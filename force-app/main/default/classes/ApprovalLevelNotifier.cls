/**
 * ★R9 The Invitee_Level_Advanced flow's entry point into Apex.
 *
 * It exists as a class of its own for one reason, and it is a platform rule rather than a
 * design choice: only one method per Apex class may be an @InvocableMethod, and
 * EventNotificationService has already spent its one on the completion notification. The
 * counting and sending stay there; this is the doorway.
 *
 * The Flow is the trigger and the aggregation is in Apex, for the same reason as the
 * completion path: a mass approval advances forty rows in one transaction and the level
 * above should hear once, not forty times.
 */
public with sharing class ApprovalLevelNotifier {
    @InvocableMethod(
        label='Notify The Approval Level Just Reached'
        description='Tells each approver at the level a batch has just advanced to that invitees are now waiting on them. One notification per approver per event, never one per invitee.'
        category='Event Management'
    )
    public static void notifyLevelApprovers(List<Id> inviteeIds) {
        EventNotificationService.notifyLevelApprovers(inviteeIds);
    }
}
