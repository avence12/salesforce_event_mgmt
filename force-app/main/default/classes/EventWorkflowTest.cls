/**
 * End-to-end workflow tests: add → submit (chain resolution + notifications) →
 * approve/reject through the standard approval process, level by level → completion
 * notification → rejected re-add.
 *
 * ★R9 The fixture is an org chart and two customers, because that is what the chain is
 * made of:
 *
 *   Acme Corporation   owned by amowner → mgrdana → rhead ("Regional Head, EMEA") → ceo
 *   Nordbank AG        owned by mgrdana → rhead → ceo
 *
 * With two levels allowed above the Account Owner, an Acme invitee needs three approvals
 * and a Nordbank invitee needs two — it reaches the Regional Head one rung earlier and
 * stops there rather than climbing to the ceo. One event therefore carries invitees with
 * different chain lengths, which is the case the old single-approver design could not
 * produce at all and the one most likely to be got wrong.
 *
 * Hélène Dubois is deliberately linked to no Contact: she is the guest who belongs to no
 * customer, and the tests assert that she cannot be submitted rather than quietly routing
 * to somebody's manager.
 */
@IsTest
private class EventWorkflowTest {
    private static User findUser(String alias) {
        return [SELECT Id, Name, ManagerId FROM User WHERE Alias = :alias AND IsActive = TRUE LIMIT 1];
    }

    /**
     * Approves or rejects one level, as whoever the platform says holds the work item.
     *
     * Reading the actor rather than taking it as an argument is the point: a test that
     * names the approver itself would pass even if the routing sent the item somewhere
     * else entirely.
     */
    private static void decideOneLevel(Id recordId, Boolean approve) {
        List<ProcessInstanceWorkitem> items = [
            SELECT Id, ActorId
            FROM ProcessInstanceWorkitem
            WHERE ProcessInstance.TargetObjectId = :recordId
        ];
        System.assertEquals(1, items.size(), 'Exactly one level should hold this invitee at a time');
        System.runAs(new User(Id = items[0].ActorId)) {
            Approval.ProcessWorkitemRequest req = new Approval.ProcessWorkitemRequest();
            req.setWorkitemId(items[0].Id);
            req.setAction(approve ? 'Approve' : 'Reject');
            Approval.process(req);
        }
    }

    /** Drives an invitee through every remaining level of its chain. */
    private static Integer approveEveryLevel(Id recordId) {
        Integer levelsApproved = 0;
        for (Integer i = 0; i < ApprovalChainService.MAX_PROVISIONED_LEVELS; i++) {
            if ([SELECT COUNT() FROM ProcessInstanceWorkitem WHERE ProcessInstance.TargetObjectId = :recordId] == 0) {
                break;
            }
            decideOneLevel(recordId, true);
            levelsApproved++;
        }
        return levelsApproved;
    }

    /** Who the platform currently has the invitee waiting on. */
    private static Id currentActor(Id recordId) {
        List<ProcessInstanceWorkitem> items = [
            SELECT ActorId
            FROM ProcessInstanceWorkitem
            WHERE ProcessInstance.TargetObjectId = :recordId
        ];
        return items.isEmpty() ? null : items[0].ActorId;
    }

    /** The shipped configuration, restated so no test depends on what Setup currently holds. */
    private static void configureChain() {
        ApprovalChainService.titlesOverride = 'Regional Head';
        ApprovalChainService.levelsAboveOverride = 2;
    }

    /**
     * ★R12 `custCd` is what the CSV carried, and it is now where Event_Invitee__c.Cust_Cd__c
     * comes from — R8 read it off Account.AccountNumber instead. Blank models the guest who
     * belongs to no customer.
     */
    private static Event_Attendee__c attendee(String first, String last, String company, String custCd) {
        return new Event_Attendee__c(
            Name = first + ' ' + last,
            First_Name__c = first,
            Last_Name__c = last,
            Email__c = first.toLowerCase() + '@' + 'evt.example',
            Title__c = 'Attendee',
            Company__c = company,
            Cust_Cd__c = custCd,
            Unique_Key__c = (last + '|' + first + '|' + company).toLowerCase()
        );
    }

    @TestSetup
    static void setup() {
        Profile std = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        Map<String, String> titles = new Map<String, String>{
            'amalex' => 'Account Manager',
            'ammaria' => 'Account Manager',
            'amowner' => 'Account Manager',
            'mgrdana' => 'Sales Manager',
            'rhead' => 'Regional Head, EMEA',
            'ceo' => 'Chief Executive'
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
            insert users; // runAs guards against mixed-DML with the setup below
            for (User u : users) {
                byAlias.put(u.Alias, u.Id);
            }
            // The reporting line the chain climbs. Both AMs report to Dana as well, which is
            // now incidental — routing starts at the Account Owner, not at the submitter.
            update new List<User>{
                new User(Id = byAlias.get('amalex'), ManagerId = byAlias.get('mgrdana')),
                new User(Id = byAlias.get('ammaria'), ManagerId = byAlias.get('mgrdana')),
                new User(Id = byAlias.get('amowner'), ManagerId = byAlias.get('mgrdana')),
                new User(Id = byAlias.get('mgrdana'), ManagerId = byAlias.get('rhead')),
                new User(Id = byAlias.get('rhead'), ManagerId = byAlias.get('ceo'))
            };
        }

        // The org's own data, as a fixture. Nothing in the workflow may create, change or
        // delete any of it — several tests below assert exactly that.
        List<Account> customers = new List<Account>{
            new Account(Name = 'Acme Corporation', AccountNumber = 'CUST-0042', OwnerId = byAlias.get('amowner')),
            new Account(Name = 'Nordbank AG', AccountNumber = 'CUST-0077', OwnerId = byAlias.get('mgrdana'))
        };
        insert customers;
        List<Contact> people = new List<Contact>{
            new Contact(FirstName = 'Emily', LastName = 'Carter', AccountId = customers[0].Id),
            new Contact(FirstName = 'Robert', LastName = 'Kim', AccountId = customers[0].Id),
            new Contact(FirstName = 'James', LastName = 'Mueller', AccountId = customers[1].Id)
        };
        insert people;

        List<Event_Attendee__c> attendees = new List<Event_Attendee__c>{
            attendee('Emily', 'Carter', 'Acme Corp', 'CUST-0042'),
            attendee('Robert', 'Kim', 'Acme Corp', 'CUST-0042'),
            attendee('James', 'Mueller', 'Nordbank AG', 'CUST-0077'),
            // ★R12 No code, because she belongs to no customer — the same fact that leaves
            // her without a Contact below, arriving one column earlier.
            attendee('Hélène', 'Dubois', 'Université de Genève', null)
        };
        insert attendees;

        // ★R12 The Contact link as the import now leaves it, having matched on customer
        // code plus email. Hélène keeps none, which is what makes her the unroutable guest.
        attendees[0].Contact__c = people[0].Id;
        attendees[1].Contact__c = people[1].Id;
        attendees[2].Contact__c = people[2].Id;
        update attendees;

        insert new Marketing_Event__c(
            Name = 'Q3 2026 Customer Appreciation Gala',
            Event_Date__c = Date.today().addDays(60),
            Location__c = 'The Plaza, New York',
            Event_Type__c = 'Conference'
        );
    }

    private static Id attendeeId(String last) {
        return [SELECT Id FROM Event_Attendee__c WHERE Last_Name__c = :last LIMIT 1].Id;
    }

    private static Id inviteeFor(String lastName) {
        return [SELECT Id FROM Event_Invitee__c WHERE Event_Attendee__r.Last_Name__c = :lastName LIMIT 1].Id;
    }

    @IsTest
    static void fullWorkflow_submitApproveReject() {
        configureChain();
        User alex = findUser('amalex');
        User maria = findUser('ammaria');
        User owner = findUser('amowner');
        User dana = findUser('mgrdana');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        Id emily = attendeeId('Carter');
        Id robert = attendeeId('Kim');
        Id james = attendeeId('Mueller');

        System.runAs(alex) {
            System.assertEquals(2, InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ emily, robert }));
            // Duplicate add is a no-op, not an error
            System.assertEquals(0, InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ emily }));
            InviteeSelectorController.SubmitResult sub = InviteeSelectorController.submitMyInvitees(evt.Id);
            System.assertEquals(2, sub.submitted);
            System.assertEquals(1, sub.approversNotified, 'Both rows are Acme’s, so one level-1 approver');
            System.assertEquals(3, sub.levels, 'Acme’s chain is Account Owner, manager, Regional Head');
        }
        System.runAs(maria) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ james });
            InviteeSelectorController.SubmitResult sub = InviteeSelectorController.submitMyInvitees(evt.Id);
            System.assertEquals(2, sub.levels, 'Nordbank is owned by Dana, whose manager is the Regional Head');
        }

        // The approval process, not our Apex, owns the status from submission onwards.
        for (Event_Invitee__c inv : [SELECT Status__c, Submitted_At__c, Current_Level__c FROM Event_Invitee__c]) {
            System.assertEquals('Pending Approval', inv.Status__c, 'Initial submission action must set the status');
            System.assertEquals(1, inv.Current_Level__c.intValue(), 'and must start the chain at level 1');
            System.assertNotEquals(null, inv.Submitted_At__c);
        }

        Map<Id, Event_Invitee__c> byId = new Map<Id, Event_Invitee__c>(
            [SELECT Id, Approver_1__c, Approver_2__c, Approver_3__c, Approval_Levels__c FROM Event_Invitee__c]
        );
        Event_Invitee__c acmeRow = byId.get(inviteeFor('Carter'));
        System.assertEquals(
            owner.Id,
            acmeRow.Approver_1__c,
            'Level 1 is the Account Owner, not the submitter’s manager'
        );
        System.assertEquals(dana.Id, acmeRow.Approver_2__c);
        System.assertEquals(findUser('rhead').Id, acmeRow.Approver_3__c);
        System.assertEquals(3, acmeRow.Approval_Levels__c.intValue());

        Event_Invitee__c nordbankRow = byId.get(inviteeFor('Mueller'));
        System.assertEquals(dana.Id, nordbankRow.Approver_1__c, 'Dana owns Nordbank and is its level 1');
        System.assertEquals(findUser('rhead').Id, nordbankRow.Approver_2__c);
        System.assertEquals(null, nordbankRow.Approver_3__c, 'The chain ended at the Regional Head');

        System.assertEquals(3, [SELECT COUNT() FROM ProcessInstance], 'One approval instance per invitee');

        Test.startTest();
        approveEveryLevel(inviteeFor('Carter'));
        decideOneLevel(inviteeFor('Kim'), false);
        Test.stopTest();

        System.assertEquals(
            'Approved',
            [SELECT Status__c FROM Event_Invitee__c WHERE Id = :inviteeFor('Carter')].Status__c
        );
        System.assertEquals(
            'Rejected',
            [SELECT Status__c FROM Event_Invitee__c WHERE Id = :inviteeFor('Kim')].Status__c
        );
        for (Event_Invitee__c inv : [
            SELECT Decided_At__c
            FROM Event_Invitee__c
            WHERE Event_Attendee__c IN (:emily, :robert)
        ]) {
            System.assertNotEquals(null, inv.Decided_At__c, 'Stamp_Decided_At runs on both outcomes');
        }

        Marketing_Event__c counts = [
            SELECT Approved_Count__c, Rejected_Count__c, Pending_Count__c
            FROM Marketing_Event__c
            WHERE Id = :evt.Id
        ];
        System.assertEquals(1, counts.Approved_Count__c);
        System.assertEquals(1, counts.Rejected_Count__c);
        System.assertEquals(1, counts.Pending_Count__c, 'Maria’s row is untouched');
    }

    /**
     * ★R9 The requirement in one test: everybody in the chain has to agree, in order.
     *
     * The assertions in the middle are the ones that matter. After level 1 approves, the
     * invitee is still Pending and the work item has moved to level 2 — an approval process
     * that final-approved here would look identical from the AM's side and be wrong.
     */
    @IsTest
    static void everyLevelMustApproveBeforeTheInviteeIs() {
        configureChain();
        User alex = findUser('amalex');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];

        System.runAs(alex) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ attendeeId('Carter') });
            InviteeSelectorController.submitMyInvitees(evt.Id);
        }
        Id inviteeId = inviteeFor('Carter');

        Test.startTest();
        System.assertEquals(findUser('amowner').Id, currentActor(inviteeId), 'Level 1: the Account Owner');

        decideOneLevel(inviteeId, true);
        System.assertEquals(
            'Pending Approval',
            [SELECT Status__c FROM Event_Invitee__c WHERE Id = :inviteeId].Status__c,
            'One approval out of three must not approve the invitee'
        );
        System.assertEquals(findUser('mgrdana').Id, currentActor(inviteeId), 'Level 2: the owner’s manager');

        decideOneLevel(inviteeId, true);
        System.assertEquals(
            'Pending Approval',
            [SELECT Status__c FROM Event_Invitee__c WHERE Id = :inviteeId].Status__c
        );
        System.assertEquals(findUser('rhead').Id, currentActor(inviteeId), 'Level 3: the Regional Head');

        decideOneLevel(inviteeId, true);
        Test.stopTest();

        Event_Invitee__c decided = [SELECT Status__c, Decided_At__c FROM Event_Invitee__c WHERE Id = :inviteeId];
        System.assertEquals('Approved', decided.Status__c, 'Only the last level approves the record');
        System.assertNotEquals(null, decided.Decided_At__c);
        System.assertEquals(null, currentActor(inviteeId), 'and nothing is left waiting on anybody');
    }

    /**
     * ★R9 The Regional Head is a terminator, not a rung. Nordbank's owner is one level below
     * one, so its chain is two long where Acme's is three — and the ceo above the Regional
     * Head never sees it.
     */
    @IsTest
    static void aChainEndingAtARegionalHeadNeedsNoFurtherApproval() {
        configureChain();
        User maria = findUser('ammaria');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];

        System.runAs(maria) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ attendeeId('Mueller') });
            InviteeSelectorController.submitMyInvitees(evt.Id);
        }
        Id inviteeId = inviteeFor('Mueller');

        Test.startTest();
        Integer levels = approveEveryLevel(inviteeId);
        Test.stopTest();

        System.assertEquals(2, levels, 'Two signatures, not three: the Regional Head ends the chain');
        System.assertEquals('Approved', [SELECT Status__c FROM Event_Invitee__c WHERE Id = :inviteeId].Status__c);
        System.assertEquals(
            0,
            [SELECT COUNT() FROM ProcessInstanceWorkitem WHERE ActorId = :findUser('ceo').Id],
            'The level above the Regional Head must never be asked'
        );
    }

    /** ★R9 One rejection anywhere in the chain ends the request — nobody above is asked. */
    @IsTest
    static void aRejectionAtAnyLevelEndsTheWholeRequest() {
        configureChain();
        User alex = findUser('amalex');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];

        System.runAs(alex) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ attendeeId('Carter') });
            InviteeSelectorController.submitMyInvitees(evt.Id);
        }
        Id inviteeId = inviteeFor('Carter');

        Test.startTest();
        decideOneLevel(inviteeId, true); // level 1 approves
        decideOneLevel(inviteeId, false); // level 2 rejects
        Test.stopTest();

        System.assertEquals('Rejected', [SELECT Status__c FROM Event_Invitee__c WHERE Id = :inviteeId].Status__c);
        System.assertEquals(null, currentActor(inviteeId), 'Level 3 is never asked');
    }

    /**
     * ★R9 The level above hears when the level below finishes. Without this the upper levels
     * would never be told anything — their items would appear in an Approvals list
     * unannounced, which is the failure mode a chain introduces and a single approver never
     * had.
     */
    @IsTest
    static void theNextLevelIsNotifiedWhenTheLevelBelowApproves() {
        configureChain();
        User alex = findUser('amalex');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];

        System.runAs(alex) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ attendeeId('Carter'), attendeeId('Kim') });
            InviteeSelectorController.submitMyInvitees(evt.Id);
        }
        List<Id> ids = new List<Id>{ inviteeFor('Carter'), inviteeFor('Kim') };

        Test.startTest();
        decideOneLevel(ids[0], true);
        decideOneLevel(ids[1], true);

        // Invoked directly, the way the Invitee_Level_Advanced flow invokes it with every id
        // the transaction touched. Two rows, one level-2 approver, one event: one notice.
        EventNotificationService.levelNotificationsSent = 0;
        EventNotificationService.notifyLevelApprovers(ids);
        Test.stopTest();

        System.assertEquals(
            1,
            EventNotificationService.levelNotificationsSent,
            'One notification per approver per event, never one per invitee'
        );
        for (Event_Invitee__c inv : [SELECT Current_Level__c FROM Event_Invitee__c WHERE Id IN :ids]) {
            System.assertEquals(2, inv.Current_Level__c.intValue(), 'The step’s approval action advances the marker');
        }
    }

    /** A row still on level 1 is nobody's news: they were told at submit time. */
    @IsTest
    static void theLevelNotificationSaysNothingAboutLevelOne() {
        configureChain();
        User alex = findUser('amalex');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];

        System.runAs(alex) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ attendeeId('Carter') });
            InviteeSelectorController.submitMyInvitees(evt.Id);
        }

        Test.startTest();
        EventNotificationService.levelNotificationsSent = 0;
        EventNotificationService.notifyLevelApprovers(new List<Id>{ inviteeFor('Carter') });
        Test.stopTest();

        System.assertEquals(0, EventNotificationService.levelNotificationsSent, 'Level 1 hears from the submit, once');
    }

    /**
     * Submit and decide both touch User — ManagerId and Title to resolve the chain, Name for
     * the notification — and neither may write to it. The org's Users are not this project's
     * to touch, the same as its Accounts and Contacts.
     */
    @IsTest
    static void submitAndApproveNeverModifyUsers() {
        configureChain();
        User alex = findUser('amalex');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];

        List<User> usersBefore = [SELECT Id, Name, ManagerId, Title, LastModifiedDate FROM User ORDER BY Id];
        Map<Id, User> beforeById = new Map<Id, User>(usersBefore);

        System.runAs(alex) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ attendeeId('Carter') });
            InviteeSelectorController.submitMyInvitees(evt.Id);
        }
        approveEveryLevel(inviteeFor('Carter'));

        List<User> usersAfter = [SELECT Id, Name, ManagerId, Title, LastModifiedDate FROM User ORDER BY Id];
        System.assertEquals(usersBefore.size(), usersAfter.size(), 'No User may be created or deleted');
        for (User u : usersAfter) {
            User before = beforeById.get(u.Id);
            System.assertEquals(
                before.LastModifiedDate,
                u.LastModifiedDate,
                'No User may be modified — the chain only reads ManagerId, Title and Name'
            );
            System.assertEquals(before.ManagerId, u.ManagerId, 'Never reparented');
            System.assertEquals(before.Title, u.Title, 'A Regional Head is found, never appointed');
        }
    }

    /**
     * ★R8 Name and email still read through live; title, salutation and company are
     * snapshotted. A guest with no Contact behind them keeps the company text the import
     * gave — the field is never blank merely because somebody is nobody's customer.
     */
    @IsTest
    static void inviteeSnapshotsThePersonAndFallsBackToTheImportedCompany() {
        User alex = findUser('amalex');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        Id helene = attendeeId('Dubois');

        System.runAs(alex) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ helene });
        }

        Event_Invitee__c inv = [
            SELECT
                Invitee_Name__c,
                Invitee_Org__c,
                Invitee_Title__c,
                Invitee_Email__c,
                Account__c,
                Cust_Cd__c,
                Account_Manager__c
            FROM Event_Invitee__c
            WHERE Event_Attendee__c = :helene
        ];
        System.assertEquals('Hélène Dubois', inv.Invitee_Name__c, 'Non-ASCII names survive the formula');
        System.assertEquals('Université de Genève', inv.Invitee_Org__c, 'Falls back to the imported company text');
        System.assertEquals('Attendee', inv.Invitee_Title__c);
        System.assertNotEquals(null, inv.Invitee_Email__c);

        // Blank, not guessed. A guest who belongs to no customer has no customer to name,
        // and inventing one from the company text is the mistake the Contact link exists
        // to avoid. ★R9 It is also the state that now stops the row being submitted at all.
        System.assertEquals(null, inv.Account__c, 'No Contact behind them means no Account');
        // ★R12 Blank for a new reason worth keeping distinct from the line above: her CSV
        // row carried no customer code, not merely no Account. Had it carried one, she
        // would have a code here and still no Account — which is precisely the case
        // Open Question 21 is about.
        System.assertEquals(null, inv.Cust_Cd__c);
        System.assertEquals(null, inv.Account_Manager__c);

        // The point of the whole revision: inviting somebody invents no customer record.
        System.assertEquals(2, [SELECT COUNT() FROM Account], 'The two fixture accounts, and not one more');
        System.assertEquals(3, [SELECT COUNT() FROM Contact]);
        System.assertEquals(0, [SELECT COUNT() FROM Lead]);
    }

    /**
     * ★R8 The whole reason the formulas became snapshots. Editing an attendee after they
     * have been invited must not rewrite what the invitation — and therefore the approval
     * that was made on it — appears to have said.
     *
     * ★R12 Narrowed, and the narrowing is the point of the extra line below. R8 froze the
     * row from the moment it was created; R12 freezes it from the moment it is decided.
     * A Draft invitation has misrepresented nobody, so it follows the attendee — see
     * EventAttendeeSyncTest for that half. What this test now pins is the half R8 was
     * actually arguing for, and it is unchanged: once Approved, nothing moves it.
     */
    @IsTest
    static void editingTheAttendeeLaterDoesNotRewriteTheInvitation() {
        User alex = findUser('amalex');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        Id emily = attendeeId('Carter');

        System.runAs(alex) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ emily });
        }
        // The state R8's argument is about. Set directly rather than through the approval
        // process: what is under test is the snapshot rule, not how a row reaches Approved.
        Event_Invitee__c row = [SELECT Id FROM Event_Invitee__c WHERE Event_Attendee__c = :emily];
        row.Status__c = 'Approved';
        update row;

        Test.startTest();
        update new Event_Attendee__c(Id = emily, Title__c = 'Managing Director', Company__c = 'Globex');
        Test.stopTest();

        Event_Invitee__c inv = [
            SELECT Invitee_Title__c, Invitee_Org__c, Invitee_Name__c
            FROM Event_Invitee__c
            WHERE Event_Attendee__c = :emily
        ];
        System.assertEquals('Attendee', inv.Invitee_Title__c, 'The title at invitation time is what the row keeps');
        System.assertEquals(
            'Acme Corporation',
            inv.Invitee_Org__c,
            'The Account name it was invited under, not the attendee’s new company text'
        );
        // Name is still a live formula, deliberately: the ERD does not snapshot it, and a
        // corrected spelling should reach every list the person appears on.
        System.assertEquals('Emily Carter', inv.Invitee_Name__c);
    }

    /**
     * ★R8 The customer arrives through the Contact link and nowhere else. ★R9 And it is
     * what the whole chain now hangs from: Account.OwnerId is level 1.
     */
    @IsTest
    static void aLinkedContactPutsTheCustomerOnTheInvitee() {
        User alex = findUser('amalex');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        Id emily = attendeeId('Carter');
        Account acme = [SELECT Id, OwnerId FROM Account WHERE Name = 'Acme Corporation'];

        System.runAs(alex) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ emily });
        }

        Event_Invitee__c inv = [
            SELECT Invitee_Org__c, Account__c, Cust_Cd__c, Account_Manager__c
            FROM Event_Invitee__c
            WHERE Event_Attendee__c = :emily
        ];
        System.assertEquals(acme.Id, inv.Account__c, 'Reached through Contact__r.AccountId');
        System.assertEquals(
            'Acme Corporation',
            inv.Invitee_Org__c,
            'The Account name wins over the imported text once there is an Account'
        );
        // ★R12 Same value, different provenance: it is snapshotted from the attendee's own
        // Cust_Cd__c, which came from the CSV. The Account agrees because that agreement is
        // what let the import link her in the first place — but the Account is no longer
        // where the invitee reads it from.
        System.assertEquals('CUST-0042', inv.Cust_Cd__c, 'Snapshotted from the attendee, not from AccountNumber');
        System.assertEquals(
            acme.OwnerId,
            inv.Account_Manager__c,
            'ACCT_MNGR is the Account owner, not whoever added the row'
        );
        System.assertEquals(findUser('amowner').Id, inv.Account_Manager__c, 'and that is who level 1 will be');

        Event_Attendee__c person = [SELECT Is_Known_Contact__c FROM Event_Attendee__c WHERE Id = :emily];
        System.assertEquals(true, person.Is_Known_Contact__c);
    }

    /**
     * ★R8 Reading the org's data is allowed where a decision was recorded for it; writing
     * to it is not, and adding an invitee is a place the boundary could plausibly slip.
     */
    @IsTest
    static void addingAnInviteeNeverWritesToAccountOrContact() {
        User alex = findUser('amalex');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        Id emily = attendeeId('Carter');

        Account accountBefore = [
            SELECT Id, Name, AccountNumber, OwnerId, LastModifiedDate
            FROM Account
            WHERE Name = 'Acme Corporation'
        ];
        Contact contactBefore = [SELECT Id, AccountId, LastModifiedDate FROM Contact WHERE LastName = 'Carter'];

        Test.startTest();
        System.runAs(alex) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ emily });
            InviteeSelectorController.submitMyInvitees(evt.Id);
        }
        Test.stopTest();

        Account accountAfter = [
            SELECT Id, Name, AccountNumber, OwnerId, LastModifiedDate
            FROM Account
            WHERE Name = 'Acme Corporation'
        ];
        System.assertEquals(accountBefore.LastModifiedDate, accountAfter.LastModifiedDate, 'Account read, not written');
        System.assertEquals(accountBefore.Name, accountAfter.Name);
        System.assertEquals(accountBefore.AccountNumber, accountAfter.AccountNumber);
        System.assertEquals(accountBefore.OwnerId, accountAfter.OwnerId, 'Never reassigned — and the chain reads it');

        Contact contactAfter = [SELECT Id, AccountId, LastModifiedDate FROM Contact WHERE LastName = 'Carter'];
        System.assertEquals(contactBefore.LastModifiedDate, contactAfter.LastModifiedDate, 'Contact read, not written');
        System.assertEquals(contactBefore.AccountId, contactAfter.AccountId, 'Never reparented');

        System.assertEquals(2, [SELECT COUNT() FROM Account], 'No Account created');
        System.assertEquals(3, [SELECT COUNT() FROM Contact], 'No Contact created');
        System.assertEquals(0, [SELECT COUNT() FROM Lead]);
    }

    /**
     * ★R9 The guest who belongs to no customer, and the price of routing on the customer.
     *
     * Under R5 anybody could be invited and the submitter's manager approved them. The chain
     * starts at an Account Owner, so a guest with no Account behind them has nobody defined
     * to approve — and the design refuses rather than falling back, because a fallback turns
     * a data gap into a quieter approval. The remedy is a data one: an administrator keeps an
     * account for non-customer guests and the reconciliation links them to it.
     */
    @IsTest
    static void aGuestWithNoCustomerCannotBeSubmitted() {
        configureChain();
        User alex = findUser('amalex');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];

        System.runAs(alex) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ attendeeId('Dubois') });

            Boolean threw = false;
            try {
                InviteeSelectorController.submitMyInvitees(evt.Id);
            } catch (AuraHandledException e) {
                threw = true;
            }
            System.assert(threw, 'No Account Owner → the submit must fail loudly');
        }

        System.assertEquals(
            0,
            [SELECT COUNT() FROM Event_Invitee__c WHERE Status__c = 'Pending Approval'],
            'A refused submit must move nothing — no half-submitted batch'
        );
        System.assertEquals(1, [SELECT COUNT() FROM Event_Invitee__c WHERE Status__c = 'Draft']);
        System.assertEquals(0, [SELECT COUNT() FROM ProcessInstance], 'Nothing entered the approval process');
    }

    /** ★R9 One unroutable row refuses the whole batch, rather than submitting the rest. */
    @IsTest
    static void oneUnroutableRowRefusesTheWholeBatch() {
        configureChain();
        User alex = findUser('amalex');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];

        System.runAs(alex) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ attendeeId('Carter'), attendeeId('Dubois') });
            Boolean threw = false;
            try {
                InviteeSelectorController.submitMyInvitees(evt.Id);
            } catch (AuraHandledException e) {
                threw = true;
            }
            System.assert(threw);
        }

        System.assertEquals(
            2,
            [SELECT COUNT() FROM Event_Invitee__c WHERE Status__c = 'Draft'],
            'The routable row stays in Draft too — a half-submitted batch is worse than a refused one'
        );
        System.assertEquals(0, [SELECT COUNT() FROM ProcessInstance]);
    }

    /**
     * An invitee pointing at nobody has a blank name everywhere it is read, so the
     * lookup is required at the field level.
     */
    @IsTest
    static void inviteeWithoutAnAttendeeIsRefused() {
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        Boolean threw = false;
        try {
            insert new Event_Invitee__c(Marketing_Event__c = evt.Id, Status__c = 'Draft', Unique_Key__c = 'k-none');
        } catch (DmlException e) {
            threw = true;
        }
        System.assert(threw, 'A required Event_Attendee__c must refuse an invitee with no attendee');
    }

    /** ★R9 And the database refuses a pending row with no level 1, independently of the Apex. */
    @IsTest
    static void aPendingRowWithNoFirstApproverIsRefusedByTheDatabase() {
        User alex = findUser('amalex');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        System.runAs(alex) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ attendeeId('Carter') });
        }
        Event_Invitee__c draft = [SELECT Id FROM Event_Invitee__c LIMIT 1];

        Boolean threw = false;
        try {
            update new Event_Invitee__c(Id = draft.Id, Status__c = 'Pending Approval');
        } catch (DmlException e) {
            threw = true;
        }
        System.assert(threw, 'Approver_Required_When_Pending must hold whatever the Apex does');
    }

    /** An attendee somebody has been invited on cannot be deleted out from under the approval. */
    @IsTest
    static void anInvitedAttendeeCannotBeDeleted() {
        User alex = findUser('amalex');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        Id emily = attendeeId('Carter');
        System.runAs(alex) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ emily });
        }

        Boolean threw = false;
        try {
            delete [SELECT Id FROM Event_Attendee__c WHERE Id = :emily];
        } catch (DmlException e) {
            threw = true;
        }
        System.assert(threw, 'Restrict on the lookup is what keeps an invitee from pointing at nothing');
    }

    @IsTest
    static void completionNotificationFiresOnlyWhenTheBatchIsDone() {
        configureChain();
        User alex = findUser('amalex');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];

        System.runAs(alex) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ attendeeId('Carter'), attendeeId('Kim') });
            InviteeSelectorController.submitMyInvitees(evt.Id);
        }
        Id first = inviteeFor('Carter');
        Id second = inviteeFor('Kim');

        Test.startTest();
        EventNotificationService.completionsSent = 0;
        // One of two decided — and only because every level of its chain has now agreed.
        approveEveryLevel(first);
        EventNotificationService.notifyCompletions(new List<Id>{ first });
        System.assertEquals(
            0,
            EventNotificationService.completionsSent,
            'One row left pending — no completion email yet'
        );

        approveEveryLevel(second);
        EventNotificationService.notifyCompletions(new List<Id>{ second });
        System.assertEquals(1, EventNotificationService.completionsSent, 'Zero pending left → notify the AM once');
        Test.stopTest();
    }

    /** Mass approval arrives as one invocable call with every id — one email, not forty. */
    @IsTest
    static void completionNotificationAggregatesABulkDecision() {
        configureChain();
        User alex = findUser('amalex');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];

        System.runAs(alex) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ attendeeId('Carter'), attendeeId('Kim') });
            InviteeSelectorController.submitMyInvitees(evt.Id);
        }
        Test.startTest();
        // Decided directly rather than through the approval process: this test is about
        // the invocable's aggregation, and driving six work items adds nothing to that.
        List<Id> ids = new List<Id>();
        List<Event_Invitee__c> all = [SELECT Id, Status__c FROM Event_Invitee__c];
        for (Event_Invitee__c inv : all) {
            inv.Status__c = 'Approved';
            ids.add(inv.Id);
        }
        update all;

        EventNotificationService.completionsSent = 0;
        EventNotificationService.notifyCompletions(ids);
        System.assertEquals(
            1,
            EventNotificationService.completionsSent,
            'Two rows, one AM, one event → exactly one email'
        );
        Test.stopTest();
    }

    @IsTest
    static void rejectedAttendeeCanBeReAdded() {
        configureChain();
        User alex = findUser('amalex');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        Id emily = attendeeId('Carter');

        System.runAs(alex) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ emily });
            InviteeSelectorController.submitMyInvitees(evt.Id);
        }
        Event_Invitee__c inv = [SELECT Id FROM Event_Invitee__c WHERE Event_Attendee__c = :emily];

        Test.startTest();
        decideOneLevel(inv.Id, false);
        Test.stopTest();

        System.runAs(alex) {
            System.assertEquals(
                1,
                InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ emily }),
                'Rejected row should reset, not error'
            );
        }
        inv = [
            SELECT
                Status__c,
                Submitted_At__c,
                Decided_At__c,
                Current_Level__c,
                Approval_Levels__c,
                Approver_1__c,
                Approver_2__c,
                Approver_3__c
            FROM Event_Invitee__c
            WHERE Id = :inv.Id
        ];
        System.assertEquals('Draft', inv.Status__c);
        System.assertEquals(null, inv.Submitted_At__c);
        System.assertEquals(null, inv.Decided_At__c);
        // ★R9 The whole chain goes, not just its first level: a stale approver anywhere
        // would let the next submit reuse somebody who decided last time.
        System.assertEquals(null, inv.Approver_1__c);
        System.assertEquals(null, inv.Approver_2__c);
        System.assertEquals(null, inv.Approver_3__c);
        System.assertEquals(null, inv.Approval_Levels__c);
        System.assertEquals(null, inv.Current_Level__c);
        System.assertEquals(
            1,
            [SELECT COUNT() FROM Event_Invitee__c WHERE Event_Attendee__c = :emily],
            'Never a second row per event+attendee'
        );
    }

    /** A rejected invitee reappears in the picker; that is what makes re-adding possible at all. */
    @IsTest
    static void aRejectedAttendeeReappearsInTheSelector() {
        configureChain();
        User alex = findUser('amalex');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        Id emily = attendeeId('Carter');

        System.runAs(alex) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ emily });
            InviteeSelectorController.submitMyInvitees(evt.Id);
        }
        Test.startTest();
        decideOneLevel([SELECT Id FROM Event_Invitee__c WHERE Event_Attendee__c = :emily].Id, false);
        Test.stopTest();

        System.runAs(alex) {
            InviteeSelectorController.SelectableResult sel = InviteeSelectorController.getSelectableAttendees(evt.Id);
            System.assertEquals(4, sel.attendees.size(), 'A rejected invitee is selectable again');
        }
    }

    /**
     * The selector is no longer scoped per AM — there is no Account left to scope
     * by. What it still does is hide people already on this event.
     */
    @IsTest
    static void selectorShowsEveryAttendeeAndHidesInvited() {
        User alex = findUser('amalex');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        Id emily = attendeeId('Carter');

        System.runAs(alex) {
            InviteeSelectorController.SelectableResult sel = InviteeSelectorController.getSelectableAttendees(evt.Id);
            System.assertEquals(4, sel.attendees.size(), 'Every imported attendee is invitable by any AM');
            System.assertEquals(false, sel.truncated, 'Four attendees is nowhere near the cap');
            System.assertEquals(InviteeSelectorController.ATTENDEE_CAP, sel.cap);

            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ emily });
            sel = InviteeSelectorController.getSelectableAttendees(evt.Id);
            System.assertEquals(3, sel.attendees.size(), 'Invited (Draft) attendee must be hidden');
            for (InviteeSelectorController.SelectableAttendee sa : sel.attendees) {
                System.assertNotEquals(emily, sa.attendeeId);
            }

            List<InviteeSelectorController.InviteeRow> all = InviteeSelectorController.getAllInvitees(evt.Id);
            System.assertEquals(1, all.size());
            System.assertEquals(true, all[0].mine);
            System.assertEquals('Draft', all[0].status);
            System.assertEquals('Emily Carter', all[0].attendeeName);
            System.assertEquals(
                'Acme Corporation',
                all[0].company,
                'Read from the Invitee_Org__c snapshot, not the lookup'
            );
        }
    }

    // ================= ★R6 attendance =================

    /** Drives one attendee all the way to Approved, through every level of its chain. */
    private static Id approvedInvitee(String lastName) {
        configureChain();
        User alex = findUser('amalex');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        Id att = attendeeId(lastName);
        System.runAs(alex) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ att });
            InviteeSelectorController.submitMyInvitees(evt.Id);
        }
        Id invId = [SELECT Id FROM Event_Invitee__c WHERE Event_Attendee__c = :att].Id;
        approveEveryLevel(invId);
        return invId;
    }

    /**
     * The R6 requirement: which events a person actually went to. Attendance is
     * recorded against the approved invitee, and the attendee reads its history
     * back through that same row — there is no second object holding it.
     */
    @IsTest
    static void attendanceIsRecordedAndReadableFromTheAttendee() {
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        Id emily = attendeeId('Carter');

        Test.startTest();
        Id invId = approvedInvitee('Carter');
        InviteeSelectorController.AttendanceResult res = InviteeSelectorController.saveAttendance(
            evt.Id,
            new List<Id>{ invId },
            new List<Id>()
        );
        Test.stopTest();

        System.assertEquals(1, res.marked);
        System.assertEquals(0, res.cleared);
        System.assertEquals(0, res.skippedNotApproved);

        // Read it the way the Attendee Event History report does: from the person.
        List<Event_Invitee__c> history = [
            SELECT Event_Name__c, Event_Date__c, Event_Type__c, Attended__c
            FROM Event_Invitee__c
            WHERE Event_Attendee__c = :emily AND Attended__c = TRUE
        ];
        System.assertEquals(1, history.size(), 'The attendee’s history is its invitee rows, not a separate object');
        System.assertEquals('Q3 2026 Customer Appreciation Gala', history[0].Event_Name__c);
        System.assertEquals('Conference', history[0].Event_Type__c, 'The event’s type reads up through the formula');
        System.assertNotEquals(null, history[0].Event_Date__c, 'Recency is half of any recommendation');
    }

    /** Marking is reversible — a mis-tick must be correctable, or nobody will tick honestly. */
    @IsTest
    static void attendanceCanBeCleared() {
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];

        Test.startTest();
        Id invId = approvedInvitee('Carter');
        InviteeSelectorController.saveAttendance(evt.Id, new List<Id>{ invId }, new List<Id>());
        InviteeSelectorController.AttendanceResult res = InviteeSelectorController.saveAttendance(
            evt.Id,
            new List<Id>(),
            new List<Id>{ invId }
        );
        Test.stopTest();

        System.assertEquals(1, res.cleared);
        System.assertEquals(false, [SELECT Attended__c FROM Event_Invitee__c WHERE Id = :invId].Attended__c);
    }

    /**
     * An unapproved invitee cannot be marked as attended. Without this the attendance
     * history quietly becomes a second, unreviewed guest list — and one bad row in a
     * batch must not fail the whole save either.
     */
    @IsTest
    static void markingAnUnapprovedInviteeIsReportedNotWritten() {
        User alex = findUser('amalex');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];

        Test.startTest();
        Id approved = approvedInvitee('Carter');
        Id draft;
        System.runAs(alex) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ attendeeId('Kim') });
            draft = [SELECT Id FROM Event_Invitee__c WHERE Event_Attendee__c = :attendeeId('Kim')].Id;
        }
        InviteeSelectorController.AttendanceResult res = InviteeSelectorController.saveAttendance(
            evt.Id,
            new List<Id>{ approved, draft },
            new List<Id>()
        );
        Test.stopTest();

        System.assertEquals(1, res.marked, 'The approved row still saves');
        System.assertEquals(1, res.skippedNotApproved, 'The draft row is reported, not silently dropped');
        System.assertEquals(false, [SELECT Attended__c FROM Event_Invitee__c WHERE Id = :draft].Attended__c);
    }

    /** …and the database refuses it too, so the guard does not depend on the controller. */
    @IsTest
    static void theDatabaseRefusesAttendanceWithoutApproval() {
        User alex = findUser('amalex');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        System.runAs(alex) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ attendeeId('Carter') });
        }
        Event_Invitee__c draft = [SELECT Id, Status__c FROM Event_Invitee__c LIMIT 1];
        System.assertEquals('Draft', draft.Status__c);

        Boolean threw = false;
        try {
            update new Event_Invitee__c(Id = draft.Id, Attended__c = true);
        } catch (DmlException e) {
            threw = true;
        }
        System.assert(threw, 'Attended_Requires_Approved must hold independently of the Apex');
    }

    /** An id belonging to another event must not be writable through this event's save. */
    @IsTest
    static void attendanceIsScopedToItsOwnEvent() {
        Marketing_Event__c other = new Marketing_Event__c(
            Name = 'Payments Innovation Symposium 2025',
            Event_Date__c = Date.today().addDays(-90),
            Event_Type__c = 'Symposium'
        );
        insert other;

        Test.startTest();
        Id invId = approvedInvitee('Carter');
        // Same invitee id, but saved against the wrong event.
        InviteeSelectorController.AttendanceResult res = InviteeSelectorController.saveAttendance(
            other.Id,
            new List<Id>{ invId },
            new List<Id>()
        );
        Test.stopTest();

        System.assertEquals(0, res.marked, 'The row belongs to a different event and must be out of reach');
        System.assertEquals(false, [SELECT Attended__c FROM Event_Invitee__c WHERE Id = :invId].Attended__c);
    }

    @IsTest
    static void savingNoAttendanceAtAllIsRefused() {
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        Boolean threw = false;
        try {
            InviteeSelectorController.saveAttendance(evt.Id, new List<Id>(), new List<Id>());
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assert(threw, 'An empty save is a client bug, not a silent no-op');
    }

    /** getAllInvitees has to tell the UI which rows are even tickable. */
    @IsTest
    static void inviteeRowsSayWhetherAttendanceCanBeRecorded() {
        User alex = findUser('amalex');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];

        Test.startTest();
        approvedInvitee('Carter');
        System.runAs(alex) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ attendeeId('Kim') });
        }
        Test.stopTest();

        Map<String, InviteeSelectorController.InviteeRow> byName = new Map<String, InviteeSelectorController.InviteeRow>();
        for (InviteeSelectorController.InviteeRow r : InviteeSelectorController.getAllInvitees(evt.Id)) {
            byName.put(r.attendeeName, r);
        }
        System.assertEquals(true, byName.get('Emily Carter').canAttend, 'Approved rows are tickable');
        System.assertEquals(false, byName.get('Robert Kim').canAttend, 'Draft rows are not');
        System.assertEquals(false, byName.get('Emily Carter').attended, 'Nothing is attended until somebody says so');
    }

    @IsTest
    static void addingNothingOrNobodyRealIsRefusedOrIgnored() {
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];

        Boolean threw = false;
        try {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>());
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assert(threw, 'An empty selection is a client bug, not a silent no-op');

        // A stale id from a client whose list is out of date must not create a row
        // pointing at nothing.
        Event_Attendee__c ghost = new Event_Attendee__c(
            Name = 'Ghost',
            Last_Name__c = 'Ghost',
            Unique_Key__c = 'ghost|||'
        );
        insert ghost;
        Id ghostId = ghost.Id;
        delete ghost;

        System.assertEquals(0, InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ ghostId }));
        System.assertEquals(0, [SELECT COUNT() FROM Event_Invitee__c]);
    }

    @IsTest
    static void submittingNothingIsRefused() {
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        Boolean threw = false;
        System.runAs(findUser('amalex')) {
            try {
                InviteeSelectorController.submitMyInvitees(evt.Id);
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        System.assert(threw, 'Nothing in Draft is a client bug, not a silent no-op');
    }
}
