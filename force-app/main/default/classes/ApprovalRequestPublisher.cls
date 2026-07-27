/**
 * Publishes Approval_Request__e platform events for the on-prem middleware, which
 * subscribes through the Pub/Sub API (connection initiated from inside the corporate
 * network — no inbound firewall opening). Payload is PII-light by design: names and
 * titles only, no email/phone.
 */
public inherited sharing class ApprovalRequestPublisher {

    public static final String ACTION_REQUEST = 'REQUEST';
    public static final String ACTION_RESEND = 'RESEND';

    @TestVisible private static Integer publishedCount = 0;

    /**
     * Invitees must carry External_Approval_Id__c and be queried with
     * Marketing_Event__r.Name / Event_Date__c, Contact__r.Name / Title,
     * Account__r.Name, Account_Owner__c and Added_By__r.Name.
     * Returns the number of events accepted by the event bus.
     */
    public static Integer publish(List<Event_Invitee__c> invitees, String action) {
        if (invitees == null || invitees.isEmpty()) { return 0; }

        Set<Id> approverIds = new Set<Id>();
        for (Event_Invitee__c inv : invitees) {
            if (inv.Account_Owner__c != null) { approverIds.add(inv.Account_Owner__c); }
        }
        Map<Id, User> approvers = new Map<Id, User>([
            SELECT Id, Name, FederationIdentifier, Username FROM User WHERE Id IN :approverIds
        ]);

        List<Approval_Request__e> events = new List<Approval_Request__e>();
        for (Event_Invitee__c inv : invitees) {
            if (String.isBlank(inv.External_Approval_Id__c)) { continue; }
            User approver = inv.Account_Owner__c != null ? approvers.get(inv.Account_Owner__c) : null;
            events.add(new Approval_Request__e(
                Correlation_Id__c = inv.External_Approval_Id__c,
                Action__c = action,
                Invitee_Id__c = inv.Id,
                Event_Name__c = abbreviate(inv.Marketing_Event__r.Name, 255),
                Event_Date__c = inv.Marketing_Event__r.Event_Date__c,
                Contact_Name__c = abbreviate(inv.Contact__r.Name, 121),
                Contact_Title__c = abbreviate(inv.Contact__r.Title, 128),
                Account_Name__c = inv.Account__r != null ? abbreviate(inv.Account__r.Name, 255) : null,
                Approver_Federation_Id__c = approver == null ? null
                    : (String.isNotBlank(approver.FederationIdentifier) ? approver.FederationIdentifier : approver.Username),
                Approver_Name__c = approver == null ? null : abbreviate(approver.Name, 121),
                Submitted_By_Name__c = inv.Added_By__r != null ? abbreviate(inv.Added_By__r.Name, 121) : null
            ));
        }
        if (events.isEmpty()) { return 0; }

        Integer ok = 0;
        for (Database.SaveResult sr : EventBus.publish(events)) {
            if (sr.isSuccess()) {
                ok++;
            } else {
                System.debug(LoggingLevel.WARN, 'Approval_Request__e publish failed: ' + sr.getErrors());
            }
        }
        publishedCount += ok;
        return ok;
    }

    private static String abbreviate(String value, Integer max) {
        return value == null ? null : value.abbreviate(max);
    }
}
