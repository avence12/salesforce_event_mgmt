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
        @AuraEnabled
        public Integer approversNotified { get; set; }
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
        Set<Id> real = new Map<Id, Event_Attendee__c>([SELECT Id FROM Event_Attendee__c WHERE Id IN :attendeeIds])
            .keySet();

        List<Event_Invitee__c> toInsert = new List<Event_Invitee__c>();
        List<Event_Invitee__c> toReset = new List<Event_Invitee__c>();

        for (Id attendeeId : attendeeIds) {
            if (!real.contains(attendeeId)) {
                continue;
            }
            Event_Invitee__c existing = existingByAttendee.get(attendeeId);
            if (existing == null) {
                toInsert.add(
                    new Event_Invitee__c(
                        Marketing_Event__c = eventId,
                        Event_Attendee__c = attendeeId,
                        Status__c = 'Draft',
                        Added_By__c = UserInfo.getUserId(),
                        Unique_Key__c = String.valueOf(eventId) + '-' + String.valueOf(attendeeId)
                    )
                );
            } else if (existing.Status__c == 'Rejected') {
                // Re-add resets the existing row — Unique_Key__c forbids a second row.
                resetToDraft(existing);
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
     * frozen into Approver__c, and never recomputed, so a later org-chart change
     * cannot reroute an item somebody is already looking at.
     */
    @AuraEnabled
    public static SubmitResult submitMyInvitees(Id eventId) {
        List<Event_Invitee__c> mine = [
            SELECT Id, Event_Attendee__c
            FROM Event_Invitee__c
            WHERE Marketing_Event__c = :eventId AND Added_By__c = :UserInfo.getUserId() AND Status__c = 'Draft'
        ];
        if (mine.isEmpty()) {
            throw new AuraHandledException('You have no draft invitees to submit.');
        }

        Id submitterId = UserInfo.getUserId();
        Id managerId = [SELECT ManagerId FROM User WHERE Id = :submitterId].ManagerId;

        // The whole ladder, now that neither an Account Owner nor a Lead Owner
        // exists to climb past. A submitter with no manager resolves to nobody, and
        // that is refused below rather than written as a row no approver can see.
        if (managerId == null) {
            throw new AuraHandledException(
                'No approver could be determined for your ' +
                    mine.size() +
                    ' invitee(s): your user record has no Manager, and an attendee has no account owner to fall back on. ' +
                    'Ask an administrator to set a Manager on your user. Nothing was submitted.'
            );
        }

        Datetime now = Datetime.now();
        for (Event_Invitee__c inv : mine) {
            inv.Submitted_At__c = now;
            inv.Approver__c = managerId;
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
        EventNotificationService.notifyApproversOfSubmission(
            evt,
            new Map<Id, Integer>{ managerId => mine.size() },
            submitterId
        );

        SubmitResult res = new SubmitResult();
        res.submitted = mine.size();
        // One manager per submitter, so this is always 1. Kept as a count rather than
        // hard-coded because it is what the toast says, and a future routing rule that
        // fans out again should not have to re-thread the return type.
        res.approversNotified = 1;
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
     * Clears every trace of the previous approval round. Approver__c must go with the
     * rest: leaving a stale approver on a Draft row would let the next submit silently
     * skip resolution and reuse whoever decided last time.
     */
    private static void resetToDraft(Event_Invitee__c inv) {
        inv.Status__c = 'Draft';
        inv.Added_By__c = UserInfo.getUserId();
        inv.Approver__c = null;
        inv.Submitted_At__c = null;
        inv.Decided_At__c = null;
    }
}
