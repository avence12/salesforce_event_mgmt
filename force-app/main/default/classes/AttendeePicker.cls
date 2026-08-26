/**
 * ★R13 "Which attendees can still be put forward on this event?" — one question, asked from
 * two screens.
 *
 * It was Screen 3's private business until R13 let an approver add people from Screen 4b. The
 * extraction is the same move R12 made with InviteeSnapshot and for the same reason: the cap,
 * the probe row that detects truncation and the ordering are decisions, not incidental code,
 * and two copies of them drift the first time one is tuned.
 *
 * **The one thing the two screens genuinely disagree about is Rejected**, and the disagreement
 * is the whole reason this class takes a parameter rather than being a single method:
 *
 *   selectable() — Screen 3, the AM. A rejected invitee reappears in the list, and re-adding
 *                  one resets the existing row to Draft. Re-proposing somebody an approver
 *                  turned down is the AM's prerogative and always has been.
 *   addable()    — Screen 4b, the approver. A rejected row stays rejected. An approver adding
 *                  people mid-review must not be able to quietly undo a rejection — their own
 *                  or, worse, somebody else's — by ticking a name in a picker. The remedy for
 *                  a rejection that should not have happened is the AM re-adding the person,
 *                  where it is visible as a fresh proposal.
 *
 * Both are `with sharing` and both are bounded. Neither reads a standard object.
 */
public with sharing class AttendeePicker {
    /** One attendee as either screen's picker shows them. */
    public class Attendee {
        @AuraEnabled
        public Id attendeeId { get; set; }
        @AuraEnabled
        public String name { get; set; }
        @AuraEnabled
        public String title { get; set; }
        @AuraEnabled
        public String email { get; set; }
        @AuraEnabled
        public String company { get; set; }
    }

    /** Wrapper so a truncated list can say so — a silently short list reads as "that's everyone". */
    public class Page {
        @AuraEnabled
        public List<Attendee> attendees { get; set; }
        @AuraEnabled
        public Boolean truncated { get; set; }
        @AuraEnabled
        public Integer cap { get; set; }
    }

    /** Most attendees either picker will hand back in one call. */
    public static final Integer CAP = 2000;

    /** Screen 3. Everyone not on this event, plus anyone whose row here was rejected. */
    public static Page selectable(Id eventId) {
        return page(eventId, true);
    }

    /** ★R13 Screen 4b. Everyone with no row on this event at all — a rejection still blocks. */
    public static Page addable(Id eventId) {
        return page(eventId, false);
    }

    /**
     * Attendees this event does not already have a row for.
     *
     * `offerRejected` decides whether a Rejected row counts as "already has one". Everything
     * else — the cap, the probe, the ordering — is identical between the two callers on
     * purpose: an attendee that sorts one way for an AM and another way for an approver would
     * be two lists of the same thing.
     */
    private static Page page(Id eventId, Boolean offerRejected) {
        Page res = new Page();
        res.attendees = new List<Attendee>();
        res.truncated = false;
        res.cap = CAP;

        Set<Id> blocked = blockedAttendeeIds(eventId, offerRejected);

        // One row past the cap: if it comes back, there are more than we are showing.
        Integer probe = CAP + 1;
        List<Event_Attendee__c> found = [
            SELECT Id, Name, Title__c, Email__c, Company__c
            FROM Event_Attendee__c
            WHERE Id NOT IN :blocked
            ORDER BY Company__c, Name
            LIMIT :probe
        ];
        if (found.size() > CAP) {
            res.truncated = true;
            found.remove(CAP); // drop the probe row
        }

        for (Event_Attendee__c a : found) {
            Attendee sa = new Attendee();
            sa.attendeeId = a.Id;
            sa.name = a.Name;
            sa.title = a.Title__c;
            sa.email = a.Email__c;
            // Grouping key is the Company *text*: two spellings of one organisation
            // group separately, which is accepted for the PoC — there is no record
            // to key on, by design.
            sa.company = a.Company__c;
            res.attendees.add(sa);
        }
        return res;
    }

    /**
     * Attendees already on the event.
     *
     * The status list is spelled out rather than written as `!= 'Rejected'` because the two
     * callers differ by exactly one value, and a list makes that difference the data it is.
     */
    private static Set<Id> blockedAttendeeIds(Id eventId, Boolean offerRejected) {
        List<String> blocking = new List<String>{ 'Draft', 'Pending Approval', 'Approved' };
        if (!offerRejected) {
            blocking.add('Rejected');
        }

        Set<Id> ids = new Set<Id>();
        for (Event_Invitee__c inv : [
            SELECT Event_Attendee__c
            FROM Event_Invitee__c
            WHERE Marketing_Event__c = :eventId AND Status__c IN :blocking
        ]) {
            if (inv.Event_Attendee__c != null) {
                ids.add(inv.Event_Attendee__c);
            }
        }
        return ids;
    }
}
