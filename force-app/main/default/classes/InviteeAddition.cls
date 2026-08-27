/**
 * ★R13 Creating invitees on somebody's behalf and submitting them, in one transaction.
 *
 * It exists for the approver's add panel on Screen 4b. InviteeApprovalController owns the two
 * questions a controller should own — may this user add here, and is the request a sane size —
 * and everything below that lives here, because it is the same sequence Screen 3 performs in
 * two steps and getting the *order* right is the whole of the correctness.
 *
 * **Why an addition is submitted rather than left as a Draft.** Screen 3's submit acts on
 * `Added_By__c = me AND Status__c = 'Draft'` — an AM submits their own batch and nobody else's.
 * A Draft row created by an approver therefore has exactly one person in the org who could ever
 * submit it: the approver. A row nobody but its creator can move is not a proposal waiting for
 * an AM, it is a row that sits there. So the only coherent options were "submit it now" and
 * "give the approver a submit button", which is the same thing with an extra tap on a phone.
 *
 * **The chain is the ordinary one and the adder stands on their own rung of it.** The person
 * added routes from their own customer's Account Owner upward, exactly as they would have done
 * had an AM proposed them; `resolveBySeed(rows, null)` drops nobody, where a submitting AM is
 * dropped from their own chain. Two consequences, both intended:
 *
 *   - An approver who is level 1 on the row they added sees it in their own pending list and
 *     approves it there. That reads like self-approval and is not: every level above them still
 *     signs, so the row collects precisely the signatures it would have collected anyway. The
 *     approver gains no authority they did not already hold — they could always approve this
 *     person once an AM added them — and the ProcessInstance records their decision as a
 *     decision rather than leaving it implied.
 *   - It leaves the feature with no dead end. Dropping the adder would hand the most senior
 *     approver — a Regional Head who owns the account, and the person most likely to want this —
 *     an empty chain and an "unroutable" refusal.
 *
 * **Nothing is written until everything can be.** The chain is resolved *before* the insert, so
 * a batch containing one guest with no customer behind them refuses whole and leaves no orphan
 * Draft rows on the event. Same all-or-nothing shape as submitMyInvitees and decide(), same
 * reason.
 *
 * **Status__c is never set here.** The field's own default makes a new row Draft for the instant
 * between insert and submit, and the Approval Process writes every value after that. That is not
 * fastidiousness: it is what lets `Event_Approver` ship with Create on `Event_Invitee__c`, no
 * Edit at all, and `Status__c` still read-only. An approver can put somebody forward through
 * this screen and still cannot type a status onto anybody.
 */
public with sharing class InviteeAddition {
    /** ★R13 What one "add these people" action did. Every number here is one the approver needs. */
    public class Result {
        @AuraEnabled
        public Integer added { get; set; }
        /**
         * Ids the caller sent that were not added: already on this event in some status, or not
         * an attendee at all. Reported rather than hidden, exactly as decide() reports its own
         * skipped rows — "added 3 of 5" is a fact, and a bare 3 is not.
         */
        @AuraEnabled
        public Integer skipped { get; set; }
        /**
         * How many of the new rows are now waiting on the person who added them. Not always all
         * of them and not always none: it depends where in each chain they stand, which is the
         * one thing about this action that is genuinely surprising the first time.
         */
        @AuraEnabled
        public Integer waitingOnMe { get; set; }
        /** Distinct level-1 approvers told about the batch. The adder is never one of them. */
        @AuraEnabled
        public Integer approversNotified { get; set; }
        /** The longest chain in the batch, so the adder learns how many signatures are pending. */
        @AuraEnabled
        public Integer levels { get; set; }
    }

    /**
     * Raised when the batch cannot be added at all. Like ApprovalChainService.UnroutableException
     * it is thrown before anything is written and its message is written for the approver rather
     * than for a log; the controller turns it into an AuraHandledException unchanged.
     */
    public class RefusedException extends Exception {
    }

    /**
     * Creates a row per attendee that is not already on this event, stamps each with the chain
     * its own customer produces, inserts them and submits them.
     *
     * The caller has already established that the running user may add here.
     */
    public static Result addAndSubmit(Id eventId, Set<Id> attendeeIds) {
        List<Event_Invitee__c> rows = new List<Event_Invitee__c>();
        Integer skipped = buildRows(eventId, attendeeIds, rows);

        Result res = submit(eventId, rows);
        res.skipped = skipped;
        return res;
    }

    /**
     * Fills `rows` with an unsaved, fully snapshotted invitee per addable attendee, and returns
     * how many of the requested ids were dropped.
     *
     * Nothing here writes. Both refusals happen while that is still true.
     */
    private static Integer buildRows(Id eventId, Set<Id> attendeeIds, List<Event_Invitee__c> rows) {
        // Any status counts as already on the event, Rejected included — the picker does not
        // offer those, and an id that arrives anyway is skipped rather than resurrecting a
        // decision somebody already made.
        Set<Id> already = new Set<Id>();
        for (Event_Invitee__c inv : [
            SELECT Event_Attendee__c
            FROM Event_Invitee__c
            WHERE Marketing_Event__c = :eventId AND Event_Attendee__c IN :attendeeIds
        ]) {
            already.add(inv.Event_Attendee__c);
        }

        // The select must cover everything InviteeSnapshot reads — a field missing here is
        // stamped as null rather than failing, so keep it in step with Screen 3's copy. Name is
        // the one addition: this method names the people it refuses, and Invitee_Name__c is a
        // formula and therefore blank on a row that has not been inserted yet.
        Map<Id, Event_Attendee__c> attendees = new Map<Id, Event_Attendee__c>(
            [
                SELECT
                    Id,
                    Name,
                    Salutation__c,
                    Title__c,
                    Company__c,
                    Cust_Cd__c,
                    Contact__r.AccountId,
                    Contact__r.Account.Name,
                    Contact__r.Account.OwnerId
                FROM Event_Attendee__c
                WHERE Id IN :attendeeIds
            ]
        );

        List<String> noCustomer = new List<String>();
        Integer skipped = 0;

        for (Id attendeeId : attendeeIds) {
            Event_Attendee__c attendee = attendees.get(attendeeId);
            if (attendee == null || already.contains(attendeeId)) {
                skipped++;
                continue;
            }
            Event_Invitee__c row = new Event_Invitee__c(
                Marketing_Event__c = eventId,
                Event_Attendee__c = attendeeId,
                Added_By__c = UserInfo.getUserId(),
                Unique_Key__c = String.valueOf(eventId) + '-' + String.valueOf(attendeeId)
            );
            InviteeSnapshot.stamp(row, attendee);
            if (row.Account_Manager__c == null) {
                noCustomer.add(attendee.Name);
            }
            rows.add(row);
        }

        if (!noCustomer.isEmpty()) {
            throw new RefusedException(
                noCustomer.size() +
                    ' of the people you picked belong to no customer, so there is nobody to start ' +
                    'their approval chain: ' +
                    String.join(noCustomer, ', ') +
                    '. A guest acquires one through their Contact link. Nothing was added.'
            );
        }
        if (rows.isEmpty()) {
            throw new RefusedException(
                'Everyone you picked is already on this event — including anyone whose invitation ' +
                    'was rejected, which only the account manager who proposed them can put forward ' +
                    'again. Nothing was added.'
            );
        }
        return skipped;
    }

    /** Stamps the chain onto each row, writes them, submits them and tells level 1. */
    private static Result submit(Id eventId, List<Event_Invitee__c> rows) {
        // null: drop nobody. The adder stands in their own chain like anyone else.
        Map<Id, List<Id>> chainBySeed = ApprovalChainService.resolveBySeed(rows, null);

        Id me = UserInfo.getUserId();
        Datetime now = Datetime.now();
        Map<Id, Integer> firstLevelCounts = new Map<Id, Integer>();
        Result res = new Result();
        res.added = rows.size();
        res.waitingOnMe = 0;
        res.levels = 0;

        for (Event_Invitee__c row : rows) {
            List<Id> chain = chainBySeed.get(row.Account_Manager__c);
            row.Submitted_At__c = now;
            ApprovalChainService.stamp(row, chain);

            Id firstApprover = chain[0];
            if (firstApprover == me) {
                res.waitingOnMe++;
            }
            Integer soFar = firstLevelCounts.containsKey(firstApprover) ? firstLevelCounts.get(firstApprover) : 0;
            firstLevelCounts.put(firstApprover, soFar + 1);
            if (chain.size() > res.levels) {
                res.levels = chain.size();
            }
        }

        insert rows;

        List<Approval.ProcessSubmitRequest> requests = new List<Approval.ProcessSubmitRequest>();
        for (Event_Invitee__c row : rows) {
            Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
            req.setObjectId(row.Id);
            req.setProcessDefinitionNameOrId('Invitee_Approval');
            req.setSkipEntryCriteria(false);
            req.setSubmitterId(me);
            requests.add(req);
        }
        // allOrNone = true, matching every other batch in this workflow.
        Approval.process(requests, true);

        res.approversNotified = notifyLevelOne(eventId, firstLevelCounts, me);
        return res;
    }

    /**
     * Tells the level-1 approvers of the new rows, minus the person who added them.
     *
     * The adder is struck out of the notification, not out of the chain. Telling somebody by
     * email that they have submitted work to themselves is noise, and the screen has already
     * said how many rows are waiting on them.
     */
    private static Integer notifyLevelOne(Id eventId, Map<Id, Integer> firstLevelCounts, Id adderId) {
        Map<Id, Integer> toNotify = new Map<Id, Integer>(firstLevelCounts);
        toNotify.remove(adderId);
        if (toNotify.isEmpty()) {
            return 0;
        }
        Marketing_Event__c evt = [SELECT Id, Name FROM Marketing_Event__c WHERE Id = :eventId];
        EventNotificationService.notifyApproversOfSubmission(evt, toNotify, adderId);
        return toNotify.size();
    }
}
