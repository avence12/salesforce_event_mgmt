/**
 * The single place invitee approval decisions are applied. Two entry points share
 * the same state transition and the same completion notification:
 *  - decideAsOwner: the in-app approval console (Account Owner clicking Approve/Reject);
 *  - applyExternalDecisions: the corporate approval system's callback via
 *    ExternalApprovalRestService, addressed by correlation ID and idempotent.
 * Keeping both paths here guarantees the "AM fully reviewed" notification and the
 * Decided_At__c stamp behave identically no matter where the decision was made.
 */
public inherited sharing class ApprovalDecisionService {

    public class OwnerDecisionResult {
        public Integer decided;
        public Integer amsNotified;
    }

    /** One decision from the corporate approval system. */
    public class ExternalDecision {
        public String correlationId;
        public Boolean approve;
        public String approverRef;  // employee ID / directory account as the corporate system knows it
        public String comment;
    }

    // ExternalResult.status values — string constants rather than an enum so they
    // serialize cleanly through the REST layer.
    public static final String RESULT_APPLIED = 'APPLIED';
    public static final String RESULT_ALREADY_APPLIED = 'ALREADY_APPLIED';
    public static final String RESULT_NOT_FOUND = 'NOT_FOUND';
    public static final String RESULT_CONFLICT = 'CONFLICT';
    public static final String RESULT_INVALID = 'INVALID';

    public class ExternalResult {
        public String correlationId;
        public String status;
        public String message;
        public ExternalResult(String correlationId, String status, String message) {
            this.correlationId = correlationId;
            this.status = status;
            this.message = message;
        }
    }

    /** Console path: the running user decides their own pending rows on one event. */
    public static OwnerDecisionResult decideAsOwner(Id eventId, List<Id> inviteeIds, Boolean approve) {
        // Only rows that are genuinely mine + pending — ignore anything else the client sent.
        List<Event_Invitee__c> rows = [
            SELECT Id, Added_By__c
            FROM Event_Invitee__c
            WHERE Id IN :inviteeIds
              AND Marketing_Event__c = :eventId
              AND Account_Owner__c = :UserInfo.getUserId()
              AND Status__c = 'Pending Approval'
        ];
        if (rows.isEmpty()) {
            throw new AuraHandledException('Nothing to decide — the selected invitees are no longer pending.');
        }

        Set<Id> affectedAms = new Set<Id>();
        Datetime now = Datetime.now();
        for (Event_Invitee__c inv : rows) {
            inv.Status__c = approve ? 'Approved' : 'Rejected';
            inv.Decided_At__c = now;
            if (inv.Added_By__c != null) { affectedAms.add(inv.Added_By__c); }
        }
        update rows;

        OwnerDecisionResult res = new OwnerDecisionResult();
        res.decided = rows.size();
        res.amsNotified = notifyCompletedAms(eventId, affectedAms);
        return res;
    }

    /**
     * Callback path: apply decisions from the corporate system, matched by
     * External_Approval_Id__c. Idempotent — replaying a decision that already
     * landed returns ALREADY_APPLIED and triggers no second notification.
     * Decisions may span events; completion notifications are computed per event.
     */
    public static List<ExternalResult> applyExternalDecisions(List<ExternalDecision> decisions) {
        List<ExternalResult> out = new List<ExternalResult>();

        Map<String, ExternalDecision> byCorrelation = new Map<String, ExternalDecision>();
        for (ExternalDecision d : decisions) {
            if (d == null || String.isBlank(d.correlationId) || d.approve == null) {
                out.add(new ExternalResult(d == null ? null : d.correlationId, RESULT_INVALID,
                    'correlationId and approve are both required.'));
            } else if (byCorrelation.containsKey(d.correlationId)) {
                out.add(new ExternalResult(d.correlationId, RESULT_INVALID,
                    'Duplicate correlationId within one payload.'));
            } else {
                byCorrelation.put(d.correlationId, d);
            }
        }
        if (byCorrelation.isEmpty()) { return out; }

        Map<String, Event_Invitee__c> rowByCorrelation = new Map<String, Event_Invitee__c>();
        for (Event_Invitee__c inv : [
            SELECT Id, External_Approval_Id__c, Status__c, Marketing_Event__c, Added_By__c
            FROM Event_Invitee__c
            WHERE External_Approval_Id__c IN :byCorrelation.keySet()
        ]) {
            rowByCorrelation.put(inv.External_Approval_Id__c, inv);
        }

        List<Event_Invitee__c> toUpdate = new List<Event_Invitee__c>();
        Map<Id, Set<Id>> affectedAmsByEvent = new Map<Id, Set<Id>>();
        Datetime now = Datetime.now();

        for (String cid : byCorrelation.keySet()) {
            ExternalDecision d = byCorrelation.get(cid);
            Event_Invitee__c inv = rowByCorrelation.get(cid);
            String target = d.approve ? 'Approved' : 'Rejected';

            if (inv == null) {
                // Also the case after a rejected invitee was re-added: the reset clears the
                // old correlation ID, so a late callback for the stale ticket lands here.
                out.add(new ExternalResult(cid, RESULT_NOT_FOUND, 'No invitee carries this correlation ID.'));
            } else if (inv.Status__c == 'Pending Approval') {
                inv.Status__c = target;
                inv.Decided_At__c = now;
                inv.Integration_Status__c = 'Decided';
                inv.External_Approver__c = d.approverRef;
                inv.Decision_Comment__c = d.comment;
                toUpdate.add(inv);
                if (inv.Added_By__c != null) {
                    if (!affectedAmsByEvent.containsKey(inv.Marketing_Event__c)) {
                        affectedAmsByEvent.put(inv.Marketing_Event__c, new Set<Id>());
                    }
                    affectedAmsByEvent.get(inv.Marketing_Event__c).add(inv.Added_By__c);
                }
                out.add(new ExternalResult(cid, RESULT_APPLIED, null));
            } else if (inv.Status__c == target || (d.approve && inv.Status__c == 'Exported')) {
                // Exported means approved-then-downloaded — an approve replay is still a match.
                out.add(new ExternalResult(cid, RESULT_ALREADY_APPLIED, 'Invitee is already ' + inv.Status__c + '.'));
            } else {
                out.add(new ExternalResult(cid, RESULT_CONFLICT,
                    'Invitee is ' + inv.Status__c + '; cannot apply ' + target + '.'));
            }
        }

        if (!toUpdate.isEmpty()) {
            update toUpdate;
            for (Id eventId : affectedAmsByEvent.keySet()) {
                notifyCompletedAms(eventId, affectedAmsByEvent.get(eventId));
            }
        }
        return out;
    }

    /** Middleware confirmed ticket creation: Sent → Acknowledged. Idempotent. */
    public static Integer acknowledge(List<String> correlationIds) {
        if (correlationIds == null || correlationIds.isEmpty()) { return 0; }
        List<Event_Invitee__c> rows = [
            SELECT Id FROM Event_Invitee__c
            WHERE External_Approval_Id__c IN :correlationIds
              AND Integration_Status__c = 'Sent'
        ];
        for (Event_Invitee__c inv : rows) {
            inv.Integration_Status__c = 'Acknowledged';
        }
        if (!rows.isEmpty()) { update rows; }
        return rows.size();
    }

    // ---------- internals ----------

    /** For each affected AM: if they have zero remaining Pending rows on this event, send the completion notification. */
    private static Integer notifyCompletedAms(Id eventId, Set<Id> amIds) {
        if (amIds.isEmpty()) { return 0; }

        Set<Id> stillPending = new Set<Id>();
        for (AggregateResult ar : [
            SELECT Added_By__c am
            FROM Event_Invitee__c
            WHERE Marketing_Event__c = :eventId
              AND Added_By__c IN :amIds
              AND Status__c = 'Pending Approval'
            GROUP BY Added_By__c
        ]) {
            stillPending.add((Id) ar.get('am'));
        }

        Map<Id, Integer> approvedByAm = new Map<Id, Integer>();
        Map<Id, Integer> rejectedByAm = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT Added_By__c am, Status__c st, COUNT(Id) n
            FROM Event_Invitee__c
            WHERE Marketing_Event__c = :eventId
              AND Added_By__c IN :amIds
              AND Status__c IN ('Approved', 'Rejected', 'Exported')
            GROUP BY Added_By__c, Status__c
        ]) {
            Id am = (Id) ar.get('am');
            String st = (String) ar.get('st');
            Integer n = (Integer) ar.get('n');
            if (st == 'Rejected') {
                rejectedByAm.put(am, (rejectedByAm.containsKey(am) ? rejectedByAm.get(am) : 0) + n);
            } else {
                approvedByAm.put(am, (approvedByAm.containsKey(am) ? approvedByAm.get(am) : 0) + n);
            }
        }

        Marketing_Event__c evt = [SELECT Id, Name FROM Marketing_Event__c WHERE Id = :eventId];
        Integer notified = 0;
        for (Id amId : amIds) {
            if (stillPending.contains(amId)) { continue; }
            EventNotificationService.notifyAmOfCompletion(
                evt, amId,
                approvedByAm.containsKey(amId) ? approvedByAm.get(amId) : 0,
                rejectedByAm.containsKey(amId) ? rejectedByAm.get(amId) : 0
            );
            notified++;
        }
        return notified;
    }
}
