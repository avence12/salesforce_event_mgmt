/**
 * Screen 4 — Approval Console (Account Owner side), a record-page LWC on
 * Marketing_Event__c. Owners see only their own pending invitees for the event.
 * The decision itself lives in ApprovalDecisionService, shared with the corporate
 * approval system's callback; when external approval is enabled this console is
 * read-only — sign-off happens in the corporate system and syncs back.
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
    public static Boolean isExternalApprovalEnabled() {
        return ApprovalIntegrationSettings.externalEnabled();
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
        if (ApprovalIntegrationSettings.externalEnabled()) {
            throw new AuraHandledException(
                'Approvals are managed in the corporate approval system — this console is read-only.');
        }
        if (inviteeIds == null || inviteeIds.isEmpty()) {
            throw new AuraHandledException('No invitees selected.');
        }

        ApprovalDecisionService.OwnerDecisionResult r =
            ApprovalDecisionService.decideAsOwner(eventId, inviteeIds, approve);

        DecisionResult res = new DecisionResult();
        res.decided = r.decided;
        res.amsNotified = r.amsNotified;
        return res;
    }
}
