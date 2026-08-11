/**
 * R3 pre-deploy data migration — run BEFORE `sf project deploy start`.
 * Only needed on an org that already has R2. A fresh org has nothing to migrate.
 *
 *   sf apex run --file scripts/r3-pre-deploy.apex -o poc-sandbox
 *
 * R3 removes 'Exported' from the Status__c picklist, which is restricted. A
 * restricted picklist cannot lose a value that records are still sitting on, so
 * every Exported row has to move first. 'Approved' is the correct destination:
 * Exported always meant "approved, and someone has downloaded it", and download
 * state is exactly what R3 stops tracking.
 *
 * Idempotent — running it twice finds nothing the second time.
 */
List<Event_Invitee__c> stranded = [SELECT Id, Status__c FROM Event_Invitee__c WHERE Status__c = 'Exported'];
for (Event_Invitee__c inv : stranded) {
    inv.Status__c = 'Approved';
}
if (!stranded.isEmpty()) {
    update stranded;
}

Integer stillPending = [SELECT COUNT() FROM Event_Invitee__c WHERE Status__c = 'Pending Approval'];

System.debug('R3 pre-deploy: moved ' + stranded.size() + ' invitee(s) from Exported to Approved.');
System.debug(
    'R3 pre-deploy: ' +
        stillPending +
        ' invitee(s) are Pending Approval. They predate Approver__c and are not in any ' +
        'approval process — run scripts/r3-post-deploy.apex after the deploy to adopt them, ' +
        'or they will sit pending forever.'
);
