/**
 * Screen 3 — Invitee Selector on the Event record page (AM side).
 *
 * One source as of R5: Event_Attendee__c, the people Screen 1 imported. The
 * Contacts-under-my-accounts tab and the Leads-I-own tab are both gone, and with
 * them the two-headed junction they fed.
 *
 * Two consequences of that are worth stating rather than discovering:
 *
 *   - **The list is no longer scoped per AM.** Account ownership and Account Team
 *     membership were what "my contacts" meant, and there is no Account here to
 *     ask. Every AM sees every attendee, bounded by the object's sharing model.
 *     That is a widening, and it is deliberate: a shared event whose attendee pool
 *     each AM could only half see would be worse than one everybody can search.
 *   - **Approval routing has one rung left.** Account Owner needed an Account and
 *     Lead Owner needed a Lead; neither exists. What remains is the submitter's
 *     manager, which is what requirement.md asked for before Account Owner was
 *     ever used as a stand-in for it.
 *
 * ★R8 The second of those is no longer permanent. Adding an invitee now snapshots the
 * customer behind them — Account, customer code and account manager, reached through
 * Event_Attendee__c.Contact__c — so the Account Owner rung has something to stand on
 * again. Nothing routed to it in R8: the field was put there first so the chain would
 * have something to start from.
 *
 * ★R9 It routes to it now, and the rung is a chain: Account Owner, their manager, that
 * manager's manager, ending early at the first Regional Head. ApprovalChainService owns
 * the rule; submitMyInvitees owns the transaction. The consequence for this screen is
 * that Account_Manager__c stopped being decoration — an invitee with no Account behind
 * them can no longer be submitted at all, which is why the error it raises names the
 * remedy rather than the field.
 *
 * Already-invited people are hidden; Rejected ones reappear and re-adding resets
 * the existing row to Draft. Submission hands off to the standard Approval Process
 * — this class resolves who approves, the process owns the status from there.
 */
public with sharing class InviteeSelectorController {
    public class SelectableAttendee {
        @AuraEnabled
        public Id attendeeId { get; set; }
        @AuraEnabled
        public String name { get; set; }
        @AuraEnabled
        public String title { get; set; }
        @AuraEnabled
        public String email { get; set; }
        @AuraEnabled
        public String company { get; set; }
    }

    /** Wrapper so a truncated list can say so — a silently short list reads as "that's everyone". */
    public class SelectableResult {
        @AuraEnabled
        public List<SelectableAttendee> attendees { get; set; }
        @AuraEnabled
        public Boolean truncated { get; set; }
        @AuraEnabled
        public Integer cap { get; set; }
    }

    public class InviteeRow {
        @AuraEnabled
        public Id inviteeId { get; set; }
        @AuraEnabled
        public String attendeeName { get; set; }
        @AuraEnabled
        public String attendeeTitle { get; set; }
        @AuraEnabled
        public String company { get; set; }
        @AuraEnabled
        public String status { get; set; }
        @AuraEnabled
        public String addedByName { get; set; }
        @AuraEnabled
        public Boolean mine { get; set; }
        @AuraEnabled
        public Boolean attended { get; set; }
        /** Only an approved invitee can be marked as attended — the UI greys out the rest. */
        @AuraEnabled
        public Boolean canAttend { get; set; }
    }

    public class AttendanceResult {
        @AuraEnabled
        public Integer marked { get; set; }
        @AuraEnabled
        public Integer cleared { get; set; }
        /** Rows the client asked to mark that were not approved. Reported, never silently dropped. */
        @AuraEnabled
        public Integer skippedNotApproved { get; set; }
    }

    public class SubmitResult {
        @AuraEnabled
        public Integer submitted { get; set; }
        /** ★R9 Distinct level-1 approvers told about this batch — no longer always one. */
        @AuraEnabled
        public Integer approversNotified { get; set; }
        /** ★R9 The longest chain in the batch, so the AM learns how many signatures they are waiting on. */
        @AuraEnabled
        public Integer levels { get; set; }
    }

    /** Most attendees the selector will hand back in one call. */
    public static final Integer ATTENDEE_CAP = 2000;

    @AuraEnabled(cacheable=true)
    public static SelectableResult getSelectableAttendees(Id eventId) {
        SelectableResult res = new SelectableResult();
        res.attendees = new List<SelectableAttendee>();
        res.truncated = false;
        res.cap = ATTENDEE_CAP;

        Set<Id> blocked = blockedAttendeeIds(eventId);

        // One row past the cap: if it comes back, there are more than we are showing.
        Integer probe = ATTENDEE_CAP + 1;
        List<Event_Attendee__c> found = [
            SELECT Id, Name, Title__c, Email__c, Company__c
            FROM Event_Attendee__c
            WHERE Id NOT IN :blocked
            ORDER BY Company__c, Name
            LIMIT :probe
        ];
        if (found.size() > ATTENDEE_CAP) {
            res.truncated = true;
            found.remove(ATTENDEE_CAP); // drop the probe row
        }

        for (Event_Attendee__c a : found) {
            SelectableAttendee sa = new SelectableAttendee();
            sa.attendeeId = a.Id;
            sa.name = a.Name;
            sa.title = a.Title__c;
            sa.email = a.Email__c;
            // Grouping key is the Company *text*: two spellings of one organisation
            // group separately, which is accepted for the PoC — there is no record
            // to key on, by design.
            sa.company = a.Company__c;
            res.attendees.add(sa);
        }
        return res;
    }

    @AuraEnabled
    public static Integer addAttendees(Id eventId, List<Id> attendeeIds) {
        if (attendeeIds == null || attendeeIds.isEmpty()) {
            throw new AuraHandledException('No attendees selected.');
        }

        // Existing rows for these attendees on this event (any status).
        Map<Id, Event_Invitee__c> existingByAttendee = new Map<Id, Event_Invitee__c>();
        for (Event_Invitee__c inv : [
            SELECT Id, Event_Attendee__c, Status__c
            FROM Event_Invitee__c
            WHERE Marketing_Event__c = :eventId AND Event_Attendee__c IN :attendeeIds
        ]) {
            existingByAttendee.put(inv.Event_Attendee__c, inv);
        }

        // Ids the client sent that do not resolve are dropped rather than trusted —
        // the same reason the import re-classifies server-side.
        //
        // ★R8 The same query carries everything the invitee snapshots. The Account is
        // reached through the Contact link and never guessed from the company text:
        // ★R12 Contact__c is set by the import, matching on customer code AND email
        // together, so an Account here means both of those agreed — not that two company
        // strings looked alike. Account.AccountNumber has dropped out of the select:
        // Cust_Cd__c now comes from the attendee, and the Account is only needed for its
        // name, its Id and its owner.
        // The select must cover everything InviteeSnapshot reads — a field missing here
        // is stamped as null rather than failing, so keep the two in step.
        Map<Id, Event_Attendee__c> attendees = new Map<Id, Event_Attendee__c>(
            [
                SELECT
                    Id,
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

        List<Event_Invitee__c> toInsert = new List<Event_Invitee__c>();
        List<Event_Invitee__c> toReset = new List<Event_Invitee__c>();

        for (Id attendeeId : attendeeIds) {
            Event_Attendee__c attendee = attendees.get(attendeeId);
            if (attendee == null) {
                continue;
            }
            Event_Invitee__c existing = existingByAttendee.get(attendeeId);
            if (existing == null) {
                Event_Invitee__c fresh = new Event_Invitee__c(
                    Marketing_Event__c = eventId,
                    Event_Attendee__c = attendeeId,
                    Status__c = 'Draft',
                    Added_By__c = UserInfo.getUserId(),
                    Unique_Key__c = String.valueOf(eventId) + '-' + String.valueOf(attendeeId)
                );
                stampSnapshot(fresh, attendee);
                toInsert.add(fresh);
            } else if (existing.Status__c == 'Rejected') {
                // Re-add resets the existing row — Unique_Key__c forbids a second row.
                resetToDraft(existing);
                // ★R8 Re-stamped, not left alone: a re-add is a fresh invitation, and it
                // should carry what is true now rather than what was true when the row
                // was first created and then rejected.
                stampSnapshot(existing, attendee);
                toReset.add(existing);
            }
            // Any other status: already invited — silently skipped (UI hides these anyway).
        }

        if (!toInsert.isEmpty()) {
            insert toInsert;
        }
        if (!toReset.isEmpty()) {
            update toReset;
        }
        return toInsert.size() + toReset.size();
    }

    /**
     * Submits this AM's Draft rows to the standard Approval Process.
     *
     * The status is deliberately NOT written here — the approval process's initial
     * submission action owns it. What this method owns is the one thing an approval
     * process cannot work out for itself: who approves. That is resolved once,
     * frozen onto the row, and never recomputed, so a later org-chart change
     * cannot reroute an item somebody is already looking at.
     *
     * ★R9 What is resolved is now a chain rather than a person — Account Owner, their
     * manager, that manager's manager, stopping at the first Regional Head. The rule lives
     * in ApprovalChainService; what stays here is the transaction shape, which is unchanged:
     * resolve first, refuse the whole batch if any row cannot be routed, and only then write
     * anything. A half-submitted batch is worse than a refused one, and with a chain there
     * are more ways to be half-submitted.
     */
    @AuraEnabled
    public static SubmitResult submitMyInvitees(Id eventId) {
        List<Event_Invitee__c> mine = [
            SELECT Id, Event_Attendee__c, Account_Manager__c, Invitee_Name__c
            FROM Event_Invitee__c
            WHERE Marketing_Event__c = :eventId AND Added_By__c = :UserInfo.getUserId() AND Status__c = 'Draft'
        ];
        if (mine.isEmpty()) {
            throw new AuraHandledException('You have no draft invitees to submit.');
        }

        Id submitterId = UserInfo.getUserId();
        Map<Id, List<Id>> chains;
        try {
            chains = ApprovalChainService.resolve(mine, submitterId);
        } catch (ApprovalChainService.UnroutableException e) {
            // Re-thrown rather than handled: the service's message already names the row, the
            // cause and the remedy, and nothing has been written at this point.
            throw new AuraHandledException(e.getMessage());
        }

        Datetime now = Datetime.now();
        // Level 1 is where a batch fans out: two invitees from two customers start with two
        // different Account Owners, which is exactly what the single-rung rule could not do.
        Map<Id, Integer> firstLevelCounts = new Map<Id, Integer>();
        Integer deepestChain = 0;
        for (Event_Invitee__c inv : mine) {
            List<Id> chain = chains.get(inv.Id);
            inv.Submitted_At__c = now;
            ApprovalChainService.stamp(inv, chain);

            Id firstApprover = chain[0];
            Integer soFar = firstLevelCounts.containsKey(firstApprover) ? firstLevelCounts.get(firstApprover) : 0;
            firstLevelCounts.put(firstApprover, soFar + 1);
            if (chain.size() > deepestChain) {
                deepestChain = chain.size();
            }
        }
        update mine;

        List<Approval.ProcessSubmitRequest> requests = new List<Approval.ProcessSubmitRequest>();
        for (Event_Invitee__c inv : mine) {
            Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
            req.setObjectId(inv.Id);
            req.setProcessDefinitionNameOrId('Invitee_Approval');
            req.setSkipEntryCriteria(false);
            req.setSubmitterId(submitterId);
            requests.add(req);
        }
        // allOrNone = true: a half-submitted batch is worse than a failed one.
        Approval.process(requests, true);

        Marketing_Event__c evt = [SELECT Id, Name FROM Marketing_Event__c WHERE Id = :eventId];
        // ★R9 Level 1 only. Levels 2..N are not involved yet and telling them now would ask
        // people to look at something they cannot act on; each level hears when the level
        // below it finishes, from the Invitee_Level_Advanced flow.
        EventNotificationService.notifyApproversOfSubmission(evt, firstLevelCounts, submitterId);

        SubmitResult res = new SubmitResult();
        res.submitted = mine.size();
        res.approversNotified = firstLevelCounts.size();
        res.levels = deepestChain;
        return res;
    }

    /**
     * Reads the Invitee_* formula fields rather than the lookup, so the table, the
     * approval page and the Screen 5 reports all read the attendee the same way.
     */
    @AuraEnabled(cacheable=true)
    public static List<InviteeRow> getAllInvitees(Id eventId) {
        List<InviteeRow> out = new List<InviteeRow>();
        for (Event_Invitee__c inv : [
            SELECT
                Id,
                Invitee_Name__c,
                Invitee_Title__c,
                Invitee_Org__c,
                Status__c,
                Attended__c,
                Added_By__r.Name,
                Added_By__c
            FROM Event_Invitee__c
            WHERE Marketing_Event__c = :eventId
            ORDER BY Invitee_Org__c, Invitee_Name__c
            LIMIT 2000
        ]) {
            InviteeRow r = new InviteeRow();
            r.inviteeId = inv.Id;
            r.attendeeName = inv.Invitee_Name__c;
            r.attendeeTitle = inv.Invitee_Title__c;
            r.company = inv.Invitee_Org__c;
            r.status = inv.Status__c;
            r.attended = inv.Attended__c;
            r.canAttend = inv.Status__c == 'Approved';
            r.addedByName = inv.Added_By__r != null ? inv.Added_By__r.Name : null;
            r.mine = inv.Added_By__c == UserInfo.getUserId();
            out.add(r);
        }
        return out;
    }

    /**
     * Records who actually turned up, after the event.
     *
     * Both lists are explicit rather than "these attended, infer the rest": the
     * caller's view is capped at 2,000 rows, so inferring absence from what is
     * missing would silently clear attendance for everybody past the cap.
     *
     * Attendance is deliberately not restricted to the AM who added the invitee.
     * Approval is per-batch because it is a control over what each AM proposes;
     * attendance is a fact about the room, and whoever ran the event records it.
     */
    @AuraEnabled
    public static AttendanceResult saveAttendance(Id eventId, List<Id> attendedIds, List<Id> notAttendedIds) {
        Set<Id> wantAttended = new Set<Id>(attendedIds == null ? new List<Id>() : attendedIds);
        Set<Id> wantAbsent = new Set<Id>(notAttendedIds == null ? new List<Id>() : notAttendedIds);
        if (wantAttended.isEmpty() && wantAbsent.isEmpty()) {
            throw new AuraHandledException('Nothing to record.');
        }
        // An id in both lists is a client bug; absence is the safer reading.
        wantAttended.removeAll(wantAbsent);

        Set<Id> touched = new Set<Id>(wantAttended);
        touched.addAll(wantAbsent);

        AttendanceResult res = new AttendanceResult();
        res.marked = 0;
        res.cleared = 0;
        res.skippedNotApproved = 0;

        List<Event_Invitee__c> changed = new List<Event_Invitee__c>();
        // Scoped to the event as well as the ids: an id from another event would
        // otherwise be writable through this method.
        for (Event_Invitee__c inv : [
            SELECT Id, Status__c, Attended__c
            FROM Event_Invitee__c
            WHERE Marketing_Event__c = :eventId AND Id IN :touched
        ]) {
            Boolean target = wantAttended.contains(inv.Id);
            if (target && inv.Status__c != 'Approved') {
                // Attended_Requires_Approved would refuse this at the database; catching
                // it here means one unapproved row cannot fail the whole save.
                res.skippedNotApproved++;
                continue;
            }
            if (inv.Attended__c == target) {
                continue; // already in the requested state
            }
            inv.Attended__c = target;
            changed.add(inv);
            if (target) {
                res.marked++;
            } else {
                res.cleared++;
            }
        }

        if (!changed.isEmpty()) {
            update changed;
        }
        return res;
    }

    // ---------- internals ----------

    /** Attendees already on the event, unless their row is Rejected — those reappear. */
    private static Set<Id> blockedAttendeeIds(Id eventId) {
        Set<Id> ids = new Set<Id>();
        for (Event_Invitee__c inv : [
            SELECT Event_Attendee__c
            FROM Event_Invitee__c
            WHERE Marketing_Event__c = :eventId AND Status__c != 'Rejected'
        ]) {
            if (inv.Event_Attendee__c != null) {
                ids.add(inv.Event_Attendee__c);
            }
        }
        return ids;
    }

    /**
     * ★R8 Freezes onto the invitee what was true of this person, and of the customer they
     * belong to, at the moment they were put forward. The reference ERD does the same on
     * SEIM_INVITEE, and the reason is that an approval has to keep showing what the approver
     * actually saw — a live formula lets a later edit to the attendee rewrite the past.
     *
     * The company falls back to the attendee's imported text when there is no Contact behind
     * them, so the field is never blank just because a guest is nobody's customer. Account__c
     * and Account_Manager__c stay blank in that case, which is the honest answer: there is no
     * customer to name. ★R12 Cust_Cd__c no longer stays blank with them — it comes from the
     * CSV by way of the attendee, so a guest whose code matched no Contact still carries it.
     *
     * Two things this deliberately does not do. It never writes to Account or Contact — it
     * only reads them. And it does not bypass sharing: this class is `with sharing`, so an
     * Account the running user cannot see comes back null and the row falls through to the
     * text. That is a real gap under a Private Account OWD, and the alternative — reading the
     * org's customer data `without sharing` to fill in a convenience field — is not a trade
     * this project gets to make on the org's behalf.
     *
     * ★R12 The body moved to InviteeSnapshot, which EventAttendeeSync also calls when an
     * attendee is edited after the fact. This is the add-time caller and always stamps
     * everything: a row being created, or a Rejected row being re-added, has no frozen
     * approver chain for the routing fields to contradict.
     */
    private static void stampSnapshot(Event_Invitee__c inv, Event_Attendee__c attendee) {
        InviteeSnapshot.stamp(inv, attendee);
    }

    /**
     * Clears every trace of the previous approval round. The approver fields must go with
     * the rest: leaving a stale chain on a Draft row would let the next submit silently
     * reuse whoever decided last time.
     *
     * ★R9 There are seven fields to clear now instead of three, which is the kind of thing
     * that rots. ApprovalChainService.stamp(inv, null) blanks the whole chain in one call, so
     * a sixth level added later cannot be forgotten here.
     */
    private static void resetToDraft(Event_Invitee__c inv) {
        inv.Status__c = 'Draft';
        inv.Added_By__c = UserInfo.getUserId();
        ApprovalChainService.stamp(inv, null);
        inv.Current_Level__c = null;
        inv.Submitted_At__c = null;
        inv.Decided_At__c = null;
    }
}
