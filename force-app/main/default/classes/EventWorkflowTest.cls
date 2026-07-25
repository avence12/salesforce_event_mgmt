/**
 * End-to-end workflow tests: add → submit (owner snapshot + notifications)
 * → approve/reject (completion notification) → export (per event and across all
 * events) → rejected re-add.
 * Two AMs and two Account Owners exercise the multi-AM, multi-owner grouping.
 */
@IsTest
private class EventWorkflowTest {

    private static User findUser(String alias) {
        return [SELECT Id, Name FROM User WHERE Alias = :alias AND IsActive = true LIMIT 1];
    }

    @TestSetup
    static void setup() {
        Profile std = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        List<User> users = new List<User>();
        for (String alias : new List<String>{ 'amalex', 'ammaria', 'ownsarah', 'ownmarc' }) {
            users.add(new User(
                Alias = alias,
                Username = alias + '.' + System.currentTimeMillis() + '@evtmgmt.poc.test',
                Email = alias + '@evtmgmt.poc.test',
                LastName = alias,
                ProfileId = std.Id,
                EmailEncodingKey = 'UTF-8',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                TimeZoneSidKey = 'America/New_York'
            ));
        }
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert users; // runAs guards against mixed-DML with the setup below
        }

        User sarah = users[2];
        User marcus = users[3];
        Account acme = new Account(Name = 'Acme Corp', OwnerId = sarah.Id);
        Account nordbank = new Account(Name = 'Nordbank AG', OwnerId = marcus.Id);
        insert new List<Account>{ acme, nordbank };

        insert new List<Contact>{
            new Contact(FirstName = 'Emily', LastName = 'Carter', Email = 'emily@acme.test', Title = 'Senior Manager', AccountId = acme.Id),
            new Contact(FirstName = 'Robert', LastName = 'Kim', Email = 'robert@acme.test', Title = 'SVP', AccountId = acme.Id),
            new Contact(FirstName = 'James', LastName = 'Mueller', Email = 'james@nordbank.test', Title = 'Director', AccountId = nordbank.Id)
        };

        insert new Marketing_Event__c(
            Name = 'Q3 2026 Customer Appreciation Gala',
            Event_Date__c = Date.today().addDays(60),
            Location__c = 'The Plaza, New York',
            Event_Type__c = 'Dinner / Gala'
        );
    }

    @IsTest
    static void fullWorkflow_submitApproveExport() {
        User alex = findUser('amalex');
        User maria = findUser('ammaria');
        User sarah = findUser('ownsarah');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        Contact emily = [SELECT Id FROM Contact WHERE Email = 'emily@acme.test'];
        Contact robert = [SELECT Id FROM Contact WHERE Email = 'robert@acme.test'];
        Contact james = [SELECT Id FROM Contact WHERE Email = 'james@nordbank.test'];

        // Alex adds two Acme contacts; Maria adds the Nordbank contact.
        System.runAs(alex) {
            Integer added = InviteeSelectorController.addInvitees(evt.Id, new List<Id>{ emily.Id, robert.Id });
            System.assertEquals(2, added);
            // Duplicate add is a no-op, not an error
            System.assertEquals(0, InviteeSelectorController.addInvitees(evt.Id, new List<Id>{ emily.Id }));
            InviteeSelectorController.SubmitResult sub = InviteeSelectorController.submitMyInvitees(evt.Id);
            System.assertEquals(2, sub.submitted);
            System.assertEquals(1, sub.ownersNotified, 'Both Acme contacts → one distinct owner (Sarah)');
        }
        System.runAs(maria) {
            InviteeSelectorController.addInvitees(evt.Id, new List<Id>{ james.Id });
            InviteeSelectorController.SubmitResult sub = InviteeSelectorController.submitMyInvitees(evt.Id);
            System.assertEquals(1, sub.submitted);
            System.assertEquals(1, sub.ownersNotified, 'Nordbank → Marcus');
        }

        // Owner snapshot must point at the account owners.
        for (Event_Invitee__c inv : [SELECT Account_Owner__c, Account__r.OwnerId, Status__c FROM Event_Invitee__c]) {
            System.assertEquals('Pending Approval', inv.Status__c);
            System.assertEquals(inv.Account__r.OwnerId, inv.Account_Owner__c);
        }

        // Sarah sees only her two (Acme) rows — Maria's Nordbank row belongs to Marcus.
        System.runAs(sarah) {
            List<ApprovalConsoleController.PendingInvitee> mine = ApprovalConsoleController.getPendingForMe(evt.Id);
            System.assertEquals(2, mine.size());

            // Approve one, reject one → Alex has zero pending left → completion notification fires.
            Test.startTest();
            ApprovalConsoleController.DecisionResult r1 = ApprovalConsoleController.decide(
                evt.Id, new List<Id>{ mine[0].inviteeId }, true);
            System.assertEquals(1, r1.decided);
            System.assertEquals(0, r1.amsNotified, 'Alex still has one pending row');

            ApprovalConsoleController.DecisionResult r2 = ApprovalConsoleController.decide(
                evt.Id, new List<Id>{ mine[1].inviteeId }, false);
            System.assertEquals(1, r2.decided);
            System.assertEquals(1, r2.amsNotified, 'Alex fully reviewed → notify him');
            Test.stopTest();
        }

        // Export as Alex: 1 approved row; flips to Exported; re-export still returns it.
        System.runAs(alex) {
            EventExportController.ExportResult ex1 = EventExportController.exportApproved(evt.Id);
            System.assertEquals(1, ex1.rowCount);
            System.assert(ex1.csv.startsWith('Name,Title,Account,Email,Approved By,Decided At'));
            System.assertEquals(1, [SELECT COUNT() FROM Event_Invitee__c WHERE Status__c = 'Exported']);

            EventExportController.ExportResult ex2 = EventExportController.exportApproved(evt.Id);
            System.assertEquals(1, ex2.rowCount, 'Re-export must return the full approved list');
        }
    }

    @IsTest
    static void exportAllApproved_spansEventsAndRespectsMineOnly() {
        User alex = findUser('amalex');
        User maria = findUser('ammaria');
        User sarah = findUser('ownsarah');
        User marcus = findUser('ownmarc');

        Marketing_Event__c gala = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        Marketing_Event__c summit = new Marketing_Event__c(
            Name = 'FinTech Summit, 2026', // the comma is deliberate — exercises CSV quoting
            Event_Date__c = Date.today().addDays(90),
            Location__c = 'Berlin',
            Event_Type__c = 'Dinner / Gala'
        );
        insert summit;

        Contact emily = [SELECT Id FROM Contact WHERE Email = 'emily@acme.test'];
        Contact james = [SELECT Id FROM Contact WHERE Email = 'james@nordbank.test'];

        System.runAs(alex) {
            InviteeSelectorController.addInvitees(gala.Id, new List<Id>{ emily.Id });
            InviteeSelectorController.submitMyInvitees(gala.Id);
        }
        System.runAs(maria) {
            InviteeSelectorController.addInvitees(summit.Id, new List<Id>{ james.Id });
            InviteeSelectorController.submitMyInvitees(summit.Id);
        }
        Event_Invitee__c emilyRow = [SELECT Id FROM Event_Invitee__c WHERE Contact__c = :emily.Id];
        Event_Invitee__c jamesRow = [SELECT Id FROM Event_Invitee__c WHERE Contact__c = :james.Id];

        Test.startTest();
        System.runAs(sarah) { ApprovalConsoleController.decide(gala.Id, new List<Id>{ emilyRow.Id }, true); }
        System.runAs(marcus) { ApprovalConsoleController.decide(summit.Id, new List<Id>{ jamesRow.Id }, true); }
        Test.stopTest();

        System.runAs(alex) {
            List<EventExportController.ApprovedSummary> all = EventExportController.getApprovedSummary(false);
            System.assertEquals(2, all.size(), 'Both events carry approved rows');
            for (EventExportController.ApprovedSummary s : all) {
                System.assertEquals(1, s.approvedCount);
                System.assertEquals(0, s.exportedCount);
                System.assertEquals(1, s.totalCount);
            }
            System.assertEquals(1, EventExportController.getApprovedSummary(true).size(),
                'mineOnly must drop the row Maria added');

            EventExportController.ExportResult ex = EventExportController.exportAllApproved(false);
            System.assertEquals(2, ex.rowCount);
            System.assertEquals(2, ex.eventCount);
            System.assertEquals(false, ex.truncated);
            System.assert(ex.csv.startsWith('Event,Event Date,Name,Title,Account,Email,Approved By,Decided At'),
                'Cross-event file needs the event columns');
            System.assert(ex.csv.contains('\r\n'), 'CRLF line endings — desktop Excel chokes on bare LF');
            System.assert(ex.csv.contains('"FinTech Summit, 2026"'), 'A value with a comma must be quoted');
            System.assertEquals(2, [SELECT COUNT() FROM Event_Invitee__c WHERE Status__c = 'Exported'],
                'Downloading everything marks everything Exported');

            System.assertEquals(2, EventExportController.exportAllApproved(false).rowCount,
                'Re-download must return the full approved list, not only new rows');

            EventExportController.ExportResult justMine = EventExportController.exportAllApproved(true);
            System.assertEquals(1, justMine.rowCount);
            System.assertEquals(1, justMine.eventCount);

            EventExportController.rowLimit = 1;
            EventExportController.ExportResult capped = EventExportController.exportAllApproved(false);
            System.assertEquals(1, capped.rowCount);
            System.assertEquals(true, capped.truncated, 'Row cap must be reported, not silently applied');
        }
    }

    @IsTest
    static void exportAllApproved_withNothingApprovedThrows() {
        User alex = findUser('amalex');
        System.runAs(alex) {
            System.assertEquals(0, EventExportController.getApprovedSummary(false).size());
            Boolean threw = false;
            try { EventExportController.exportAllApproved(false); }
            catch (AuraHandledException e) { threw = true; }
            System.assert(threw, 'Nothing approved → explicit error, not an empty file');
        }
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
        System.runAs(sarah) {
            ApprovalConsoleController.decide(evt.Id, new List<Id>{ inv.Id }, false);
        }

        System.runAs(alex) {
            Integer added = InviteeSelectorController.addInvitees(evt.Id, new List<Id>{ emily.Id });
            System.assertEquals(1, added, 'Rejected row should reset, not error');
        }
        inv = [SELECT Status__c, Submitted_At__c, Decided_At__c, Account_Owner__c FROM Event_Invitee__c WHERE Id = :inv.Id];
        System.assertEquals('Draft', inv.Status__c);
        System.assertEquals(null, inv.Submitted_At__c);
        System.assertEquals(null, inv.Decided_At__c);
        System.assertEquals(null, inv.Account_Owner__c);
        System.assertEquals(1, [SELECT COUNT() FROM Event_Invitee__c WHERE Contact__c = :emily.Id],
            'Never a second row per event+contact');
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
            List<InviteeSelectorController.SelectableContact> sel = InviteeSelectorController.getSelectableContacts(evt.Id);
            System.assertEquals(2, sel.size(), 'Only contacts under accounts Alex owns');

            InviteeSelectorController.addInvitees(evt.Id, new List<Id>{ c1.Id });
            sel = InviteeSelectorController.getSelectableContacts(evt.Id);
            System.assertEquals(1, sel.size(), 'Invited (Draft) contact must be hidden');
            System.assertEquals(c2.Id, sel[0].contactId);

            List<InviteeSelectorController.InviteeRow> all = InviteeSelectorController.getAllInvitees(evt.Id);
            System.assertEquals(1, all.size());
            System.assertEquals(true, all[0].mine);
            System.assertEquals('Draft', all[0].status);
        }
    }

    @IsTest
    static void decideRejectsForeignRows() {
        User alex = findUser('amalex');
        User marcus = findUser('ownmarc');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        Contact emily = [SELECT Id FROM Contact WHERE Email = 'emily@acme.test'];

        System.runAs(alex) {
            InviteeSelectorController.addInvitees(evt.Id, new List<Id>{ emily.Id });
            InviteeSelectorController.submitMyInvitees(evt.Id);
        }
        Event_Invitee__c inv = [SELECT Id FROM Event_Invitee__c WHERE Contact__c = :emily.Id];

        // Marcus is not the owner of Acme — deciding Sarah's row must fail.
        System.runAs(marcus) {
            Boolean threw = false;
            try { ApprovalConsoleController.decide(evt.Id, new List<Id>{ inv.Id }, true); }
            catch (AuraHandledException e) { threw = true; }
            System.assert(threw, 'Owners can only decide their own pending rows');
        }
    }
}
