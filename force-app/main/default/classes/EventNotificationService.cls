/**
 * All email + in-app (bell) notifications for the event workflow.
 *
 * This class survived the move to a standard Approval Process because both of its
 * conditions are aggregates over sibling records — "one notification per distinct
 * approver", "zero remaining Pending for this AM on this event" — and a per-record
 * Flow cannot ask those questions without going wrong the moment someone approves
 * forty invitees at once. The Flow is the trigger; the counting stays here.
 *
 * Notification volume is Option 1 of the two considered in design.md: approvers
 * turn off per-request approval emails and hear once per submission from here,
 * rather than once per invitee from the Approval Process.
 */
public with sharing class EventNotificationService {
    @TestVisible
    private static Integer emailsSent = 0;
    @TestVisible
    private static Integer bellsSent = 0;
    /**
     * ★R9 Counted separately because the chain made the total ambiguous. Approving level 1
     * of three now sends a level notification in the same transaction that a completion test
     * is watching, and a test asserting "one email" would be asserting which of two features
     * fired. Each notification counts itself.
     */
    @TestVisible
    private static Integer completionsSent = 0;
    @TestVisible
    private static Integer levelNotificationsSent = 0;

    /**
     * Entry point for the Invitee_Decision_Completion record-triggered Flow.
     * Receives every invitee decided in the transaction — a mass approval of forty
     * rows arrives as one call with forty ids, which is the whole reason the counting
     * is not in the Flow.
     */
    @InvocableMethod(
        label='Notify AM If Fully Reviewed'
        description='For each AM whose submitted batch on an event now has zero Pending rows left, send the completion email and bell.'
        category='Event Management'
    )
    public static void notifyCompletions(List<Id> inviteeIds) {
        if (inviteeIds == null || inviteeIds.isEmpty()) {
            return;
        }

        // (event, submitting AM) pairs touched by this transaction.
        Set<Id> eventIds = new Set<Id>();
        Set<Id> amIds = new Set<Id>();
        Set<String> pairs = new Set<String>();
        for (Event_Invitee__c inv : [
            SELECT Marketing_Event__c, Added_By__c
            FROM Event_Invitee__c
            WHERE Id IN :inviteeIds AND Added_By__c != NULL
        ]) {
            eventIds.add(inv.Marketing_Event__c);
            amIds.add(inv.Added_By__c);
            pairs.add(inv.Marketing_Event__c + ':' + inv.Added_By__c);
        }
        if (pairs.isEmpty()) {
            return;
        }

        // One query for the whole transaction, then answer each pair from the tallies.
        Set<String> stillPending = new Set<String>();
        for (AggregateResult ar : [
            SELECT Marketing_Event__c evt, Added_By__c am
            FROM Event_Invitee__c
            WHERE Marketing_Event__c IN :eventIds AND Added_By__c IN :amIds AND Status__c = 'Pending Approval'
            GROUP BY Marketing_Event__c, Added_By__c
        ]) {
            stillPending.add(ar.get('evt') + ':' + ar.get('am'));
        }

        Map<String, Integer> approved = tally(eventIds, amIds, 'Approved');
        Map<String, Integer> rejected = tally(eventIds, amIds, 'Rejected');
        Map<Id, Marketing_Event__c> events = new Map<Id, Marketing_Event__c>(
            [SELECT Id, Name FROM Marketing_Event__c WHERE Id IN :eventIds]
        );

        for (String pair : pairs) {
            if (stillPending.contains(pair)) {
                continue; // this AM has more to hear about on this event
            }
            List<String> parts = pair.split(':');
            Marketing_Event__c evt = events.get((Id) parts[0]);
            if (evt == null) {
                continue;
            }
            notifyAmOfCompletion(
                evt,
                (Id) parts[1],
                approved.containsKey(pair) ? approved.get(pair) : 0,
                rejected.containsKey(pair) ? rejected.get(pair) : 0
            );
        }
    }

    private static Map<String, Integer> tally(Set<Id> eventIds, Set<Id> amIds, String status) {
        Map<String, Integer> out = new Map<String, Integer>();
        for (AggregateResult ar : [
            SELECT Marketing_Event__c evt, Added_By__c am, COUNT(Id) n
            FROM Event_Invitee__c
            WHERE Marketing_Event__c IN :eventIds AND Added_By__c IN :amIds AND Status__c = :status
            GROUP BY Marketing_Event__c, Added_By__c
        ]) {
            out.put(ar.get('evt') + ':' + ar.get('am'), (Integer) ar.get('n'));
        }
        return out;
    }

    /**
     * One notification per distinct approver at submit time.
     *
     * This is the notification the approver actually acts on: with Option 1 the
     * Approval Process sends no assignment email of its own, so if this stops firing
     * an approver hears nothing at all — the pending items simply appear in their
     * Approvals list unannounced.
     *
     * ★R9 This now covers level 1 only, and the map genuinely has several entries: one
     * batch spanning three customers starts on three different Account Owners. Every level
     * above it is told by notifyLevelApprovers when the level below finishes.
     */
    public static void notifyApproversOfSubmission(
        Marketing_Event__c evt,
        Map<Id, Integer> pendingCountByApproverId,
        Id submittedById
    ) {
        String submitterName = [SELECT Name FROM User WHERE Id = :submittedById].Name;
        List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();

        for (Id approverId : pendingCountByApproverId.keySet()) {
            Integer n = pendingCountByApproverId.get(approverId);
            String title = 'Approval requested: ' + evt.Name;
            String body =
                submitterName +
                ' submitted ' +
                n +
                ' invitee(s) for your approval on "' +
                evt.Name +
                '". Open the event, or your Approvals list, to approve or reject.';

            emails.add(buildEmail(approverId, title, body, evt.Id));
            sendBell(approverId, title, body, evt.Id);
        }
        sendEmails(emails);
    }

    /**
     * ★R9 Tells the level a batch has just advanced to that it now has work.
     *
     * A chain broke the notification design in a way that is easy to miss: with one approver,
     * everybody who mattered was involved at submit time and one email at submit time was the
     * whole of it. Levels 2..N are not involved at submit time, so under the old design their
     * items would appear in an Approvals list unannounced and the batch would sit there. This
     * is the repair, and it is deliberately the same shape as the submit-time notification —
     * one email per distinct approver per event, not one per invitee.
     *
     * Called by the Invitee_Level_Advanced flow through ApprovalLevelNotifier, on the update
     * that each approval step's field update makes to Current_Level__c.
     *
     * Rows that are no longer pending, and levels with no approver (a skipped tail step),
     * are dropped rather than notified: both are states the chain reaches normally.
     */
    public static void notifyLevelApprovers(List<Id> inviteeIds) {
        if (inviteeIds == null || inviteeIds.isEmpty()) {
            return;
        }

        // event -> approver -> how many invitees have just landed on them
        Map<Id, Map<Id, Integer>> byEventThenApprover = new Map<Id, Map<Id, Integer>>();
        for (Event_Invitee__c inv : [
            SELECT
                Id,
                Marketing_Event__c,
                Status__c,
                Current_Level__c,
                Approver_1__c,
                Approver_2__c,
                Approver_3__c,
                Approver_4__c,
                Approver_5__c
            FROM Event_Invitee__c
            WHERE Id IN :inviteeIds AND Status__c = 'Pending Approval' AND Current_Level__c > 1
        ]) {
            Id approver = approverAt(inv, inv.Current_Level__c.intValue());
            if (approver == null) {
                continue;
            }
            Map<Id, Integer> forEvent = byEventThenApprover.get(inv.Marketing_Event__c);
            if (forEvent == null) {
                forEvent = new Map<Id, Integer>();
                byEventThenApprover.put(inv.Marketing_Event__c, forEvent);
            }
            Integer soFar = forEvent.containsKey(approver) ? forEvent.get(approver) : 0;
            forEvent.put(approver, soFar + 1);
        }
        if (byEventThenApprover.isEmpty()) {
            return;
        }

        Map<Id, Marketing_Event__c> events = new Map<Id, Marketing_Event__c>(
            [SELECT Id, Name FROM Marketing_Event__c WHERE Id IN :byEventThenApprover.keySet()]
        );
        List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();
        for (Id eventId : byEventThenApprover.keySet()) {
            Marketing_Event__c evt = events.get(eventId);
            if (evt == null) {
                continue;
            }
            Map<Id, Integer> forEvent = byEventThenApprover.get(eventId);
            for (Id approverId : forEvent.keySet()) {
                String title = 'Approval requested: ' + evt.Name;
                String body =
                    forEvent.get(approverId) +
                    ' invitee(s) for "' +
                    evt.Name +
                    '" have been approved at the level below yours and are now waiting on you. ' +
                    'Open the event, or your Approvals list, to approve or reject.';
                emails.add(buildEmail(approverId, title, body, evt.Id));
                sendBell(approverId, title, body, evt.Id);
                levelNotificationsSent++;
            }
        }
        sendEmails(emails);
    }

    /** The Approver_N__c field for a level, without five branches at every call site. */
    private static Id approverAt(Event_Invitee__c inv, Integer level) {
        switch on level {
            when 1 {
                return inv.Approver_1__c;
            }
            when 2 {
                return inv.Approver_2__c;
            }
            when 3 {
                return inv.Approver_3__c;
            }
            when 4 {
                return inv.Approver_4__c;
            }
            when 5 {
                return inv.Approver_5__c;
            }
            when else {
                return null;
            }
        }
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
            'The approved list is in the "Approved Invitees" reports, under the Event Management report folder.';
        sendEmails(new List<Messaging.SingleEmailMessage>{ buildEmail(amId, title, body, evt.Id) });
        sendBell(amId, title, body, evt.Id);
        completionsSent++;
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
