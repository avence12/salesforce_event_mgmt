/**
 * Corporate (on-prem) approval integration tests: external submit publishes
 * Approval_Request__e instead of notifying owners in Salesforce; the console goes
 * read-only; the REST callback applies decisions idempotently and fires the same
 * completion notification as the console path; re-adding a rejected invitee clears
 * the correlation ID; the reconciliation batch resends and then flags stale rows.
 */
@IsTest
private class ExternalApprovalIntegrationTest {

    private static User findUser(String alias) {
        return [SELECT Id, Name FROM User WHERE Alias = :alias AND IsActive = true LIMIT 1];
    }

    @TestSetup
    static void setup() {
        Profile std = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        List<User> users = new List<User>();
        for (String alias : new List<String>{ 'extam', 'extown' }) {
            users.add(new User(
                Alias = alias,
                Username = alias + '.' + System.currentTimeMillis() + '@evtmgmt.poc.test',
                Email = alias + '@evtmgmt.poc.test',
                LastName = alias,
                ProfileId = std.Id,
                EmailEncodingKey = 'UTF-8',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                TimeZoneSidKey = 'America/New_York',
                FederationIdentifier = alias + '-fedid'
            ));
        }
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert users; // runAs guards against mixed-DML with the setup below
        }

        Account acme = new Account(Name = 'Acme Corp', OwnerId = users[1].Id);
        insert acme;
        insert new List<Contact>{
            new Contact(FirstName = 'Emily', LastName = 'Carter', Email = 'emily@acme.test', Title = 'Senior Manager', AccountId = acme.Id),
            new Contact(FirstName = 'Robert', LastName = 'Kim', Email = 'robert@acme.test', Title = 'SVP', AccountId = acme.Id)
        };

        insert new Marketing_Event__c(
            Name = 'Q3 2026 Customer Appreciation Gala',
            Event_Date__c = Date.today().addDays(60),
            Location__c = 'The Plaza, New York',
            Event_Type__c = 'Dinner / Gala'
        );
    }

    /** Adds both contacts and submits as the AM with external approval enabled. */
    private static void submitExternally() {
        ApprovalIntegrationSettings.externalEnabledOverride = true;
        User am = findUser('extam');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        List<Id> contactIds = new List<Id>();
        for (Contact c : [SELECT Id FROM Contact ORDER BY LastName]) { contactIds.add(c.Id); }
        System.runAs(am) {
            InviteeSelectorController.addInvitees(evt.Id, contactIds);
            InviteeSelectorController.submitMyInvitees(evt.Id);
        }
    }

    private static Map<String, Object> post(String body) {
        RestRequest req = new RestRequest();
        req.requestUri = '/services/apexrest/event-approval/v1/decisions';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(body);
        RestContext.request = req;
        RestContext.response = new RestResponse();
        ExternalApprovalRestService.applyDecisions();
        String raw = RestContext.response.responseBody.toString();
        return (Map<String, Object>) JSON.deserializeUntyped(raw);
    }

    private static String decisionBody(String correlationId, Boolean approve) {
        return JSON.serialize(new Map<String, Object>{
            'decisions' => new List<Object>{
                new Map<String, Object>{
                    'correlationId' => correlationId,
                    'approve' => approve,
                    'approverId' => 'EMP-1234',
                    'comment' => approve ? 'Looks good' : 'Not this event'
                }
            }
        });
    }

    private static Map<String, String> statusByCorrelation(Map<String, Object> response) {
        Map<String, String> out = new Map<String, String>();
        for (Object o : (List<Object>) response.get('results')) {
            Map<String, Object> item = (Map<String, Object>) o;
            out.put((String) item.get('correlationId'), (String) item.get('status'));
        }
        return out;
    }

    @IsTest
    static void externalSubmitPublishesInsteadOfNotifying() {
        ApprovalRequestPublisher.publishedCount = 0;
        Test.startTest();
        submitExternally();
        Test.stopTest();

        System.assertEquals(2, ApprovalRequestPublisher.publishedCount,
            'One Approval_Request__e per submitted invitee');
        System.assertEquals(0, EventNotificationService.emailsSent,
            'The corporate system owns approver notification in external mode');
        for (Event_Invitee__c inv : [
            SELECT External_Approval_Id__c, Integration_Status__c, Status__c FROM Event_Invitee__c
        ]) {
            System.assertEquals('Pending Approval', inv.Status__c);
            System.assertEquals('Sent', inv.Integration_Status__c);
            System.assertNotEquals(null, inv.External_Approval_Id__c, 'Correlation ID assigned at submit');
        }
    }

    @IsTest
    static void consoleIsReadOnlyInExternalMode() {
        submitExternally();
        User owner = findUser('extown');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        Event_Invitee__c inv = [SELECT Id FROM Event_Invitee__c LIMIT 1];

        System.assertEquals(true, ApprovalConsoleController.isExternalApprovalEnabled());
        System.runAs(owner) {
            System.assertEquals(2, ApprovalConsoleController.getPendingForMe(evt.Id).size(),
                'Owner still sees pending rows — as read-only progress');
            Boolean threw = false;
            try { ApprovalConsoleController.decide(evt.Id, new List<Id>{ inv.Id }, true); }
            catch (AuraHandledException e) { threw = true; }
            System.assert(threw, 'Deciding in Salesforce must be blocked while external approval is on');
        }
    }

    @IsTest
    static void decisionCallbackAppliesAndNotifiesOnCompletion() {
        submitExternally();
        Event_Invitee__c emilyRow = [SELECT Id, External_Approval_Id__c FROM Event_Invitee__c
                                     WHERE Contact__r.LastName = 'Carter'];
        Event_Invitee__c robertRow = [SELECT Id, External_Approval_Id__c FROM Event_Invitee__c
                                      WHERE Contact__r.LastName = 'Kim'];

        Test.startTest();
        Map<String, Object> r1 = post(decisionBody(emilyRow.External_Approval_Id__c, true));
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('APPLIED', statusByCorrelation(r1).get(emilyRow.External_Approval_Id__c));
        System.assertEquals(0, EventNotificationService.emailsSent,
            'AM still has one pending row — no completion notification yet');

        Map<String, Object> r2 = post(decisionBody(robertRow.External_Approval_Id__c, false));
        System.assertEquals('APPLIED', statusByCorrelation(r2).get(robertRow.External_Approval_Id__c));
        Test.stopTest();

        System.assertEquals(1, EventNotificationService.emailsSent,
            'Batch fully reviewed → exactly one completion email to the AM');

        emilyRow = [SELECT Status__c, Decided_At__c, Integration_Status__c, External_Approver__c, Decision_Comment__c
                    FROM Event_Invitee__c WHERE Id = :emilyRow.Id];
        System.assertEquals('Approved', emilyRow.Status__c);
        System.assertNotEquals(null, emilyRow.Decided_At__c);
        System.assertEquals('Decided', emilyRow.Integration_Status__c);
        System.assertEquals('EMP-1234', emilyRow.External_Approver__c);
        System.assertEquals('Looks good', emilyRow.Decision_Comment__c);
        System.assertEquals('Rejected',
            [SELECT Status__c FROM Event_Invitee__c WHERE Id = :robertRow.Id].Status__c);
    }

    @IsTest
    static void decisionCallbackIsIdempotentAndDetectsConflict() {
        submitExternally();
        Event_Invitee__c emilyRow = [SELECT Id, External_Approval_Id__c FROM Event_Invitee__c
                                     WHERE Contact__r.LastName = 'Carter'];
        String cid = emilyRow.External_Approval_Id__c;

        post(decisionBody(cid, true));
        Integer emailsAfterFirst = EventNotificationService.emailsSent;

        // Blind middleware retry with the same payload: success, no state change, no re-notify.
        Map<String, Object> replay = post(decisionBody(cid, true));
        System.assertEquals('ALREADY_APPLIED', statusByCorrelation(replay).get(cid));
        System.assertEquals(emailsAfterFirst, EventNotificationService.emailsSent,
            'A replay must never trigger a second notification');

        // The opposite decision for an already-approved row is a real conflict.
        Map<String, Object> conflict = post(decisionBody(cid, false));
        System.assertEquals('CONFLICT', statusByCorrelation(conflict).get(cid));
        System.assertEquals('Approved',
            [SELECT Status__c FROM Event_Invitee__c WHERE Id = :emilyRow.Id].Status__c,
            'A conflicting callback must not overwrite the landed decision');
    }

    @IsTest
    static void acknowledgementsFlipSentToAcknowledged() {
        submitExternally();
        List<String> cids = new List<String>();
        for (Event_Invitee__c inv : [SELECT External_Approval_Id__c FROM Event_Invitee__c]) {
            cids.add(inv.External_Approval_Id__c);
        }

        Map<String, Object> res = post(JSON.serialize(new Map<String, Object>{ 'acknowledgements' => cids }));
        System.assertEquals(2, (Integer) res.get('acknowledged'));
        System.assertEquals(2, [SELECT COUNT() FROM Event_Invitee__c WHERE Integration_Status__c = 'Acknowledged']);

        Map<String, Object> again = post(JSON.serialize(new Map<String, Object>{ 'acknowledgements' => cids }));
        System.assertEquals(0, (Integer) again.get('acknowledged'), 'Ack replay is a no-op');
    }

    @IsTest
    static void badPayloadsAreRejectedAndUnknownIdIsNotFound() {
        submitExternally();

        post('this is not json');
        System.assertEquals(400, RestContext.response.statusCode, 'Unparseable body → 400');

        post('{}');
        System.assertEquals(400, RestContext.response.statusCode, 'Neither list present → 400');

        Map<String, Object> res = post(decisionBody('00000000-0000-0000-0000-000000000000', true));
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('NOT_FOUND', statusByCorrelation(res).get('00000000-0000-0000-0000-000000000000'));

        Map<String, Object> invalid = post(JSON.serialize(new Map<String, Object>{
            'decisions' => new List<Object>{ new Map<String, Object>{ 'approve' => true } }
        }));
        System.assertEquals('INVALID', ((Map<String, Object>) ((List<Object>) invalid.get('results'))[0]).get('status'));
    }

    @IsTest
    static void reAddAfterExternalRejectClearsIntegrationFields() {
        submitExternally();
        User am = findUser('extam');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        Event_Invitee__c emilyRow = [SELECT Id, External_Approval_Id__c, Contact__c FROM Event_Invitee__c
                                     WHERE Contact__r.LastName = 'Carter'];
        String staleCid = emilyRow.External_Approval_Id__c;

        post(decisionBody(staleCid, false)); // corporate system rejects Emily

        System.runAs(am) {
            System.assertEquals(1, InviteeSelectorController.addInvitees(evt.Id, new List<Id>{ emilyRow.Contact__c }),
                'Rejected row resets on re-add');
        }
        emilyRow = [SELECT Status__c, External_Approval_Id__c, Integration_Status__c,
                           External_Approver__c, Decision_Comment__c
                    FROM Event_Invitee__c WHERE Id = :emilyRow.Id];
        System.assertEquals('Draft', emilyRow.Status__c);
        System.assertEquals(null, emilyRow.External_Approval_Id__c);
        System.assertEquals(null, emilyRow.Integration_Status__c);
        System.assertEquals(null, emilyRow.External_Approver__c);
        System.assertEquals(null, emilyRow.Decision_Comment__c);

        // A late callback for the stale corporate ticket must not decide the reset row.
        Map<String, Object> late = post(decisionBody(staleCid, true));
        System.assertEquals('NOT_FOUND', statusByCorrelation(late).get(staleCid));
        System.assertEquals('Draft',
            [SELECT Status__c FROM Event_Invitee__c WHERE Id = :emilyRow.Id].Status__c);
    }

    @IsTest
    static void reconciliationResendsStaleAndFlagsDead() {
        submitExternally();
        Event_Invitee__c emilyRow = [SELECT Id FROM Event_Invitee__c WHERE Contact__r.LastName = 'Carter'];
        Event_Invitee__c robertRow = [SELECT Id FROM Event_Invitee__c WHERE Contact__r.LastName = 'Kim'];

        // Defaults: resend after 24h, fail after 72h — 30h → resend, 100h → flag.
        update new List<Event_Invitee__c>{
            new Event_Invitee__c(Id = emilyRow.Id, Submitted_At__c = Datetime.now().addHours(-30)),
            new Event_Invitee__c(Id = robertRow.Id, Submitted_At__c = Datetime.now().addHours(-100))
        };

        ApprovalRequestPublisher.publishedCount = 0;
        Test.startTest();
        Database.executeBatch(new ApprovalSyncReconciliationBatch(), 200);
        Test.stopTest();

        System.assertEquals(1, ApprovalRequestPublisher.publishedCount,
            'Only the 30h-old row is re-driven as RESEND');
        System.assertEquals('Sent',
            [SELECT Integration_Status__c FROM Event_Invitee__c WHERE Id = :emilyRow.Id].Integration_Status__c,
            'Resent row keeps waiting for the middleware');
        System.assertEquals('Sync Failed',
            [SELECT Integration_Status__c FROM Event_Invitee__c WHERE Id = :robertRow.Id].Integration_Status__c,
            'The 100h-old row is flagged for manual follow-up');

        // A late decision on a Sync Failed row still lands — business status is still Pending.
        String cid = [SELECT External_Approval_Id__c FROM Event_Invitee__c WHERE Id = :robertRow.Id].External_Approval_Id__c;
        Map<String, Object> res = post(decisionBody(cid, true));
        System.assertEquals('APPLIED', statusByCorrelation(res).get(cid));
    }
}
