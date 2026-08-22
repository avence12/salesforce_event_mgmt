/**
 * ★R12 The one place an Event_Invitee__c's snapshot fields are written from its
 * Event_Attendee__c.
 *
 * It exists because R12 gave the stamping a second caller. Until then only
 * InviteeSelectorController stamped, at add time, and the logic lived there as a
 * private method. R12 lets an attendee edit re-stamp invitees already added
 * (EventAttendeeSync), and two copies of "which attendee field lands in which invitee
 * field" would drift the first time one of them gained a field — silently, because
 * nothing compares them.
 *
 * WHAT IS SNAPSHOTTED AND WHY IT IS NOT A FORMULA is on Invitee_Title__c's description,
 * not repeated here. The short version: an approval record must not change after the
 * decision, so these are stamps rather than live references.
 *
 * The split into two methods is the whole of R12's per-status rule:
 *
 *   stamp()        — everything, including the routing fields. Correct only where
 *                    nothing has been submitted: add time, a re-add, and a Draft row.
 *   stampDisplay() — the four fields a human reads and nothing that steers approval.
 *                    Correct for a Pending row, whose approver chain is already frozen
 *                    onto Approver_1..5__c and must not be contradicted by the row's
 *                    own Account_Manager__c moving underneath it.
 *
 * There is deliberately no method for Approved or Rejected. Those rows are never
 * re-stamped, and the absence of a method is the enforcement.
 */
public with sharing class InviteeSnapshot {
    /**
     * Every field the invitee snapshots, routing included.
     *
     * The attendee must have been queried with Salutation__c, Title__c, Company__c,
     * Cust_Cd__c and Contact__r.Account's Id, Name and OwnerId. A field the caller did
     * not select is stamped as null rather than raising, so both call sites carry a
     * comment pointing here.
     */
    public static void stamp(Event_Invitee__c inv, Event_Attendee__c attendee) {
        stampDisplay(inv, attendee);

        Account customer = attendee.Contact__r == null ? null : attendee.Contact__r.Account;
        inv.Account__c = customer == null ? null : customer.Id;
        inv.Account_Manager__c = customer == null ? null : customer.OwnerId;
    }

    /**
     * What an approver reads: who the person is, what they do, who they work for, and
     * under which customer code. None of it can reroute an approval in flight.
     *
     * ★R12 Cust_Cd__c comes from the attendee, which got it from the CSV — not from
     * Account.AccountNumber as it did in R8. The import matches the Contact *using* the
     * code, so reading the code back off the matched Account would be circular. The
     * consequence worth knowing: a guest who matched no Contact still has a code here,
     * where under R8 they had none.
     */
    public static void stampDisplay(Event_Invitee__c inv, Event_Attendee__c attendee) {
        inv.Invitee_Salutation__c = attendee.Salutation__c;
        inv.Invitee_Title__c = attendee.Title__c;
        inv.Cust_Cd__c = attendee.Cust_Cd__c;

        // The Account's name wins over the imported company text where there is an
        // Account, because "Acme Corporation" spelled the org's way beats whatever the
        // conference organiser typed. Which source was used stays legible from whether
        // Account__c is populated — see Invitee_Org__c's description.
        Account customer = attendee.Contact__r == null ? null : attendee.Contact__r.Account;
        inv.Invitee_Org__c = customer == null ? attendee.Company__c : customer.Name;
    }
}
