/**
 * ★R8 Screen 4b — the approver's company-grouped view and the bulk decision behind it.
 *
 * ★R9 The fixture is two customers owned by one account manager and a third owned by
 * somebody else, above a shared reporting line:
 *
 *   Acme Corporation, Globex   owned by apowner ┐
 *   Nordbank AG                owned by apother ┴→ apdana → aprhead ("Regional Head, EMEA")
 *
 * That shape carries every question this screen has to answer. One approver with several
 * companies is what the grouping is for; a row owned by somebody else is what the
 * server-side re-scoping is for; and a shared level 2 is what proves the screen shows a
 * level-2 approver nothing until the level below them has signed — the one behaviour a
 * chain adds and a field comparison would have got wrong.
 */
@IsTest
private class InviteeApprovalControllerTest {
    private static User findUser(String alias) {
        return [SELECT Id, Name, ManagerId FROM User WHERE Alias = :alias AND IsActive = TRUE LIMIT 1];
    }

    private static Event_Attendee__c attendee(String first, String last, String company) {
        return new Event_Attendee__c(
            Name = first + ' ' + last,
            First_Name__c = first,
            Last_Name__c = last,
            Email__c = first.toLowerCase() + '@evt.example',
            Title__c = 'Attendee',
            Salutation__c = 'Dr',
            Company__c = company,
            Unique_Key__c = (last + '|' + first + '|' + company).toLowerCase()
        );
    }

    private static Id attendeeId(String lastName) {
        return [SELECT Id FROM Event_Attendee__c WHERE Last_Name__c = :lastName LIMIT 1].Id;
    }

    private static Marketing_Event__c theEvent() {
        return [SELECT Id, Name FROM Marketing_Event__c LIMIT 1];
    }

    private static void configureChain() {
        ApprovalChainService.titlesOverride = 'Regional Head';
        ApprovalChainService.levelsAboveOverride = 2;
    }

    @TestSetup
    static void setup() {
        Profile std = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        Map<String, String> titles = new Map<String, String>{
            'apalex' => 'Account Manager',
            'apowner' => 'Account Manager',
            'apother' => 'Account Manager',
            'apdana' => 'Sales Manager',
            'aprhead' => 'Regional Head, EMEA'
        };
        List<User> users = new List<User>();
        for (String alias : titles.keySet()) {
            users.add(
                new User(
                    Alias = alias,
                    Username = alias + '.' + System.currentTimeMillis() + '@evtmgmt.poc.test',
                    Email = alias + '@evtmgmt.poc.test',
                    LastName = alias,
                    Title = titles.get(alias),
                    ProfileId = std.Id,
                    EmailEncodingKey = 'UTF-8',
                    LanguageLocaleKey = 'en_US',
                    LocaleSidKey = 'en_US',
                    TimeZoneSidKey = 'America/New_York'
                )
            );
        }

        Map<String, Id> byAlias = new Map<String, Id>();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert users;
            for (User u : users) {
                byAlias.put(u.Alias, u.Id);
            }
            update new List<User>{
                new User(Id = byAlias.get('apalex'), ManagerId = byAlias.get('apdana')),
                new User(Id = byAlias.get('apowner'), ManagerId = byAlias.get('apdana')),
                new User(Id = byAlias.get('apother'), ManagerId = byAlias.get('apdana')),
                new User(Id = byAlias.get('apdana'), ManagerId = byAlias.get('aprhead'))
            };
        }

        List<Account> customers = new List<Account>{
            new Account(Name = 'Acme Corporation', AccountNumber = 'CUST-0042', OwnerId = byAlias.get('apowner')),
            new Account(Name = 'Globex', AccountNumber = 'CUST-0055', OwnerId = byAlias.get('apowner')),
            new Account(Name = 'Nordbank AG', AccountNumber = 'CUST-0077', OwnerId = byAlias.get('apother'))
        };
        insert customers;
        List<Contact> people = new List<Contact>{
            new Contact(FirstName = 'Emily', LastName = 'Carter', AccountId = customers[0].Id),
            new Contact(FirstName = 'Robert', LastName = 'Kim', AccountId = customers[0].Id),
            new Contact(FirstName = 'Lena', LastName = 'Farrow', AccountId = customers[1].Id),
            new Contact(FirstName = 'James', LastName = 'Mueller', AccountId = customers[2].Id)
        };
        insert people;

        List<Event_Attendee__c> attendees = new List<Event_Attendee__c>{
            attendee('Emily', 'Carter', 'Acme Corp'),
            attendee('Robert', 'Kim', 'Acme Corp'),
            attendee('Lena', 'Farrow', 'Globex Inc'),
            attendee('James', 'Mueller', 'Nordbank AG'),
            attendee('Hélène', 'Dubois', 'Université de Genève')
        };
        insert attendees;
        for (Integer i = 0; i < 4; i++) {
            attendees[i].Contact__c = people[i].Id;
        }
        update attendees;

        insert new Marketing_Event__c(
            Name = 'Q4 2026 Risk Symposium',
            Event_Date__c = Date.today().addDays(45),
            Event_Type__c = 'Symposium'
        );
    }

    /** Adds and submits a batch as the given AM, leaving the rows pending on level 1. */
    private static void submitAs(User am, List<Id> attendeeIds) {
        configureChain();
        Marketing_Event__c evt = theEvent();
        System.runAs(am) {
            InviteeSelectorController.addAttendees(evt.Id, attendeeIds);
            InviteeSelectorController.submitMyInvitees(evt.Id);
        }
    }

    /** Approves one level as whoever currently holds the item — never as a named guess. */
    private static void approveOneLevel(Id inviteeId) {
        ProcessInstanceWorkitem item = [
            SELECT Id, ActorId
            FROM ProcessInstanceWorkitem
            WHERE ProcessInstance.TargetObjectId = :inviteeId
            LIMIT 1
        ];
        System.runAs(new User(Id = item.ActorId)) {
            Approval.ProcessWorkitemRequest req = new Approval.ProcessWorkitemRequest();
            req.setWorkitemId(item.Id);
            req.setAction('Approve');
            Approval.process(req);
        }
    }

    private static Map<String, InviteeApprovalController.CompanyGroup> groupsByCompany(
        List<InviteeApprovalController.CompanyGroup> groups
    ) {
        Map<String, InviteeApprovalController.CompanyGroup> out = new Map<String, InviteeApprovalController.CompanyGroup>();
        for (InviteeApprovalController.CompanyGroup g : groups) {
            out.put(g.company, g);
        }
        return out;
    }

    private static Id inviteeFor(String lastName) {
        return [SELECT Id FROM Event_Invitee__c WHERE Event_Attendee__r.Last_Name__c = :lastName LIMIT 1].Id;
    }

    @IsTest
    static void pendingWorkIsGroupedByTheCompanyTheyWereInvitedAs() {
        submitAs(findUser('apalex'), new List<Id>{ attendeeId('Carter'), attendeeId('Kim'), attendeeId('Farrow') });

        List<InviteeApprovalController.CompanyGroup> groups;
        System.runAs(findUser('apowner')) {
            groups = InviteeApprovalController.getMyPendingByCompany(theEvent().Id);
        }

        Map<String, InviteeApprovalController.CompanyGroup> byName = groupsByCompany(groups);
        System.assertEquals(2, groups.size(), 'Two companies, not three people');
        System.assertEquals(2, byName.get('Acme Corporation').invitees.size());
        System.assertEquals(1, byName.get('Globex').invitees.size());
        System.assertEquals(true, byName.get('Acme Corporation').hasCustomer);
        System.assertEquals('CUST-0042', byName.get('Acme Corporation').custCd);
        System.assertEquals('CUST-0055', byName.get('Globex').custCd);
    }

    /** ★R9 The screen says where in the chain the approver is standing. */
    @IsTest
    static void everyRowSaysWhichLevelOfTheChainItIsOn() {
        submitAs(findUser('apalex'), new List<Id>{ attendeeId('Carter') });

        List<InviteeApprovalController.CompanyGroup> asLevelOne;
        System.runAs(findUser('apowner')) {
            asLevelOne = InviteeApprovalController.getMyPendingByCompany(theEvent().Id);
        }
        System.assertEquals(1, asLevelOne[0].invitees[0].level, 'The Account Owner is level 1');
        System.assertEquals(3, asLevelOne[0].invitees[0].levels, 'of a three-level chain');

        Test.startTest();
        approveOneLevel(inviteeFor('Carter'));
        Test.stopTest();

        List<InviteeApprovalController.CompanyGroup> asLevelTwo;
        System.runAs(findUser('apdana')) {
            asLevelTwo = InviteeApprovalController.getMyPendingByCompany(theEvent().Id);
        }
        System.assertEquals(2, asLevelTwo[0].invitees[0].level, 'and their manager is level 2 of the same chain');
        System.assertEquals(3, asLevelTwo[0].invitees[0].levels);
    }

    /**
     * ★R9 The behaviour a field comparison would have got wrong.
     *
     * Approver_2__c names apdana from the moment the row is submitted, so a screen filtering
     * on "am I in the chain?" would show them work that level 1 has not released yet — and
     * let them act on it. Reading the work item is what makes waiting mean waiting.
     */
    @IsTest
    static void aLevelTwoApproverSeesNothingUntilLevelOneHasSigned() {
        submitAs(findUser('apalex'), new List<Id>{ attendeeId('Carter') });
        User dana = findUser('apdana');

        List<InviteeApprovalController.CompanyGroup> before;
        System.runAs(dana) {
            before = InviteeApprovalController.getMyPendingByCompany(theEvent().Id);
        }
        System.assertEquals(0, before.size(), 'Named in the chain, but not yet their turn');

        // …and not merely hidden: they cannot decide it either.
        Boolean threw = false;
        System.runAs(dana) {
            try {
                InviteeApprovalController.decide(theEvent().Id, new List<Id>{ inviteeFor('Carter') }, true, null);
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        System.assert(threw, 'A level-2 approver must not be able to jump the queue');

        Test.startTest();
        approveOneLevel(inviteeFor('Carter'));
        Test.stopTest();

        List<InviteeApprovalController.CompanyGroup> after;
        System.runAs(dana) {
            after = InviteeApprovalController.getMyPendingByCompany(theEvent().Id);
        }
        System.assertEquals(1, after.size(), 'Once level 1 has signed, it is theirs');
    }

    @IsTest
    static void anApproverSeesOnlyWhatIsWaitingOnThem() {
        User alex = findUser('apalex');
        submitAs(alex, new List<Id>{ attendeeId('Carter') });

        List<InviteeApprovalController.CompanyGroup> asSubmitter;
        System.runAs(alex) {
            asSubmitter = InviteeApprovalController.getMyPendingByCompany(theEvent().Id);
        }
        System.assertEquals(0, asSubmitter.size(), 'The submitter is not an approver and sees nothing here');

        List<InviteeApprovalController.CompanyGroup> asApprover;
        System.runAs(findUser('apowner')) {
            asApprover = InviteeApprovalController.getMyPendingByCompany(theEvent().Id);
        }
        System.assertEquals(1, asApprover.size());
    }

    /**
     * ★R9 One tick, one company, every row in it — and what that means with a chain is that
     * they all move up a level together, not that they are approved.
     */
    @IsTest
    static void approvingACompanyAdvancesEveryRowInItToTheNextLevel() {
        submitAs(findUser('apalex'), new List<Id>{ attendeeId('Carter'), attendeeId('Kim'), attendeeId('Farrow') });

        List<Id> acmeIds = new List<Id>();
        for (Event_Invitee__c inv : [SELECT Id FROM Event_Invitee__c WHERE Invitee_Org__c = 'Acme Corporation']) {
            acmeIds.add(inv.Id);
        }

        InviteeApprovalController.DecisionResult res;
        Test.startTest();
        System.runAs(findUser('apowner')) {
            res = InviteeApprovalController.decide(theEvent().Id, acmeIds, true, 'Fine by me');
        }
        Test.stopTest();

        System.assertEquals(2, res.decided);
        System.assertEquals(0, res.skipped);
        for (Event_Invitee__c inv : [SELECT Status__c FROM Event_Invitee__c WHERE Id IN :acmeIds]) {
            System.assertEquals('Pending Approval', inv.Status__c, 'Two more levels still have to agree');
        }
        System.assertEquals(
            2,
            [SELECT COUNT() FROM ProcessInstanceWorkitem WHERE ActorId = :findUser('apdana').Id],
            'and both have moved to the level above'
        );
        System.assertEquals(
            1,
            [SELECT COUNT() FROM ProcessInstanceWorkitem WHERE ActorId = :findUser('apowner').Id],
            'A company-scoped decision must not reach another company'
        );
    }

    /** A rejection at level 1 ends the request outright — the chain is unanimous or nothing. */
    @IsTest
    static void rejectingWorksThroughTheSameProcess() {
        submitAs(findUser('apalex'), new List<Id>{ attendeeId('Mueller') });
        Id inviteeId = inviteeFor('Mueller');

        Test.startTest();
        System.runAs(findUser('apother')) {
            InviteeApprovalController.decide(theEvent().Id, new List<Id>{ inviteeId }, false, 'Not this time');
        }
        Test.stopTest();

        Event_Invitee__c decided = [SELECT Status__c, Decided_At__c FROM Event_Invitee__c WHERE Id = :inviteeId];
        System.assertEquals('Rejected', decided.Status__c);
        System.assertNotEquals(null, decided.Decided_At__c);
        System.assertEquals(
            0,
            [SELECT COUNT() FROM ProcessInstanceWorkitem WHERE ProcessInstance.TargetObjectId = :inviteeId],
            'Nobody above is asked once a level has said no'
        );
    }

    /**
     * The client's list is a request, not an instruction. A caller who sends an id that is
     * pending on somebody else must not decide it — this is the reason the controller
     * re-queries instead of trusting what arrives.
     */
    @IsTest
    static void anIdPendingOnSomebodyElseIsDroppedNotDecided() {
        submitAs(findUser('apalex'), new List<Id>{ attendeeId('Carter'), attendeeId('Mueller') });

        Id mine = inviteeFor('Carter'); // Acme, owned by apowner
        Id notMine = inviteeFor('Mueller'); // Nordbank, owned by apother

        InviteeApprovalController.DecisionResult res;
        Test.startTest();
        System.runAs(findUser('apowner')) {
            res = InviteeApprovalController.decide(theEvent().Id, new List<Id>{ mine, notMine }, true, null);
        }
        Test.stopTest();

        System.assertEquals(1, res.decided, 'Only the row actually assigned to this approver');
        System.assertEquals(1, res.skipped, 'And the other one is reported, not silently absent');
        System.assertEquals(
            findUser('apdana').Id,
            [
                SELECT ActorId
                FROM ProcessInstanceWorkitem
                WHERE ProcessInstance.TargetObjectId = :mine
                LIMIT 1
            ]
            .ActorId,
            'The decided row moved up a level'
        );
        System.assertEquals(
            findUser('apother').Id,
            [
                SELECT ActorId
                FROM ProcessInstanceWorkitem
                WHERE ProcessInstance.TargetObjectId = :notMine
                LIMIT 1
            ]
            .ActorId,
            'and the other is exactly where it was'
        );
    }

    @IsTest
    static void decidingNothingIsRefused() {
        Boolean threw = false;
        System.runAs(findUser('apowner')) {
            try {
                InviteeApprovalController.decide(theEvent().Id, new List<Id>(), true, null);
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        System.assertEquals(true, threw, 'An empty selection is a client bug, not a no-op');
    }

    @IsTest
    static void aBatchOverTheCapIsRefusedBeforeAnyDml() {
        submitAs(findUser('apalex'), new List<Id>{ attendeeId('Carter') });
        Id real = inviteeFor('Carter');

        List<Id> tooMany = new List<Id>();
        for (Integer i = 0; i <= InviteeApprovalController.MAX_PER_DECISION; i++) {
            tooMany.add(real);
        }

        Boolean threw = false;
        System.runAs(findUser('apowner')) {
            try {
                InviteeApprovalController.decide(theEvent().Id, tooMany, true, null);
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        System.assertEquals(true, threw);
        System.assertEquals(
            'Pending Approval',
            [SELECT Status__c FROM Event_Invitee__c WHERE Id = :real].Status__c,
            'Refused before anything was decided'
        );
        System.assertEquals(
            1,
            [SELECT COUNT() FROM ProcessInstanceWorkitem WHERE ActorId = :findUser('apowner').Id],
            'and it is still waiting on the same person'
        );
    }

    /** A row decided between load and click: refused with an explanation, nothing changed. */
    @IsTest
    static void decidingARowThatHasMovedOnIsRefused() {
        submitAs(findUser('apalex'), new List<Id>{ attendeeId('Carter') });
        Id inviteeId = inviteeFor('Carter');

        Test.startTest();
        System.runAs(findUser('apowner')) {
            InviteeApprovalController.decide(theEvent().Id, new List<Id>{ inviteeId }, true, null);

            Boolean threw = false;
            try {
                InviteeApprovalController.decide(theEvent().Id, new List<Id>{ inviteeId }, true, null);
            } catch (AuraHandledException e) {
                threw = true;
            }
            System.assertEquals(true, threw, 'The second decision has no work item to act on — it is level 2’s now');
        }
        Test.stopTest();

        System.assertEquals(
            'Pending Approval',
            [SELECT Status__c FROM Event_Invitee__c WHERE Id = :inviteeId].Status__c
        );
    }

    /**
     * ★R9 A pending row with no Account behind it can no longer arrive through the front
     * door — routing starts at the Account Owner, so a guest with no customer is refused at
     * submit. It can still arrive through the side door: Account__c is SetNull, so deleting
     * a customer mid-approval empties it under a row somebody is already looking at.
     *
     * The grouping has to stay honest when that happens, which is why this state is set up
     * by hand rather than deleted from the test.
     */
    @IsTest
    static void aRowWhoseCustomerHasGoneStillGroupsByItsOwnCompanyText() {
        configureChain();
        User alex = findUser('apalex');
        User owner = findUser('apowner');
        Marketing_Event__c evt = theEvent();

        System.runAs(alex) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ attendeeId('Dubois') });
        }
        // Routed by hand, because the chain would refuse this row — which is the point.
        Event_Invitee__c orphan = [SELECT Id FROM Event_Invitee__c LIMIT 1];
        orphan.Approver_1__c = owner.Id;
        orphan.Approval_Levels__c = 1;
        orphan.Submitted_At__c = Datetime.now();
        update orphan;
        Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
        req.setObjectId(orphan.Id);
        req.setProcessDefinitionNameOrId('Invitee_Approval');
        req.setSubmitterId(alex.Id);
        Approval.process(req);

        List<InviteeApprovalController.CompanyGroup> groups;
        System.runAs(owner) {
            groups = InviteeApprovalController.getMyPendingByCompany(evt.Id);
        }

        System.assertEquals(1, groups.size());
        System.assertEquals(false, groups[0].hasCustomer, 'Stated as "not a customer" rather than left blank');
        System.assertEquals(
            'Université de Genève',
            groups[0].company,
            'Grouped by their own company text, never into one bucket with unrelated guests'
        );
    }

    /**
     * The same guarantee EventWorkflowTest makes for submit and decide, restated for the
     * one screen that reads an Account in order to group by it.
     */
    @IsTest
    static void theApprovalScreenNeverWritesToAccountOrContact() {
        submitAs(findUser('apalex'), new List<Id>{ attendeeId('Carter') });
        Account before = [SELECT Id, Name, OwnerId, LastModifiedDate FROM Account WHERE Name = 'Acme Corporation'];
        Contact contactBefore = [SELECT Id, AccountId, LastModifiedDate FROM Contact WHERE LastName = 'Carter'];
        Id inviteeId = inviteeFor('Carter');

        Test.startTest();
        System.runAs(findUser('apowner')) {
            InviteeApprovalController.getMyPendingByCompany(theEvent().Id);
            InviteeApprovalController.decide(theEvent().Id, new List<Id>{ inviteeId }, true, null);
        }
        Test.stopTest();

        Account after = [SELECT Id, Name, OwnerId, LastModifiedDate FROM Account WHERE Name = 'Acme Corporation'];
        System.assertEquals(before.LastModifiedDate, after.LastModifiedDate, 'Account read, never written');
        System.assertEquals(before.OwnerId, after.OwnerId, 'and the owner the chain routes to is left alone');
        Contact contactAfter = [SELECT Id, AccountId, LastModifiedDate FROM Contact WHERE LastName = 'Carter'];
        System.assertEquals(contactBefore.LastModifiedDate, contactAfter.LastModifiedDate);
        System.assertEquals(3, [SELECT COUNT() FROM Account]);
        System.assertEquals(4, [SELECT COUNT() FROM Contact]);
    }
}
