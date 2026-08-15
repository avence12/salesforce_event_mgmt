/**
 * ★R8 Screen 4b — the approver's company-grouped view and the bulk decision behind it.
 *
 * Two AMs report to one manager, who is therefore the approver for both of their batches.
 * That shape is what makes the grouping worth testing at all: one approver, several
 * companies, invitees submitted by different people.
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

    @TestSetup
    static void setup() {
        Profile std = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        List<User> users = new List<User>();
        for (String alias : new List<String>{ 'apalex', 'apmaria', 'apdana' }) {
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
            insert users;
            update new List<User>{
                new User(Id = users[0].Id, ManagerId = users[2].Id),
                new User(Id = users[1].Id, ManagerId = users[2].Id)
            };
        }

        insert new List<Event_Attendee__c>{
            attendee('Emily', 'Carter', 'Acme Corp'),
            attendee('Robert', 'Kim', 'Acme Corp'),
            attendee('James', 'Mueller', 'Nordbank AG'),
            attendee('Hélène', 'Dubois', 'Université de Genève')
        };

        insert new Marketing_Event__c(
            Name = 'Q4 2026 Risk Symposium',
            Event_Date__c = Date.today().addDays(45),
            Event_Type__c = 'Symposium'
        );
    }

    /** Adds and submits a batch as the given AM, leaving the rows Pending on their manager. */
    private static void submitAs(User am, List<Id> attendeeIds) {
        Marketing_Event__c evt = theEvent();
        System.runAs(am) {
            InviteeSelectorController.addAttendees(evt.Id, attendeeIds);
            InviteeSelectorController.submitMyInvitees(evt.Id);
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

    @IsTest
    static void pendingWorkIsGroupedByTheCompanyTheyWereInvitedAs() {
        User alex = findUser('apalex');
        User dana = findUser('apdana');
        submitAs(alex, new List<Id>{ attendeeId('Carter'), attendeeId('Kim'), attendeeId('Mueller') });

        List<InviteeApprovalController.CompanyGroup> groups;
        System.runAs(dana) {
            groups = InviteeApprovalController.getMyPendingByCompany(theEvent().Id);
        }

        Map<String, InviteeApprovalController.CompanyGroup> byName = groupsByCompany(groups);
        System.assertEquals(2, groups.size(), 'Two companies, not three people');
        System.assertEquals(2, byName.get('Acme Corp').invitees.size());
        System.assertEquals(1, byName.get('Nordbank AG').invitees.size());
        // No Contact behind any of them, so no customer — stated rather than left blank.
        System.assertEquals(false, byName.get('Acme Corp').hasCustomer);
        System.assertEquals(null, byName.get('Acme Corp').custCd);
    }

    @IsTest
    static void aLinkedCustomerGroupsByAccountAndCarriesItsCode() {
        User alex = findUser('apalex');
        User dana = findUser('apdana');

        Account acme = new Account(Name = 'Acme Corporation', AccountNumber = 'CUST-0042');
        insert acme;
        Contact emily = new Contact(FirstName = 'Emily', LastName = 'Carter', AccountId = acme.Id);
        insert emily;
        update new Event_Attendee__c(Id = attendeeId('Carter'), Contact__c = emily.Id);

        submitAs(alex, new List<Id>{ attendeeId('Carter'), attendeeId('Kim') });

        List<InviteeApprovalController.CompanyGroup> groups;
        System.runAs(dana) {
            groups = InviteeApprovalController.getMyPendingByCompany(theEvent().Id);
        }

        Map<String, InviteeApprovalController.CompanyGroup> byName = groupsByCompany(groups);
        // Emily now groups under the Account's name; Robert still under the imported text.
        // Two spellings of one organisation therefore stay apart until both are linked,
        // which is the honest state rather than a merge nobody authorised.
        System.assertEquals(2, groups.size());
        System.assertEquals(true, byName.get('Acme Corporation').hasCustomer);
        System.assertEquals('CUST-0042', byName.get('Acme Corporation').custCd);
        System.assertEquals(false, byName.get('Acme Corp').hasCustomer);
    }

    @IsTest
    static void anApproverSeesOnlyWhatIsWaitingOnThem() {
        User alex = findUser('apalex');
        User dana = findUser('apdana');
        submitAs(alex, new List<Id>{ attendeeId('Carter') });

        List<InviteeApprovalController.CompanyGroup> asSubmitter;
        System.runAs(alex) {
            asSubmitter = InviteeApprovalController.getMyPendingByCompany(theEvent().Id);
        }
        System.assertEquals(0, asSubmitter.size(), 'The submitter is not the approver and sees nothing here');

        List<InviteeApprovalController.CompanyGroup> asApprover;
        System.runAs(dana) {
            asApprover = InviteeApprovalController.getMyPendingByCompany(theEvent().Id);
        }
        System.assertEquals(1, asApprover.size());
    }

    @IsTest
    static void approvingACompanyDecidesEveryRowInIt() {
        User alex = findUser('apalex');
        User dana = findUser('apdana');
        submitAs(alex, new List<Id>{ attendeeId('Carter'), attendeeId('Kim'), attendeeId('Mueller') });

        List<Id> acmeIds = new List<Id>();
        for (Event_Invitee__c inv : [
            SELECT Id
            FROM Event_Invitee__c
            WHERE Invitee_Org__c = 'Acme Corp'
        ]) {
            acmeIds.add(inv.Id);
        }

        InviteeApprovalController.DecisionResult res;
        Test.startTest();
        System.runAs(dana) {
            res = InviteeApprovalController.decide(theEvent().Id, acmeIds, true, 'Fine by me');
        }
        Test.stopTest();

        System.assertEquals(2, res.decided);
        System.assertEquals(0, res.skipped);

        Map<String, String> statusByOrg = new Map<String, String>();
        for (Event_Invitee__c inv : [SELECT Invitee_Org__c, Status__c FROM Event_Invitee__c]) {
            statusByOrg.put(inv.Invitee_Org__c, inv.Status__c);
        }
        System.assertEquals('Approved', statusByOrg.get('Acme Corp'), 'The approval process wrote the status');
        System.assertEquals(
            'Pending Approval',
            statusByOrg.get('Nordbank AG'),
            'A company-scoped decision must not reach another company'
        );
    }

    @IsTest
    static void rejectingWorksThroughTheSameProcess() {
        User alex = findUser('apalex');
        User dana = findUser('apdana');
        submitAs(alex, new List<Id>{ attendeeId('Dubois') });
        Id inviteeId = [SELECT Id FROM Event_Invitee__c LIMIT 1].Id;

        Test.startTest();
        System.runAs(dana) {
            InviteeApprovalController.decide(theEvent().Id, new List<Id>{ inviteeId }, false, 'Not this time');
        }
        Test.stopTest();

        System.assertEquals('Rejected', [SELECT Status__c FROM Event_Invitee__c WHERE Id = :inviteeId].Status__c);
        System.assertNotEquals(null, [SELECT Decided_At__c FROM Event_Invitee__c WHERE Id = :inviteeId].Decided_At__c);
    }

    /**
     * The client's list is a request, not an instruction. A caller who sends an id that is
     * pending on somebody else must not decide it — this is the reason the controller
     * re-queries instead of trusting what arrives.
     */
    @IsTest
    static void anIdPendingOnSomebodyElseIsDroppedNotDecided() {
        User alex = findUser('apalex');
        User maria = findUser('apmaria');
        User dana = findUser('apdana');

        // Give Maria a different manager, so her batch is pending on somebody who is not Dana.
        User otherManager;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile std = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
            otherManager = new User(
                Alias = 'apotr',
                Username = 'apotr.' + System.currentTimeMillis() + '@evtmgmt.poc.test',
                Email = 'apotr@evtmgmt.poc.test',
                LastName = 'apotr',
                ProfileId = std.Id,
                EmailEncodingKey = 'UTF-8',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                TimeZoneSidKey = 'America/New_York'
            );
            insert otherManager;
            update new User(Id = maria.Id, ManagerId = otherManager.Id);
        }

        submitAs(alex, new List<Id>{ attendeeId('Carter') });
        submitAs(maria, new List<Id>{ attendeeId('Mueller') });

        Id mine = [SELECT Id FROM Event_Invitee__c WHERE Invitee_Org__c = 'Acme Corp' LIMIT 1].Id;
        Id notMine = [SELECT Id FROM Event_Invitee__c WHERE Invitee_Org__c = 'Nordbank AG' LIMIT 1].Id;

        InviteeApprovalController.DecisionResult res;
        Test.startTest();
        System.runAs(dana) {
            res = InviteeApprovalController.decide(theEvent().Id, new List<Id>{ mine, notMine }, true, null);
        }
        Test.stopTest();

        System.assertEquals(1, res.decided, 'Only the row actually assigned to this approver');
        System.assertEquals(1, res.skipped, 'And the other one is reported, not silently absent');
        System.assertEquals('Approved', [SELECT Status__c FROM Event_Invitee__c WHERE Id = :mine].Status__c);
        System.assertEquals(
            'Pending Approval',
            [SELECT Status__c FROM Event_Invitee__c WHERE Id = :notMine].Status__c,
            'A row pending on another approver is untouched'
        );
    }

    @IsTest
    static void decidingNothingIsRefused() {
        User dana = findUser('apdana');
        Boolean threw = false;
        System.runAs(dana) {
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
        User alex = findUser('apalex');
        User dana = findUser('apdana');
        submitAs(alex, new List<Id>{ attendeeId('Carter') });
        Id real = [SELECT Id FROM Event_Invitee__c LIMIT 1].Id;

        List<Id> tooMany = new List<Id>();
        for (Integer i = 0; i <= InviteeApprovalController.MAX_PER_DECISION; i++) {
            tooMany.add(real);
        }

        Boolean threw = false;
        System.runAs(dana) {
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
    }

    /** A row decided between load and click: refused with an explanation, nothing changed. */
    @IsTest
    static void decidingAnAlreadyDecidedRowIsRefused() {
        User alex = findUser('apalex');
        User dana = findUser('apdana');
        submitAs(alex, new List<Id>{ attendeeId('Carter') });
        Id inviteeId = [SELECT Id FROM Event_Invitee__c LIMIT 1].Id;

        Test.startTest();
        System.runAs(dana) {
            InviteeApprovalController.decide(theEvent().Id, new List<Id>{ inviteeId }, true, null);

            Boolean threw = false;
            try {
                InviteeApprovalController.decide(theEvent().Id, new List<Id>{ inviteeId }, true, null);
            } catch (AuraHandledException e) {
                threw = true;
            }
            System.assertEquals(true, threw, 'The second decision has no work item to act on');
        }
        Test.stopTest();

        System.assertEquals('Approved', [SELECT Status__c FROM Event_Invitee__c WHERE Id = :inviteeId].Status__c);
    }

    /**
     * The same guarantee EventWorkflowTest makes for submit and decide, restated for the
     * one screen that reads an Account in order to group by it.
     */
    @IsTest
    static void theApprovalScreenNeverWritesToAccountOrContact() {
        User alex = findUser('apalex');
        User dana = findUser('apdana');

        Account acme = new Account(Name = 'Acme Corporation', AccountNumber = 'CUST-0042');
        insert acme;
        Contact emily = new Contact(FirstName = 'Emily', LastName = 'Carter', AccountId = acme.Id);
        insert emily;
        update new Event_Attendee__c(Id = attendeeId('Carter'), Contact__c = emily.Id);

        submitAs(alex, new List<Id>{ attendeeId('Carter') });
        Account before = [SELECT Id, Name, OwnerId, LastModifiedDate FROM Account];
        Contact contactBefore = [SELECT Id, AccountId, LastModifiedDate FROM Contact];
        Id inviteeId = [SELECT Id FROM Event_Invitee__c LIMIT 1].Id;

        Test.startTest();
        System.runAs(dana) {
            InviteeApprovalController.getMyPendingByCompany(theEvent().Id);
            InviteeApprovalController.decide(theEvent().Id, new List<Id>{ inviteeId }, true, null);
        }
        Test.stopTest();

        Account after = [SELECT Id, Name, OwnerId, LastModifiedDate FROM Account];
        System.assertEquals(before.LastModifiedDate, after.LastModifiedDate, 'Account read, never written');
        System.assertEquals(before.OwnerId, after.OwnerId);
        Contact contactAfter = [SELECT Id, AccountId, LastModifiedDate FROM Contact];
        System.assertEquals(contactBefore.LastModifiedDate, contactAfter.LastModifiedDate);
        System.assertEquals(1, [SELECT COUNT() FROM Account]);
        System.assertEquals(1, [SELECT COUNT() FROM Contact]);
    }
}
