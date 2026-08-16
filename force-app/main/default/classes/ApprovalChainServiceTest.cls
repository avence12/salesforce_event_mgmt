/**
 * ★R9 The approval chain, tested away from the workflow that uses it.
 *
 * Two hierarchies, because the interesting cases need both. One ends in a Regional Head
 * with somebody above them, which is the only way to prove the chain stops rather than
 * merely runs out; the other is four plain managers with no titles at all, which is the
 * only way to prove the level cap and the submitter exclusion do what they claim without a
 * Regional Head quietly ending the walk first.
 *
 * Every test sets the configuration explicitly. Reading the shipped Default record instead
 * would make these tests assert what an administrator last typed into Setup.
 */
@IsTest
private class ApprovalChainServiceTest {
    private static User findUser(String alias) {
        return [SELECT Id, Name, Title, ManagerId, IsActive FROM User WHERE Alias = :alias LIMIT 1];
    }

    private static User draftUser(String alias, String title) {
        return new User(
            Alias = alias,
            Username = alias + '.' + System.currentTimeMillis() + '@evtmgmt.poc.test',
            Email = alias + '@evtmgmt.poc.test',
            LastName = alias,
            Title = title,
            ProfileId = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1]
            .Id,
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            TimeZoneSidKey = 'America/New_York'
        );
    }

    @TestSetup
    static void setup() {
        Map<String, String> titles = new Map<String, String>{
            'chsub' => 'Account Manager',
            'chown' => 'Account Manager',
            'chmgr' => 'Sales Manager',
            // The marker is deliberately not the whole title: real ones carry a region, and
            // matching them is the reason isRegionalHead uses contains rather than equals.
            'chrh' => 'Regional Head, EMEA',
            'chceo' => 'Chief Executive',
            'chpa' => 'Account Manager',
            'chpb' => 'Manager',
            'chpc' => 'Senior Manager',
            'chpd' => 'Managing Director'
        };
        List<User> users = new List<User>();
        for (String alias : titles.keySet()) {
            users.add(draftUser(alias, titles.get(alias)));
        }

        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert users;
            Map<String, Id> byAlias = new Map<String, Id>();
            for (User u : users) {
                byAlias.put(u.Alias, u.Id);
            }
            update new List<User>{
                new User(Id = byAlias.get('chsub'), ManagerId = byAlias.get('chmgr')),
                new User(Id = byAlias.get('chown'), ManagerId = byAlias.get('chmgr')),
                new User(Id = byAlias.get('chmgr'), ManagerId = byAlias.get('chrh')),
                new User(Id = byAlias.get('chrh'), ManagerId = byAlias.get('chceo')),
                new User(Id = byAlias.get('chpa'), ManagerId = byAlias.get('chpb')),
                new User(Id = byAlias.get('chpb'), ManagerId = byAlias.get('chpc')),
                new User(Id = byAlias.get('chpc'), ManagerId = byAlias.get('chpd'))
            };
        }

        insert new Event_Attendee__c(
            Name = 'Chain Fixture',
            First_Name__c = 'Chain',
            Last_Name__c = 'Fixture',
            Company__c = 'Fixture Ltd',
            Unique_Key__c = 'fixture|chain|fixture ltd|'
        );
        insert new Marketing_Event__c(
            Name = 'Chain Fixture Event',
            Event_Date__c = Date.today().addDays(30),
            Event_Type__c = 'Conference'
        );
    }

    // Cached so that building a 40-row batch does not spend the query limit on scenery, and
    // so the query count this class measures is the walk's own.
    private static Id cachedEventId;
    private static Id cachedAttendeeId;

    private static Event_Invitee__c draftInvitee(Id accountOwnerId, String key) {
        if (cachedEventId == null) {
            cachedEventId = [SELECT Id FROM Marketing_Event__c LIMIT 1].Id;
            cachedAttendeeId = [SELECT Id FROM Event_Attendee__c LIMIT 1].Id;
        }
        return new Event_Invitee__c(
            Marketing_Event__c = cachedEventId,
            Event_Attendee__c = cachedAttendeeId,
            Status__c = 'Draft',
            Unique_Key__c = key,
            Account_Manager__c = accountOwnerId
        );
    }

    /** Chain resolution reads two fields off the row; the rest of the invitee is scenery. */
    private static Event_Invitee__c inviteeOwnedBy(Id accountOwnerId, String key) {
        Event_Invitee__c inv = draftInvitee(accountOwnerId, key);
        insert inv;
        return inv;
    }

    /** The shipped configuration, restated so no test depends on what Setup currently holds. */
    private static void configureAsShipped() {
        ApprovalChainService.titlesOverride = 'Regional Head';
        ApprovalChainService.levelsAboveOverride = 2;
    }

    private static List<Id> chainFor(Id accountOwnerId, Id submitterId, String key) {
        Event_Invitee__c inv = inviteeOwnedBy(accountOwnerId, key);
        return ApprovalChainService.resolve(new List<Event_Invitee__c>{ inv }, submitterId).get(inv.Id);
    }

    /** requirement.md's chain, in the order it names: Account Owner, then two managers up. */
    @IsTest
    static void theChainIsTheAccountOwnerThenTheirManagersUpward() {
        configureAsShipped();
        User owner = findUser('chpa');
        User submitter = findUser('chsub');

        Test.startTest();
        List<Id> chain = chainFor(owner.Id, submitter.Id, 'k-plain-three');
        Test.stopTest();

        System.assertEquals(3, chain.size(), 'One Account Owner plus the two levels above them');
        System.assertEquals(owner.Id, chain[0], 'Level 1 is the Account Owner');
        System.assertEquals(findUser('chpb').Id, chain[1], 'Level 2 is their manager');
        System.assertEquals(findUser('chpc').Id, chain[2], 'Level 3 is that manager’s manager');
        System.assertEquals(
            false,
            new Set<Id>(chain).contains(findUser('chpd').Id),
            'The fourth level exists in the org chart and must not be in the chain'
        );
    }

    /**
     * The requirement's early exit, and the reason the plain hierarchy exists: chpd is above
     * chpc and is not in the chain either, but only because of the level cap. Here the cap
     * would allow a third level and the Regional Head ends it anyway.
     */
    @IsTest
    static void theChainStopsAtTheFirstRegionalHeadItReaches() {
        configureAsShipped();
        User owner = findUser('chmgr'); // manager -> chrh (Regional Head) -> chceo
        User submitter = findUser('chsub');

        Test.startTest();
        List<Id> chain = chainFor(owner.Id, submitter.Id, 'k-stops-at-rh');
        Test.stopTest();

        System.assertEquals(2, chain.size(), 'Two levels, though the cap would have allowed three');
        System.assertEquals(owner.Id, chain[0]);
        System.assertEquals(findUser('chrh').Id, chain[1], 'The Regional Head signs');
        System.assertEquals(
            false,
            new Set<Id>(chain).contains(findUser('chceo').Id),
            'and the chain does not continue past them'
        );
    }

    /** A Regional Head who owns the account is the whole chain — one signature, correctly. */
    @IsTest
    static void anAccountOwnedByARegionalHeadNeedsOneApproval() {
        configureAsShipped();

        Test.startTest();
        List<Id> chain = chainFor(findUser('chrh').Id, findUser('chsub').Id, 'k-rh-owns');
        Test.stopTest();

        System.assertEquals(1, chain.size());
        System.assertEquals(findUser('chrh').Id, chain[0]);
    }

    /** No manager above the Account Owner is a complete chain of one, not a failure. */
    @IsTest
    static void aChainThatRunsOutOfManagersEndsWhereItRanOut() {
        configureAsShipped();

        Test.startTest();
        List<Id> chain = chainFor(findUser('chpd').Id, findUser('chsub').Id, 'k-top-of-tree');
        Test.stopTest();

        System.assertEquals(1, chain.size(), 'chpd has no manager, so the chain is just them');
    }

    /**
     * An AM inviting their own customer must not be the one who approves it.
     *
     * The second assertion is the one worth having: dropping the submitter shortens the
     * chain rather than sliding the window up. chpd is one level further up and stays out —
     * skipping a level must not buy another one at the top.
     */
    @IsTest
    static void theSubmitterIsNeverTheirOwnApproverAndTheChainDoesNotBackfill() {
        configureAsShipped();
        User owner = findUser('chpa');

        Test.startTest();
        List<Id> chain = chainFor(owner.Id, owner.Id, 'k-self-owned');
        Test.stopTest();

        System.assertEquals(2, chain.size(), 'Level 1 dropped, and the window did not slide up to refill it');
        System.assertEquals(findUser('chpb').Id, chain[0]);
        System.assertEquals(findUser('chpc').Id, chain[1]);
        System.assertEquals(
            false,
            new Set<Id>(chain).contains(findUser('chpd').Id),
            'A skipped level must not buy an extra one at the top'
        );
    }

    /** More levels later costs a setting, which is the whole reason the setting exists. */
    @IsTest
    static void theConfiguredLevelCapIsWhatDecidesHowFarTheChainClimbs() {
        ApprovalChainService.titlesOverride = 'Regional Head';
        User owner = findUser('chpa');
        User submitter = findUser('chsub');

        Test.startTest();
        ApprovalChainService.levelsAboveOverride = 0;
        System.assertEquals(1, chainFor(owner.Id, submitter.Id, 'k-cap-0').size(), 'Account Owner only');

        ApprovalChainService.levelsAboveOverride = 3;
        System.assertEquals(4, chainFor(owner.Id, submitter.Id, 'k-cap-3').size(), 'All four of the plain hierarchy');

        // Configuration cannot promise a level the metadata has no field or step for: a
        // stamped level 6 would be an approver nobody could ever act as.
        ApprovalChainService.levelsAboveOverride = 40;
        System.assertEquals(
            ApprovalChainService.MAX_PROVISIONED_LEVELS,
            ApprovalChainService.maxLevels(),
            'Clamped to the levels that actually exist'
        );
        Test.stopTest();
    }

    /** Blank markers are a valid setting: no early termination, climb the full cap. */
    @IsTest
    static void withNoTitleMarkersTheChainClimbsPastTheRegionalHead() {
        ApprovalChainService.titlesOverride = '';
        ApprovalChainService.levelsAboveOverride = 2;

        Test.startTest();
        List<Id> chain = chainFor(findUser('chmgr').Id, findUser('chsub').Id, 'k-no-markers');
        Test.stopTest();

        System.assertEquals(3, chain.size());
        System.assertEquals(findUser('chceo').Id, chain[2], 'Nothing marks anyone as a Regional Head now');
    }

    /** The state the bucket-account answer to Open Question 21 exists to prevent. */
    @IsTest
    static void anInviteeWithNoAccountOwnerIsRefused() {
        configureAsShipped();
        Event_Invitee__c inv = inviteeOwnedBy(null, 'k-no-owner');

        Boolean threw = false;
        String message = '';
        Test.startTest();
        try {
            ApprovalChainService.resolve(new List<Event_Invitee__c>{ inv }, findUser('chsub').Id);
        } catch (ApprovalChainService.UnroutableException e) {
            threw = true;
            message = e.getMessage();
        }
        Test.stopTest();

        System.assert(threw, 'No Account Owner means no chain, and that must be refused rather than guessed');
        System.assert(message.contains('no Account Owner'), 'The message names the cause: ' + message);
        System.assert(message.contains('Nothing was submitted'), 'and says nothing moved: ' + message);
    }

    /** An inactive approver can never act, so routing to them would stall the batch silently. */
    @IsTest
    static void anInactiveApproverInTheChainIsRefused() {
        configureAsShipped();
        User middle = findUser('chpb');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            update new User(Id = middle.Id, IsActive = false);
        }

        Boolean threw = false;
        String message = '';
        Test.startTest();
        try {
            chainFor(findUser('chpa').Id, findUser('chsub').Id, 'k-inactive');
        } catch (ApprovalChainService.UnroutableException e) {
            threw = true;
            message = e.getMessage();
        }
        Test.stopTest();

        System.assert(threw, 'A chain through an inactive user must not be submitted');
        System.assert(message.contains('inactive'), 'The message names the cause: ' + message);
    }

    /** Nobody but the submitter in the whole chain: refused, and told why it is not routable. */
    @IsTest
    static void aChainThatIsOnlyTheSubmitterIsRefused() {
        configureAsShipped();
        User top = findUser('chpd'); // owns the account, has no manager

        Boolean threw = false;
        String message = '';
        Test.startTest();
        try {
            chainFor(top.Id, top.Id, 'k-only-me');
        } catch (ApprovalChainService.UnroutableException e) {
            threw = true;
            message = e.getMessage();
        }
        Test.stopTest();

        System.assert(threw);
        System.assert(message.contains('the only person the chain reaches is you'), message);
    }

    /**
     * Bulk safety. Forty invitees across three customers must cost the same three queries
     * as one invitee does — the walk is per distinct Account Owner, not per row.
     */
    @IsTest
    static void inviteesSharingACustomerShareOneWalk() {
        configureAsShipped();
        Id plainOwner = findUser('chpa').Id;
        Id regionalOwner = findUser('chmgr').Id;
        List<Event_Invitee__c> batch = new List<Event_Invitee__c>();
        for (Integer i = 0; i < 20; i++) {
            batch.add(draftInvitee(plainOwner, 'k-bulk-a-' + i));
            batch.add(draftInvitee(regionalOwner, 'k-bulk-b-' + i));
        }
        insert batch;

        Test.startTest();
        Integer before = Limits.getQueries();
        Map<Id, List<Id>> chains = ApprovalChainService.resolve(batch, findUser('chsub').Id);
        Integer used = Limits.getQueries() - before;
        Test.stopTest();

        System.assertEquals(40, chains.size());
        System.assertEquals(3, chains.get(batch[0].Id).size(), 'The plain hierarchy: three levels');
        System.assertEquals(2, chains.get(batch[1].Id).size(), 'The one ending at a Regional Head: two');
        System.assert(used <= 3, 'One query per generation, never one per invitee — used ' + used);
    }

    /** stamp() is where the field names live, so it is where they are tested. */
    @IsTest
    static void stampWritesTheChainAcrossTheNumberedFieldsAndClearsThemAgain() {
        configureAsShipped();
        Event_Invitee__c inv = new Event_Invitee__c();
        List<Id> chain = new List<Id>{ findUser('chpa').Id, findUser('chpb').Id };

        Test.startTest();
        ApprovalChainService.stamp(inv, chain);
        Test.stopTest();

        System.assertEquals(chain[0], inv.Approver_1__c);
        System.assertEquals(chain[1], inv.Approver_2__c);
        System.assertEquals(null, inv.Approver_3__c, 'Unused levels stay blank so their steps are skipped');
        System.assertEquals(2, inv.Approval_Levels__c.intValue());

        // The reset path: a re-added invitee must not carry last round's approvers.
        ApprovalChainService.stamp(inv, null);
        System.assertEquals(null, inv.Approver_1__c);
        System.assertEquals(null, inv.Approver_2__c);
        System.assertEquals(null, inv.Approval_Levels__c);
    }

    /** A title is a string an org types by hand; the matcher has to survive that. */
    @IsTest
    static void regionalHeadMatchingIsCaseInsensitiveAndIgnoresSurroundingWords() {
        ApprovalChainService.titlesOverride = 'Regional Head, Country Head';

        Test.startTest();
        System.assertEquals(true, ApprovalChainService.isRegionalHead(new User(Title = 'REGIONAL HEAD')));
        System.assertEquals(true, ApprovalChainService.isRegionalHead(new User(Title = 'Regional Head, APAC')));
        System.assertEquals(true, ApprovalChainService.isRegionalHead(new User(Title = 'Country Head (Germany)')));
        System.assertEquals(false, ApprovalChainService.isRegionalHead(new User(Title = 'Head of Sales')));
        System.assertEquals(false, ApprovalChainService.isRegionalHead(new User(Title = null)));
        Test.stopTest();
    }
}
