/**
 * ★R9 Resolves the approval chain for a batch of invitees, once, at submit time.
 *
 * requirement.md defines the chain and this class is the whole of it:
 *
 *   Level 1  the Account Owner of the customer the invitee belongs to
 *            (Event_Invitee__c.Account_Manager__c, snapshotted when the row was added)
 *   Level 2  that person's manager, from User.ManagerId
 *   Level 3  their manager in turn
 *            ... for at most Max_Levels_Above_Account_Owner__c levels above level 1
 *
 * and it stops early at the first Regional Head it reaches, who is the last approver
 * rather than one more rung to climb past.
 *
 * **Why the org chart and not a routing table.** design.md's R7 designed this as a
 * cust_cd-keyed Approval_Route__c object and explicitly rejected walking User.ManagerId,
 * on the grounds that an approval chain is usually not the HR reporting line and that a
 * stop condition would need a field on User, which this project does not own. requirement.md
 * — written after R7 — answers both points from the business's side: the chain *is* the
 * reporting line here, and the stop condition is a title the org already records. R7's
 * objection was sound about orgs in general and wrong about this one, so the walk wins and
 * no route table is built. What the business gives up by that choice is a chain it can edit
 * as data: changing who approves now means changing the org chart or the titles on it.
 *
 * **Frozen, and that matters more than it did.** The whole chain is stamped onto the invitee
 * at submit time and never recomputed. A reorganisation halfway up a three-level chain must
 * not reroute an item somebody is already looking at, and with three levels there is a great
 * deal more halfway to be in than there was with one.
 *
 * **Failure is refused, not routed around.** Every way of failing to resolve a chain — no
 * Account Owner, an inactive approver, a chain that is only the submitter — raises
 * UnroutableException and the caller submits nothing. The tempting alternative, quietly
 * falling back to the submitter's manager, converts a data-quality problem into a weaker
 * approval than the business asked for, which is the one thing this workflow exists to
 * prevent.
 */
public with sharing class ApprovalChainService {
    /**
     * How many Approver_N__c fields exist on Event_Invitee__c, and therefore how many steps
     * the approval process can address. Configuration above this is clamped rather than
     * obeyed: stamping a level nobody can approve would create an invitee that never finishes.
     */
    public static final Integer MAX_PROVISIONED_LEVELS = 5;

    private static final String SETTING_NAME = 'Default';
    private static final String DEFAULT_REGIONAL_HEAD_TITLES = 'Regional Head';
    private static final Integer DEFAULT_LEVELS_ABOVE = 2;

    /** Raised when a batch cannot be routed. The message is written for the AM, not the log. */
    public class UnroutableException extends Exception {
    }

    // Test hooks. The shipped Default record is the org's answer, and a test that depended on
    // it would be asserting the configuration rather than the walk.
    @TestVisible
    private static String titlesOverride;
    @TestVisible
    private static Integer levelsAboveOverride;

    /**
     * The chain for each invitee, in level order.
     *
     * Invitees must be queried with Account_Manager__c and Invitee_Name__c. Two invitees
     * belonging to the same customer share a chain, so the walk runs once per distinct
     * Account Owner rather than once per row.
     */
    public static Map<Id, List<Id>> resolve(List<Event_Invitee__c> invitees, Id submitterId) {
        List<String> noOwner = new List<String>();
        Set<Id> seeds = new Set<Id>();
        for (Event_Invitee__c inv : invitees) {
            if (inv.Account_Manager__c == null) {
                noOwner.add(labelOf(inv));
            } else {
                seeds.add(inv.Account_Manager__c);
            }
        }
        if (!noOwner.isEmpty()) {
            throw new UnroutableException(
                noOwner.size() +
                    ' of your ' +
                    invitees.size() +
                    ' invitee(s) have no Account Owner, so there is nobody to start their approval chain: ' +
                    listOf(noOwner) +
                    '. An invitee acquires one through the attendee’s Contact link — guests who are nobody’s ' +
                    'customer belong to the account your administrator keeps for them. Nothing was submitted.'
            );
        }

        Map<Id, List<Id>> chainBySeed = walkFrom(seeds, submitterId);

        Map<Id, List<Id>> out = new Map<Id, List<Id>>();
        for (Event_Invitee__c inv : invitees) {
            out.put(inv.Id, chainBySeed.get(inv.Account_Manager__c));
        }
        return out;
    }

    /**
     * Writes a resolved chain onto an invitee.
     *
     * Kept here rather than in the caller so that exactly one class knows the Approver_N__c
     * fields exist — adding a sixth level should be a change to this file and the metadata,
     * not a hunt through the controllers.
     */
    public static void stamp(Event_Invitee__c inv, List<Id> chain) {
        inv.Approver_1__c = levelOrNull(chain, 1);
        inv.Approver_2__c = levelOrNull(chain, 2);
        inv.Approver_3__c = levelOrNull(chain, 3);
        inv.Approver_4__c = levelOrNull(chain, 4);
        inv.Approver_5__c = levelOrNull(chain, 5);
        inv.Approval_Levels__c = chain == null ? null : chain.size();
    }

    /** Total levels a chain may have at the current configuration, clamped to what exists. */
    public static Integer maxLevels() {
        Integer above = levelsAboveOverride != null ? levelsAboveOverride : configuredLevelsAbove();
        if (above < 0) {
            above = 0;
        }
        Integer total = above + 1;
        return total > MAX_PROVISIONED_LEVELS ? MAX_PROVISIONED_LEVELS : total;
    }

    // ---------- the walk ----------

    private static Map<Id, List<Id>> walkFrom(Set<Id> seeds, Id submitterId) {
        Integer limitLevels = maxLevels();
        Map<Id, User> known = climb(seeds, limitLevels);

        Map<Id, List<Id>> out = new Map<Id, List<Id>>();
        List<String> inactive = new List<String>();
        Boolean unreadable = false;
        Boolean onlyTheSubmitter = false;

        for (Id seed : seeds) {
            List<Id> chain = new List<Id>();
            Set<Id> visited = new Set<Id>();
            Id cursor = seed;
            Integer position = 0;

            // `position` counts places in the org chart, not approvers. Dropping the submitter
            // shortens the chain rather than sliding the window up: requirement.md caps the
            // chain at N levels above the Account Owner, and skipping a level must not buy
            // another one at the top.
            while (cursor != null && position < limitLevels && !visited.contains(cursor)) {
                visited.add(cursor);
                position++;

                User u = known.get(cursor);
                if (u == null) {
                    // A manager this user cannot see. Truncating the chain here would approve
                    // with fewer signatures than the business asked for and say nothing.
                    unreadable = true;
                    break;
                }
                if (!u.IsActive) {
                    inactive.add(u.Name);
                    break;
                }
                if (cursor != submitterId) {
                    chain.add(cursor);
                }
                if (isRegionalHead(u)) {
                    break; // the Regional Head signs; the chain does not continue past them
                }
                cursor = u.ManagerId;
            }

            if (chain.isEmpty()) {
                onlyTheSubmitter = true;
            }
            out.put(seed, chain);
        }

        // Reported in this order on purpose: a chain that came out empty *because* it hit an
        // inactive user should say so, not blame the submitter's missing manager.
        if (!inactive.isEmpty()) {
            throw new UnroutableException(
                'The approval chain reaches an inactive user: ' +
                    listOf(inactive) +
                    '. An inactive approver can never act, so the request would sit in their queue for ever. ' +
                    'Ask an administrator to reassign the account or update the reporting line. Nothing was submitted.'
            );
        }
        if (unreadable) {
            throw new UnroutableException(
                'The approval chain could not be read in full — one of the users above the Account Owner ' +
                    'is not visible to you. Submitting now would route to fewer approvers than the chain has. ' +
                    'Ask an administrator to check user visibility. Nothing was submitted.'
            );
        }
        if (onlyTheSubmitter) {
            throw new UnroutableException(
                'No approver could be determined: the only person the chain reaches is you. ' +
                    'An Account Owner cannot approve their own submission, so this needs a Manager ' +
                    'set on your user record. Ask an administrator. Nothing was submitted.'
            );
        }
        return out;
    }

    /**
     * Fetches the seeds and up to `limitLevels - 1` generations of managers above them.
     *
     * One query per generation and never one per invitee: a 200-row batch spanning four
     * customers costs the same three queries as a single row does.
     */
    private static Map<Id, User> climb(Set<Id> seeds, Integer limitLevels) {
        Map<Id, User> known = new Map<Id, User>();
        Set<Id> wanted = new Set<Id>(seeds);

        for (Integer generation = 0; generation < limitLevels && !wanted.isEmpty(); generation++) {
            Map<Id, User> fetched = new Map<Id, User>(
                [SELECT Id, Name, Title, IsActive, ManagerId FROM User WHERE Id IN :wanted]
            );
            known.putAll(fetched);

            Set<Id> next = new Set<Id>();
            for (User u : fetched.values()) {
                if (u.ManagerId != null && !known.containsKey(u.ManagerId)) {
                    next.add(u.ManagerId);
                }
            }
            wanted = next;
        }
        return known;
    }

    /**
     * Substring, case-insensitive, against User.Title.
     *
     * Real titles carry a region — "Regional Head, EMEA" — so equality would match nobody.
     * The looseness is the point and its cost is recorded on the configuration field.
     */
    @TestVisible
    private static Boolean isRegionalHead(User u) {
        if (String.isBlank(u.Title)) {
            return false;
        }
        String title = u.Title.toLowerCase();
        for (String marker : regionalHeadMarkers()) {
            if (title.contains(marker)) {
                return true;
            }
        }
        return false;
    }

    // ---------- configuration ----------

    private static List<String> regionalHeadMarkers() {
        String raw = titlesOverride != null ? titlesOverride : configuredTitles();
        List<String> markers = new List<String>();
        if (String.isBlank(raw)) {
            return markers; // no markers = no early termination, which is a valid setting
        }
        for (String part : raw.split(',')) {
            String marker = part.trim().toLowerCase();
            if (String.isNotBlank(marker)) {
                markers.add(marker);
            }
        }
        return markers;
    }

    private static String configuredTitles() {
        Approval_Chain_Setting__mdt s = setting();
        return s == null ? DEFAULT_REGIONAL_HEAD_TITLES : s.Regional_Head_Titles__c;
    }

    private static Integer configuredLevelsAbove() {
        Approval_Chain_Setting__mdt s = setting();
        if (s == null || s.Max_Levels_Above_Account_Owner__c == null) {
            return DEFAULT_LEVELS_ABOVE;
        }
        return s.Max_Levels_Above_Account_Owner__c.intValue();
    }

    /** Null when the record was never deployed — the constants above are then the answer. */
    private static Approval_Chain_Setting__mdt setting() {
        return Approval_Chain_Setting__mdt.getInstance(SETTING_NAME);
    }

    // ---------- small helpers ----------

    private static Id levelOrNull(List<Id> chain, Integer level) {
        return (chain != null && chain.size() >= level) ? chain[level - 1] : null;
    }

    private static String labelOf(Event_Invitee__c inv) {
        return String.isBlank(inv.Invitee_Name__c) ? 'an invitee' : inv.Invitee_Name__c;
    }

    /** "Alice, Bob and 3 more" — an error naming forty people is one nobody reads. */
    private static String listOf(List<String> names) {
        if (names.size() <= 3) {
            return String.join(names, ', ');
        }
        List<String> head = new List<String>{ names[0], names[1], names[2] };
        return String.join(head, ', ') + ' and ' + (names.size() - 3) + ' more';
    }
}
