/**
 * Reliability backstop for the corporate-approval integration: platform events can
 * be missed and callbacks can fail, so pending requests must not wait forever.
 *  - older than Resend_After_Hours (default 24): republish the request with
 *    Action = RESEND and the same correlation ID (middleware upserts, no dup ticket);
 *  - older than Fail_After_Hours (default 72): mark Integration Status = Sync Failed
 *    for manual follow-up. Such a row drops out of this batch, but a late decision
 *    callback still lands normally — Status__c is still Pending Approval.
 *
 * Schedule (e.g. hourly):
 *   System.schedule('Approval Sync Reconciliation', '0 0 * * * ?',
 *                   new ApprovalSyncReconciliationBatch());
 */
public without sharing class ApprovalSyncReconciliationBatch
    implements Database.Batchable<SObject>, Schedulable {

    @TestVisible private static Integer lastResent = 0;
    @TestVisible private static Integer lastFlagged = 0;

    public Database.QueryLocator start(Database.BatchableContext bc) {
        Datetime resendCutoff = Datetime.now().addHours(-ApprovalIntegrationSettings.resendAfterHours());
        return Database.getQueryLocator([
            SELECT Id, External_Approval_Id__c, Submitted_At__c, Account_Owner__c,
                   Added_By__r.Name, Contact__r.Name, Contact__r.Title, Account__r.Name,
                   Marketing_Event__r.Name, Marketing_Event__r.Event_Date__c
            FROM Event_Invitee__c
            WHERE Status__c = 'Pending Approval'
              AND External_Approval_Id__c != null
              AND Integration_Status__c IN ('Sent', 'Acknowledged')
              AND Submitted_At__c < :resendCutoff
        ]);
    }

    public void execute(Database.BatchableContext bc, List<Event_Invitee__c> scope) {
        Datetime failCutoff = Datetime.now().addHours(-ApprovalIntegrationSettings.failAfterHours());

        List<Event_Invitee__c> toFlag = new List<Event_Invitee__c>();
        List<Event_Invitee__c> toResend = new List<Event_Invitee__c>();
        for (Event_Invitee__c inv : scope) {
            if (inv.Submitted_At__c < failCutoff) {
                toFlag.add(new Event_Invitee__c(Id = inv.Id, Integration_Status__c = 'Sync Failed'));
            } else {
                toResend.add(inv);
            }
        }

        if (!toFlag.isEmpty()) {
            update toFlag;
            lastFlagged += toFlag.size();
        }
        if (!toResend.isEmpty()) {
            lastResent += ApprovalRequestPublisher.publish(toResend, ApprovalRequestPublisher.ACTION_RESEND);
        }
    }

    public void finish(Database.BatchableContext bc) {
        System.debug(LoggingLevel.INFO,
            'Approval sync reconciliation: resent ' + lastResent + ', flagged ' + lastFlagged + ' as Sync Failed.');
    }

    public void execute(SchedulableContext sc) {
        Database.executeBatch(new ApprovalSyncReconciliationBatch(), 200);
    }
}
