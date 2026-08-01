/**
 * All email + in-app (bell) notifications for the event workflow.
 * Called from Apex only — aggregate conditions ("one notification per distinct
 * owner", "zero remaining pending per AM") are computed by the callers, per the
 * design decision to keep aggregation out of record-triggered Flows.
 */
public with sharing class EventNotificationService {
    @TestVisible
    private static Integer emailsSent = 0;
    @TestVisible
    private static Integer bellsSent = 0;

    /** One notification per distinct Account Owner at submit time. */
    public static void notifyOwnersOfSubmission(
        Marketing_Event__c evt,
        Map<Id, Integer> pendingCountByOwnerId,
        Id submittedById
    ) {
        String submitterName = [SELECT Name FROM User WHERE Id = :submittedById].Name;
        List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();

        for (Id ownerId : pendingCountByOwnerId.keySet()) {
            Integer n = pendingCountByOwnerId.get(ownerId);
            String title = 'Approval requested: ' + evt.Name;
            String body =
                submitterName +
                ' submitted ' +
                n +
                ' contact(s) under your accounts for "' +
                evt.Name +
                '". Open the event to approve or reject.';

            emails.add(buildEmail(ownerId, title, body, evt.Id));
            sendBell(ownerId, title, body, evt.Id);
        }
        sendEmails(emails);
    }

    /** Sent when an AM's submitted batch for an event has zero remaining Pending rows. */
    public static void notifyAmOfCompletion(Marketing_Event__c evt, Id amId, Integer approved, Integer rejected) {
        String title = 'Review complete: ' + evt.Name;
        String body =
            'Your submissions for "' +
            evt.Name +
            '" have been fully reviewed: ' +
            approved +
            ' approved, ' +
            rejected +
            ' rejected. ' +
            'You can now export the approved list from the event page.';
        sendEmails(new List<Messaging.SingleEmailMessage>{ buildEmail(amId, title, body, evt.Id) });
        sendBell(amId, title, body, evt.Id);
    }

    // ---------- internals ----------

    private static Messaging.SingleEmailMessage buildEmail(Id userId, String subject, String body, Id eventId) {
        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setTargetObjectId(userId);
        mail.setSaveAsActivity(false);
        mail.setSubject(subject);
        mail.setPlainTextBody(body + '\n\nEvent: ' + URL.getOrgDomainUrl().toExternalForm() + '/' + eventId);
        return mail;
    }

    private static void sendEmails(List<Messaging.SingleEmailMessage> emails) {
        if (emails.isEmpty()) {
            return;
        }
        try {
            Messaging.sendEmail(emails, false);
            emailsSent += emails.size();
        } catch (Exception e) {
            // PoC: email deliverability may be off in a sandbox — never block the transaction.
            System.debug(LoggingLevel.WARN, 'Email send failed: ' + e.getMessage());
        }
    }

    private static void sendBell(Id userId, String title, String body, Id eventId) {
        List<CustomNotificationType> types = [
            SELECT Id
            FROM CustomNotificationType
            WHERE DeveloperName = 'Event_Approval_Notification'
            LIMIT 1
        ];
        if (types.isEmpty()) {
            return;
        } // not deployed / test context without the type
        try {
            Messaging.CustomNotification n = new Messaging.CustomNotification();
            n.setNotificationTypeId(types[0].Id);
            n.setTitle(title.abbreviate(250));
            n.setBody(body.abbreviate(750));
            n.setTargetId(eventId); // record-page navigation — reliable on desktop and mobile
            n.send(new Set<String>{ String.valueOf(userId) });
            bellsSent++;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Bell notification failed: ' + e.getMessage());
        }
    }
}
