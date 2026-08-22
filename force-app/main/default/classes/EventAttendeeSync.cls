/**
 * ★R12 Keeps an invitee's snapshot in step with its attendee — for exactly as long as
 * the invitation is still undecided.
 *
 * THE PROBLEM THIS SOLVES, and it is narrower than "the fields should match". R8 froze
 * Invitee_Salutation__c, Invitee_Title__c and Invitee_Org__c into snapshots so that
 * correcting an attendee could not rewrite what an approval appeared to show. That
 * argument is airtight for an Approved row and vacuous for a Draft one: a Draft has been
 * approved by nobody, so a frozen typo protects no record and simply guarantees the
 * approver reads stale data when it is finally submitted. R8 took the whole trade
 * because it was choosing between a formula and a snapshot, and a formula cannot ask
 * what status the row is in. A trigger can.
 *
 * The rule, per status:
 *
 *   Draft              full re-stamp, routing fields included. Nothing is frozen.
 *   Pending Approval   display fields only. The approver chain was resolved and frozen
 *                      onto Approver_1..5__c at submit; re-stamping Account_Manager__c
 *                      underneath it would leave the row naming one approver while
 *                      addressed to another.
 *   Approved/Rejected  never. This is the case R8 was arguing about and R8 still wins.
 *
 * WHY IT IS NOT A FORMULA FIELD: a formula would sync all four statuses, which is the
 * Approved case above. The automation is not a more expensive formula — it exists
 * because the correct behaviour is conditional.
 *
 * WHAT IT DOES NOT TOUCH: Attended__c, Status__c, the approver chain, and every standard
 * object. It writes Event_Invitee__c and nothing else, which keeps the CLAUDE.md
 * invariant intact by construction rather than by care.
 */
public with sharing class EventAttendeeSync {
    /** Statuses that still accept a re-stamp, and how much of one. */
    private static final Set<String> FULL = new Set<String>{ 'Draft' };
    private static final Set<String> DISPLAY_ONLY = new Set<String>{ 'Pending Approval' };

    /**
     * Re-stamps the open invitees of every attendee whose snapshotted data changed.
     *
     * Called from the after-update trigger. `oldMap` is what makes this cheap: an
     * attendee edit that touches none of the snapshotted fields — a phone number, an
     * address, a re-import refreshing Source_File__c — queries nothing and writes
     * nothing, which matters because a re-upload of an 8,000-row file updates every
     * attendee in it.
     */
    public static void onAfterUpdate(List<Event_Attendee__c> updated, Map<Id, Event_Attendee__c> oldMap) {
        Set<Id> changed = new Set<Id>();
        for (Event_Attendee__c a : updated) {
            if (snapshotDataChanged(a, oldMap.get(a.Id))) {
                changed.add(a.Id);
            }
        }
        if (changed.isEmpty()) {
            return;
        }

        // Re-queried rather than trusting the trigger's records: the snapshot reads
        // Contact__r.Account, and a trigger's sObjects carry no parent relationships.
        // The select must cover everything InviteeSnapshot reads — see that class.
        Map<Id, Event_Attendee__c> attendees = new Map<Id, Event_Attendee__c>(
            [
                SELECT
                    Id,
                    Salutation__c,
                    Title__c,
                    Company__c,
                    Cust_Cd__c,
                    Contact__r.AccountId,
                    Contact__r.Account.Name,
                    Contact__r.Account.OwnerId
                FROM Event_Attendee__c
                WHERE Id IN :changed
            ]
        );

        Set<String> open = new Set<String>(FULL);
        open.addAll(DISPLAY_ONLY);

        List<Event_Invitee__c> toUpdate = new List<Event_Invitee__c>();
        for (Event_Invitee__c inv : [
            SELECT
                Id,
                Status__c,
                Event_Attendee__c,
                Invitee_Salutation__c,
                Invitee_Title__c,
                Invitee_Org__c,
                Cust_Cd__c,
                Account__c,
                Account_Manager__c
            FROM Event_Invitee__c
            WHERE Event_Attendee__c IN :changed AND Status__c IN :open
        ]) {
            Event_Attendee__c attendee = attendees.get(inv.Event_Attendee__c);
            if (attendee == null) {
                continue;
            }
            if (FULL.contains(inv.Status__c)) {
                InviteeSnapshot.stamp(inv, attendee);
            } else {
                InviteeSnapshot.stampDisplay(inv, attendee);
            }
            toUpdate.add(inv);
        }

        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
    }

    /**
     * Whether this edit moved anything an invitee snapshots.
     *
     * Company__c counts even though an invitee with an Account never displays it — the
     * same attendee may also have invitees with no Account behind them, and those do.
     * Contact__c counts because it is what decides between the two sources, and because
     * the import can now set it on a re-upload that matched where the first one did not.
     */
    private static Boolean snapshotDataChanged(Event_Attendee__c current, Event_Attendee__c previous) {
        return current.Salutation__c != previous.Salutation__c ||
            current.Title__c != previous.Title__c ||
            current.Company__c != previous.Company__c ||
            current.Cust_Cd__c != previous.Cust_Cd__c ||
            current.Contact__c != previous.Contact__c;
    }
}
