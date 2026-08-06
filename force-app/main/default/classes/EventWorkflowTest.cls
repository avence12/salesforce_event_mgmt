/**
 * End-to-end workflow tests: add → submit (approver ladder + notifications) →
 * approve/reject through the standard approval process → completion notification →
 * rejected re-add.
 *
 * Two AMs and two Account Owners exercise the multi-AM, multi-owner grouping. The
 * export tests that used to live here went with EventExportController — that path is
 * two saved reports now, and a report is not something Apex can meaningfully assert on.
 */
@IsTest
private class EventWorkflowTest {
    private static User findUser(String alias) {
        return [SELECT Id, Name, ManagerId FROM User WHERE Alias = :alias AND IsActive = TRUE LIMIT 1];
    }

    /** Approves or rejects through the platform, the way the Approvals list does. */
    private static void decide(Id recordId, Boolean approve) {
        Approval.ProcessWorkitemRequest req = new Approval.ProcessWorkitemRequest();
        req.setWorkitemId(
            [SELECT Id FROM ProcessInstanceWorkitem WHERE ProcessInstance.TargetObjectId = :recordId LIMIT 1].Id
        );
        req.setAction(approve ? 'Approve' : 'Reject');
        Approval.process(req);
    }

    @TestSetup
    static void setup() {
        Profile std = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        List<User> users = new List<User>();
        for (String alias : new List<String>{ 'amalex', 'ammaria', 'ownsarah', 'ownmarc', 'mgrdana' }) {
            users.add(
                new User(
                    Alias = alias,
                    Username = alias + '.' + System.currentTimeMillis() + '@evtmgmt.poc.test',
                    Email = alias + '@evtmgmt.poc.test',
                    LastName = alias,
                    ProfileId = std.Id,
                    EmailEncodingKey = 'UTF-8',
                    LanguageLocaleKey = 'en_US',
                    LocaleSidKey = 'en_US',
                    TimeZoneSidKey = 'America/New_York'
                )
            );
        }
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert users; // runAs guards against mixed-DML with the setup below
            // Dana manages both AMs — ladder rule 3, and the only approver a
            // self-owned lead can reach.
            update new List<User>{
                new User(Id = users[0].Id, ManagerId = users[4].Id),
                new User(Id = users[1].Id, ManagerId = users[4].Id)
            };
        }

        User sarah = users[2];
        User marcus = users[3];
        Account acme = new Account(Name = 'Acme Corp', OwnerId = sarah.Id);
        Account nordbank = new Account(Name = 'Nordbank AG', OwnerId = marcus.Id);
        insert new List<Account>{ acme, nordbank };

        insert new List<Contact>{
            new Contact(
                FirstName = 'Emily',
                LastName = 'Carter',
                Email = 'emily@acme.test',
                Title = 'Senior Manager',
                AccountId = acme.Id
            ),
            new Contact(
                FirstName = 'Robert',
                LastName = 'Kim',
                Email = 'robert@acme.test',
                Title = 'SVP',
                AccountId = acme.Id
            ),
            new Contact(
                FirstName = 'James',
                LastName = 'Mueller',
                Email = 'james@nordbank.test',
                Title = 'Director',
                AccountId = nordbank.Id
            )
        };

        insert new Marketing_Event__c(
            Name = 'Q3 2026 Customer Appreciation Gala',
            Event_Date__c = Date.today().addDays(60),
            Location__c = 'The Plaza, New York',
            Event_Type__c = 'Dinner / Gala'
        );
    }

    @IsTest
    static void fullWorkflow_submitApproveReject() {
        User alex = findUser('amalex');
        User maria = findUser('ammaria');
        User sarah = findUser('ownsarah');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        Contact emily = [SELECT Id FROM Contact WHERE Email = 'emily@acme.test'];
        Contact robert = [SELECT Id FROM Contact WHERE Email = 'robert@acme.test'];
        Contact james = [SELECT Id FROM Contact WHERE Email = 'james@nordbank.test'];

        System.runAs(alex) {
            Integer added = InviteeSelectorController.addInvitees(evt.Id, new List<Id>{ emily.Id, robert.Id });
            System.assertEquals(2, added);
            // Duplicate add is a no-op, not an error
            System.assertEquals(0, InviteeSelectorController.addInvitees(evt.Id, new List<Id>{ emily.Id }));
            InviteeSelectorController.SubmitResult sub = InviteeSelectorController.submitMyInvitees(evt.Id);
            System.assertEquals(2, sub.submitted);
            System.assertEquals(1, sub.approversNotified, 'Both Acme contacts → one distinct approver (Sarah)');
        }
        System.runAs(maria) {
            InviteeSelectorController.addInvitees(evt.Id, new List<Id>{ james.Id });
            InviteeSelectorController.SubmitResult sub = InviteeSelectorController.submitMyInvitees(evt.Id);
            System.assertEquals(1, sub.approversNotified, 'Nordbank → Marcus');
        }

        // The approval process, not our Apex, owns the status from submission onwards.
        for (Event_Invitee__c inv : [
            SELECT Account_Owner__c, Approver__c, Account__r.OwnerId, Status__c, Submitted_At__c
            FROM Event_Invitee__c
        ]) {
            System.assertEquals('Pending Approval', inv.Status__c, 'Initial submission action must set the status');
            System.assertEquals(inv.Account__r.OwnerId, inv.Approver__c, 'Ladder rule 1: the Account Owner approves');
            System.assertEquals(inv.Account__r.OwnerId, inv.Account_Owner__c, 'Audit snapshot still taken');
            System.assertNotEquals(null, inv.Submitted_At__c);
        }
        System.assertEquals(3, [SELECT COUNT() FROM ProcessInstance], 'One approval instance per invitee');

        List<Event_Invitee__c> acmeRows = [
            SELECT Id
            FROM Event_Invitee__c
            WHERE Contact__c IN (:emily.Id, :robert.Id)
            ORDER BY Id
        ];

        Test.startTest();
        System.runAs(sarah) {
            decide(acmeRows[0].Id, true);
            decide(acmeRows[1].Id, false);
        }
        Test.stopTest();

        Map<Id, Event_Invitee__c> after = new Map<Id, Event_Invitee__c>(
            [SELECT Id, Status__c, Decided_At__c FROM Event_Invitee__c WHERE Id IN :acmeRows]
        );
        System.assertEquals('Approved', after.get(acmeRows[0].Id).Status__c);
        System.assertEquals('Rejected', after.get(acmeRows[1].Id).Status__c);
        for (Event_Invitee__c inv : after.values()) {
            System.assertNotEquals(null, inv.Decided_At__c, 'Stamp_Decided_At runs on both outcomes');
        }

        Marketing_Event__c counts = [
            SELECT Approved_Count__c, Rejected_Count__c, Pending_Count__c
            FROM Marketing_Event__c
            WHERE Id = :evt.Id
        ];
        System.assertEquals(1, counts.Approved_Count__c);
        System.assertEquals(1, counts.Rejected_Count__c);
        System.assertEquals(1, counts.Pending_Count__c, 'Maria\'s Nordbank row is untouched');
    }

    /**
     * The case the whole Lead model exists for, and the one that would look identical
     * to success if it were wrong: an AM adds a professor they own as a Lead. Rule 2's
     * exclusion must send it to their *manager*, because routing it to the Lead Owner
     * would mean the submitter approving their own guest.
     */
    @IsTest
    static void leadInviteeRoutesToManagerNotToItsOwner() {
        User alex = findUser('amalex');
        User dana = findUser('mgrdana');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];

        Lead prof;
        System.runAs(alex) {
            prof = new Lead(
                FirstName = 'Hélène',
                LastName = 'Dubois',
                Company = 'Université de Genève',
                Title = 'Professor of Cryptography',
                Email = 'h.dubois@unige.test',
                OwnerId = alex.Id
            );
            insert prof;

            InviteeSelectorController.SelectableResult sel = InviteeSelectorController.getSelectableLeads(evt.Id);
            System.assertEquals(1, sel.contacts.size(), 'Alex owns exactly one unconverted lead');
            System.assertEquals(prof.Id, sel.contacts[0].leadId);
            System.assertEquals(
                'Université de Genève',
                sel.contacts[0].accountName,
                'Company text stands in for Account'
            );

            System.assertEquals(1, InviteeSelectorController.addLeadInvitees(evt.Id, new List<Id>{ prof.Id }));
            InviteeSelectorController.SubmitResult sub = InviteeSelectorController.submitMyInvitees(evt.Id);
            System.assertEquals(1, sub.submitted);
        }

        Event_Invitee__c inv = [
            SELECT
                Status__c,
                Approver__c,
                Account__c,
                Account_Owner__c,
                Invitee_Name__c,
                Invitee_Org__c,
                Invitee_Type__c
            FROM Event_Invitee__c
            WHERE Lead__c = :prof.Id
        ];
        System.assertEquals(dana.Id, inv.Approver__c, 'A self-owned lead must never route back to its submitter');
        System.assertNotEquals(alex.Id, inv.Approver__c);
        System.assertEquals(null, inv.Account__c, 'A lead invitee has no customer Account — that is the point');
        System.assertEquals(null, inv.Account_Owner__c);
        System.assertEquals('Pending Approval', inv.Status__c);

        // The formula fields are what let one report cover both kinds of invitee.
        System.assertEquals('Hélène Dubois', inv.Invitee_Name__c);
        System.assertEquals('Université de Genève', inv.Invitee_Org__c);
        System.assertEquals('Lead', inv.Invitee_Type__c);

        Test.startTest();
        System.runAs(dana) {
            decide([SELECT Id FROM Event_Invitee__c WHERE Lead__c = :prof.Id].Id, true);
        }
        Test.stopTest();

        System.assertEquals(
            'Approved',
            [SELECT Status__c FROM Event_Invitee__c WHERE Lead__c = :prof.Id].Status__c,
            'The manager can decide it — it is a real work item, not an orphan'
        );

        // No Account was invented anywhere along the way.
        System.assertEquals(
            0,
            [SELECT COUNT() FROM Account WHERE Name = 'Université de Genève'],
            'Account means transacting customer — a university must never become one'
        );
    }

    /** A lead owned by someone else routes to that owner: rule 2 without the exclusion. */
    @IsTest
    static void leadOwnedByAnotherUserRoutesToThatOwner() {
        User alex = findUser('amalex');
        User marcus = findUser('ownmarc');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];

        Lead speaker = new Lead(
            FirstName = 'Tomas',
            LastName = 'Lindqvist',
            Company = 'KTH Royal Institute',
            Email = 't.lindqvist@kth.test',
            OwnerId = marcus.Id
        );
        insert speaker;

        System.runAs(alex) {
            InviteeSelectorController.addLeadInvitees(evt.Id, new List<Id>{ speaker.Id });
            InviteeSelectorController.submitMyInvitees(evt.Id);
        }
        System.assertEquals(
            marcus.Id,
            [SELECT Approver__c FROM Event_Invitee__c WHERE Lead__c = :speaker.Id].Approver__c,
            'Rule 2: the lead owner holds the relationship, so they sign it off'
        );
    }

    /**
     * The orphan-row defect, made unreachable. A submitter with no manager adding a
     * lead they own has nobody left on the ladder; the submit must fail with a named
     * error and leave everything in Draft, rather than creating a pending row that no
     * approver can ever see.
     */
    @IsTest
    static void unroutableSubmitIsRefusedAndNothingMoves() {
        User maria = findUser('ammaria');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            update new User(Id = maria.Id, ManagerId = null);
        }
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];

        System.runAs(maria) {
            Lead l = new Lead(
                FirstName = 'Ana',
                LastName = 'Ferreira',
                Company = 'Instituto Superior Técnico',
                Email = 'a.ferreira@ist.test',
                OwnerId = maria.Id
            );
            insert l;
            InviteeSelectorController.addLeadInvitees(evt.Id, new List<Id>{ l.Id });

            Boolean threw = false;
            try {
                InviteeSelectorController.submitMyInvitees(evt.Id);
            } catch (AuraHandledException e) {
                threw = true;
            }
            System.assert(threw, 'No approver on the ladder → the submit must fail loudly');
        }

        System.assertEquals(
            0,
            [SELECT COUNT() FROM Event_Invitee__c WHERE Status__c = 'Pending Approval'],
            'A refused submit must move nothing — no half-submitted batch'
        );
        System.assertEquals(1, [SELECT COUNT() FROM Event_Invitee__c WHERE Status__c = 'Draft']);
        System.assertEquals(0, [SELECT COUNT() FROM ProcessInstance], 'Nothing entered the approval process');
    }

    /** An invitee must point at exactly one of Contact / Lead — the XOR validation rule. */
    @IsTest
    static void inviteeCannotBeBothOrNeither() {
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        Contact emily = [SELECT Id FROM Contact WHERE Email = 'emily@acme.test'];
        Lead l = new Lead(LastName = 'Nobody', Company = 'Nowhere University', Email = 'n@nowhere.test');
        insert l;

        Boolean neitherThrew = false;
        try {
            insert new Event_Invitee__c(Marketing_Event__c = evt.Id, Status__c = 'Draft', Unique_Key__c = 'k-neither');
        } catch (DmlException e) {
            neitherThrew = true;
        }
        System.assert(neitherThrew, 'An invitee pointing at nobody must be refused');

        Boolean bothThrew = false;
        try {
            insert new Event_Invitee__c(
                Marketing_Event__c = evt.Id,
                Contact__c = emily.Id,
                Lead__c = l.Id,
                Status__c = 'Draft',
                Unique_Key__c = 'k-both'
            );
        } catch (DmlException e) {
            bothThrew = true;
        }
        System.assert(bothThrew, 'Two identities on one row would silently prefer the Contact');
    }

    @IsTest
    static void completionNotificationFiresOnlyWhenTheBatchIsDone() {
        User alex = findUser('amalex');
        User sarah = findUser('ownsarah');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        Contact emily = [SELECT Id FROM Contact WHERE Email = 'emily@acme.test'];
        Contact robert = [SELECT Id FROM Contact WHERE Email = 'robert@acme.test'];

        System.runAs(alex) {
            InviteeSelectorController.addInvitees(evt.Id, new List<Id>{ emily.Id, robert.Id });
            InviteeSelectorController.submitMyInvitees(evt.Id);
        }
        List<Event_Invitee__c> rows = [SELECT Id FROM Event_Invitee__c ORDER BY Id];

        Test.startTest();
        EventNotificationService.emailsSent = 0;
        // One of two decided: the AM still has something pending, so stay quiet.
        System.runAs(sarah) {
            decide(rows[0].Id, true);
        }
        EventNotificationService.notifyCompletions(new List<Id>{ rows[0].Id });
        System.assertEquals(0, EventNotificationService.emailsSent, 'One row left pending — no completion email yet');

        System.runAs(sarah) {
            decide(rows[1].Id, true);
        }
        EventNotificationService.notifyCompletions(new List<Id>{ rows[1].Id });
        System.assertEquals(1, EventNotificationService.emailsSent, 'Zero pending left → notify the AM once');
        Test.stopTest();
    }

    /** Mass approval arrives as one invocable call with every id — one email, not forty. */
    @IsTest
    static void completionNotificationAggregatesABulkDecision() {
        User alex = findUser('amalex');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        List<Contact> cs = [SELECT Id FROM Contact WHERE Email LIKE '%acme.test'];

        System.runAs(alex) {
            InviteeSelectorController.addInvitees(evt.Id, new List<Id>(new Map<Id, Contact>(cs).keySet()));
            InviteeSelectorController.submitMyInvitees(evt.Id);
        }
        Test.startTest();
        // Decided directly rather than through the approval process: this test is about
        // the invocable's aggregation, and driving 2+ work items adds nothing to that.
        List<Id> ids = new List<Id>();
        List<Event_Invitee__c> all = [SELECT Id, Status__c FROM Event_Invitee__c];
        for (Event_Invitee__c inv : all) {
            inv.Status__c = 'Approved';
            ids.add(inv.Id);
        }
        update all;

        EventNotificationService.emailsSent = 0;
        EventNotificationService.notifyCompletions(ids);
        System.assertEquals(1, EventNotificationService.emailsSent, 'Two rows, one AM, one event → exactly one email');
        Test.stopTest();
    }

    @IsTest
    static void rejectedContactCanBeReAdded() {
        User alex = findUser('amalex');
        User sarah = findUser('ownsarah');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        Contact emily = [SELECT Id FROM Contact WHERE Email = 'emily@acme.test'];

        System.runAs(alex) {
            InviteeSelectorController.addInvitees(evt.Id, new List<Id>{ emily.Id });
            InviteeSelectorController.submitMyInvitees(evt.Id);
        }
        Event_Invitee__c inv = [SELECT Id FROM Event_Invitee__c WHERE Contact__c = :emily.Id];

        Test.startTest();
        System.runAs(sarah) {
            decide(inv.Id, false);
        }
        Test.stopTest();

        System.runAs(alex) {
            Integer added = InviteeSelectorController.addInvitees(evt.Id, new List<Id>{ emily.Id });
            System.assertEquals(1, added, 'Rejected row should reset, not error');
        }
        inv = [
            SELECT Status__c, Submitted_At__c, Decided_At__c, Account_Owner__c, Approver__c
            FROM Event_Invitee__c
            WHERE Id = :inv.Id
        ];
        System.assertEquals('Draft', inv.Status__c);
        System.assertEquals(null, inv.Submitted_At__c);
        System.assertEquals(null, inv.Decided_At__c);
        System.assertEquals(null, inv.Account_Owner__c);
        System.assertEquals(
            null,
            inv.Approver__c,
            'A stale approver would let the next submit skip the ladder and reuse whoever decided last time'
        );
        System.assertEquals(
            1,
            [SELECT COUNT() FROM Event_Invitee__c WHERE Contact__c = :emily.Id],
            'Never a second row per event+contact'
        );
    }

    @IsTest
    static void selectorScopesToMyAccountsAndHidesInvited() {
        User alex = findUser('amalex');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];

        // Give Alex an account of his own for the owner-path scope test.
        Account mine = new Account(Name = 'Alex Own Account', OwnerId = alex.Id);
        insert mine;
        Contact c1 = new Contact(FirstName = 'Own', LastName = 'Contact1', Email = 'own1@x.test', AccountId = mine.Id);
        Contact c2 = new Contact(FirstName = 'Own', LastName = 'Contact2', Email = 'own2@x.test', AccountId = mine.Id);
        insert new List<Contact>{ c1, c2 };

        System.runAs(alex) {
            InviteeSelectorController.SelectableResult sel = InviteeSelectorController.getSelectableContacts(evt.Id);
            System.assertEquals(2, sel.contacts.size(), 'Only contacts under accounts Alex owns');
            System.assertEquals(false, sel.truncated, 'Two contacts is nowhere near the cap');
            System.assertEquals(InviteeSelectorController.CONTACT_CAP, sel.cap);

            InviteeSelectorController.addInvitees(evt.Id, new List<Id>{ c1.Id });
            sel = InviteeSelectorController.getSelectableContacts(evt.Id);
            System.assertEquals(1, sel.contacts.size(), 'Invited (Draft) contact must be hidden');
            System.assertEquals(c2.Id, sel.contacts[0].contactId);

            List<InviteeSelectorController.InviteeRow> all = InviteeSelectorController.getAllInvitees(evt.Id);
            System.assertEquals(1, all.size());
            System.assertEquals(true, all[0].mine);
            System.assertEquals('Draft', all[0].status);
            System.assertEquals('Contact', all[0].inviteeType);
            System.assertEquals('Alex Own Account', all[0].accountName, 'Read through Invitee_Org__c, not Account__r');
        }
    }

    /** A converted lead is not selectable — its Contact is the thing to invite. */
    @IsTest
    static void convertedAndInvitedLeadsAreHidden() {
        User alex = findUser('amalex');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];

        Lead keep = new Lead(LastName = 'Keeper', Company = 'ETH Zürich', Email = 'k@eth.test', OwnerId = alex.Id);
        Lead invite = new Lead(LastName = 'Invited', Company = 'ETH Zürich', Email = 'i@eth.test', OwnerId = alex.Id);
        insert new List<Lead>{ keep, invite };

        System.runAs(alex) {
            InviteeSelectorController.addLeadInvitees(evt.Id, new List<Id>{ invite.Id });
            InviteeSelectorController.SelectableResult sel = InviteeSelectorController.getSelectableLeads(evt.Id);
            System.assertEquals(1, sel.contacts.size(), 'The invited lead must drop out of the list');
            System.assertEquals(keep.Id, sel.contacts[0].leadId);
        }
    }
}
