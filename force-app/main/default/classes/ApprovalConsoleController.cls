/**
 * Screen 4 — Approval Console (Account Owner side), a record-page LWC on
 * Marketing_Event__c. Owners see only their own pending invitees for the event.
 * Completion notification is computed here in Apex (aggregate: "zero remaining
 * Pending per submitting AM"), not in a record-triggered Flow.
 */
public with sharing class ApprovalConsoleController {

    public class PendingInvitee {
        @AuraEnabled public Id inviteeId { get; set; }
        @AuraEnabled public String contactName { get; set; }
        @AuraEnabled public String contactTitle { get; set; }
        @AuraEnabled public Id accountId { get; set; }
        @AuraEnabled public String accountName { get; set; }
        @AuraEnabled public String addedByName { get; set; }
    }

    public class DecisionResult {
        @AuraEnabled public Integer decided { get; set; }
        @AuraEnabled public Integer amsNotified { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static List<PendingInvitee> getPendingForMe(Id eventId) {
        List<PendingInvitee> out = new List<PendingInvitee>();
        for (Event_Invitee__c inv : [
            SELECT Id, Contact__r.Name, Contact__r.Title, Account__c, Account__r.Name, Added_By__r.Name
            FROM Event_Invitee__c
            WHERE Marketing_Event__c = :eventId
              AND Account_Owner__c = :UserInfo.getUserId()
              AND Status__c = 'Pending Approval'
            ORDER BY Account__r.Name, Contact__r.Name
            LIMIT 2000
        ]) {
            PendingInvitee p = new PendingInvitee();
            p.inviteeId = inv.Id;
            p.contactName = inv.Contact__r.Name;
            p.contactTitle = inv.Contact__r.Title;
            p.accountId = inv.Account__c;
            p.accountName = inv.Account__r != null ? inv.Account__r.Name : null;
            p.addedByName = inv.Added_By__r != null ? inv.Added_By__r.Name : null;
            out.add(p);
        }
        return out;
    }

    @AuraEnabled
    public static DecisionResult decide(Id eventId, List<Id> inviteeIds, Boolean approve) {
        if (inviteeIds == null || inviteeIds.isEmpty()) {
            throw new AuraHandledException('No invitees selected.');
        }

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

        Integer amsNotified = notifyCompletedAms(eventId, affectedAms);

        DecisionResult res = new DecisionResult();
        res.decided = rows.size();
        res.amsNotified = amsNotified;
        return res;
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
