/**
 * R3 post-deploy data migration — run AFTER `sf project deploy start` succeeds.
 * Only needed on an org that already has R2.
 *
 *   sf apex run --file scripts/r3-post-deploy.apex -o poc-sandbox
 *
 * Adopts the invitees that were already Pending Approval before R3 existed.
 *
 * Those rows are pending in the *old* sense: a status value and an Account_Owner__c
 * snapshot, with nothing behind them. There is no approval process instance, so
 * nobody has a work item, and the console that used to read Account_Owner__c is
 * gone. Left alone they are precisely the orphan row Approver_Required_When_Pending
 * exists to make impossible — pending on screen, un-decidable in fact.
 *
 * Every one of them is a Contact invitee (Lead invitees could not exist before R3),
 * so ladder rule 1 applies and Account_Owner__c is the right approver by definition.
 *
 * Idempotent — rows already carrying an Approver__c are skipped.
 */
List<Event_Invitee__c> orphans = [
    SELECT Id, Account_Owner__c, Account__c, Contact__c
    FROM Event_Invitee__c
    WHERE Status__c = 'Pending Approval' AND Approver__c = NULL
];

List<Event_Invitee__c> adoptable = new List<Event_Invitee__c>();
List<Event_Invitee__c> unroutable = new List<Event_Invitee__c>();

for (Event_Invitee__c inv : orphans) {
    if (inv.Account_Owner__c != null) {
        inv.Approver__c = inv.Account_Owner__c;
        adoptable.add(inv);
    } else {
        // No snapshot to fall back on. Sending these back to Draft is honest: the AM
        // resubmits and the ladder resolves an approver properly. Inventing one here
        // would be guessing at who should have signed something off weeks ago.
        inv.Status__c = 'Draft';
        inv.Submitted_At__c = null;
        unroutable.add(inv);
    }
}

if (!adoptable.isEmpty()) {
    update adoptable; // Approver__c set in the same DML the validation rule inspects
}
if (!unroutable.isEmpty()) {
    update unroutable;
}

// Put the adopted rows into the approval process so their approver actually gets a
// work item. Without this they would carry an approver and still have nothing to click.
List<Approval.ProcessSubmitRequest> requests = new List<Approval.ProcessSubmitRequest>();
for (Event_Invitee__c inv : adoptable) {
    Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
    req.setObjectId(inv.Id);
    req.setProcessDefinitionNameOrId('Invitee_Approval');
    requests.add(req);
}

Integer submitted = 0;
if (!requests.isEmpty()) {
    // allOrNone = false: one bad row (an inactive approver, say) must not block the
    // rest of the backfill. Failures are printed so they can be handled by hand.
    for (Approval.ProcessResult r : Approval.process(requests, false)) {
        if (r.isSuccess()) {
            submitted++;
        } else {
            System.debug(LoggingLevel.WARN, 'Could not submit ' + r.getEntityId() + ': ' + r.getErrors());
        }
    }
}

System.debug('R3 post-deploy: adopted ' + adoptable.size() + ' pending invitee(s); ' + submitted + ' entered the approval process.');
System.debug('R3 post-deploy: returned ' + unroutable.size() + ' invitee(s) with no owner snapshot to Draft for resubmission.');
