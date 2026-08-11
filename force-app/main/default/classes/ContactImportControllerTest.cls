/**
 * R4: the import is an attendance log, not a reconciliation tool.
 *
 * The two tests that matter most are the negative ones — no Contact is created,
 * updated or deleted, and no Account is created. Those two assertions ARE the
 * requirement; everything else here is detail about how matching reaches a person.
 */
@IsTest
private class ContactImportControllerTest {
    @TestSetup
    static void setup() {
        Account acme = new Account(Name = 'Acme Corp');
        Account nordbank = new Account(Name = 'Nordbank AG');
        insert new List<Account>{ acme, nordbank };
        insert new List<Contact>{
            new Contact(
                FirstName = 'Emily',
                LastName = 'Carter',
                Email = 'emily.carter@acmecorp.com',
                Title = 'Manager',
                AccountId = acme.Id
            ),
            new Contact(
                FirstName = 'James',
                LastName = 'Mueller',
                Email = 'j.mueller@nordbank.de',
                Title = 'Director',
                AccountId = nordbank.Id
            )
        };
    }

    private static ContactImportController.ImportRow row(
        String first,
        String last,
        String email,
        String company,
        String event
    ) {
        ContactImportController.ImportRow r = new ContactImportController.ImportRow();
        r.firstName = first;
        r.lastName = last;
        r.email = email;
        r.company = company;
        r.event = event;
        return r;
    }

    private static List<ContactImportController.ImportRow> one(ContactImportController.ImportRow r) {
        return new List<ContactImportController.ImportRow>{ r };
    }

    // ================= the requirement =================

    /**
     * The whole point of R4. If this fails, nothing else about the feature matters.
     */
    @IsTest
    static void importNeverTouchesContactsOrAccounts() {
        List<Contact> before = [SELECT Id, LastModifiedDate, Title, Email, AccountId FROM Contact ORDER BY LastName];
        Integer accountsBefore = [SELECT COUNT() FROM Account];

        Test.startTest();
        ContactImportController.applyChanges(
            new List<ContactImportController.ImportRow>{
                // matches Emily — and tries to change her title and company on the way past
                row('Emily', 'Carter', 'emily.carter@acmecorp.com', 'Globex', 'FinTech Summit 2026'),
                // matches nobody at a customer
                row('Anke', 'Weber', 'a.weber@tuberlin.test', 'TU Berlin', 'FinTech Summit 2026')
            },
            'attendees.csv'
        );
        Test.stopTest();

        List<Contact> after = [SELECT Id, LastModifiedDate, Title, Email, AccountId FROM Contact ORDER BY LastName];
        System.assertEquals(before.size(), after.size(), 'No Contact may be created or deleted');
        for (Integer i = 0; i < before.size(); i++) {
            System.assertEquals(before[i].Id, after[i].Id);
            System.assertEquals(
                before[i].LastModifiedDate,
                after[i].LastModifiedDate,
                'No Contact may be modified — not even a field the CSV disagrees with'
            );
            System.assertEquals(before[i].Title, after[i].Title);
            System.assertEquals(before[i].AccountId, after[i].AccountId, 'Never reparented');
        }
        System.assertEquals(accountsBefore, [SELECT COUNT() FROM Account], 'No Account may be created');
    }

    @IsTest
    static void appliesTagsAndCreatesLeadsOnly() {
        Test.startTest();
        ContactImportController.ApplyResult res = ContactImportController.applyChanges(
            new List<ContactImportController.ImportRow>{
                row('Emily', 'Carter', 'emily.carter@acmecorp.com', 'Acme Corp', 'FinTech Summit 2026'),
                row('Anke', 'Weber', 'a.weber@tuberlin.test', 'TU Berlin', 'FinTech Summit 2026'),
                row('No', '', 'noname@x.test', 'Nowhere', 'FinTech Summit 2026')
            },
            'attendees.csv'
        );
        Test.stopTest();

        System.assertEquals(2, res.tagsRecorded, 'Both the matched contact and the new lead are tagged');
        System.assertEquals(1, res.leadsCreated);

        Event_History__c contactTag = [
            SELECT Event_Name__c, Match_Basis__c, Source_File__c, Attendee_Type__c, Attendee_Org__c, Lead__c
            FROM Event_History__c
            WHERE Contact__c != NULL
        ];
        System.assertEquals('FinTech Summit 2026', contactTag.Event_Name__c);
        System.assertEquals('Name', contactTag.Match_Basis__c, 'Unique on name alone — no narrowing needed');
        System.assertEquals('attendees.csv', contactTag.Source_File__c);
        System.assertEquals('Contact', contactTag.Attendee_Type__c);
        System.assertEquals('Acme Corp', contactTag.Attendee_Org__c);
        System.assertEquals(null, contactTag.Lead__c, 'Exactly one parent');

        Event_History__c leadTag = [
            SELECT Match_Basis__c, Attendee_Type__c, Attendee_Org__c
            FROM Event_History__c
            WHERE Lead__c != NULL
        ];
        System.assertEquals(
            'Created by import',
            leadTag.Match_Basis__c,
            'A lead the import created had no matching to do — creating someone without recording why loses the only reason they exist'
        );
        System.assertEquals('Lead', leadTag.Attendee_Type__c);
        System.assertEquals('TU Berlin', leadTag.Attendee_Org__c);
    }

    /** Re-running the same file is a no-op: the fact is "was on the list", not "was imported N times". */
    @IsTest
    static void reRunningTheSameFileChangesNothing() {
        List<ContactImportController.ImportRow> rows = new List<ContactImportController.ImportRow>{
            row('Emily', 'Carter', 'emily.carter@acmecorp.com', 'Acme Corp', 'FinTech Summit 2026'),
            row('Anke', 'Weber', 'a.weber@tuberlin.test', 'TU Berlin', 'FinTech Summit 2026')
        };

        Test.startTest();
        ContactImportController.applyChanges(rows, 'attendees.csv');
        ContactImportController.applyChanges(rows, 'attendees.csv');
        Test.stopTest();

        System.assertEquals(2, [SELECT COUNT() FROM Event_History__c], 'Upsert on Unique_Key__c, not insert');
        System.assertEquals(
            1,
            [SELECT COUNT() FROM Lead],
            'The second run must match the lead it created, not clone it'
        );
        System.assertEquals(
            'Name',
            [SELECT Match_Basis__c FROM Event_History__c WHERE Lead__c != NULL].Match_Basis__c,
            'On the second run the lead already exists, so it is matched rather than created'
        );
    }

    /** The same person twice in one file, same event: one row. */
    @IsTest
    static void duplicateRowsInOneFileCollapse() {
        Test.startTest();
        ContactImportController.ApplyResult res = ContactImportController.applyChanges(
            new List<ContactImportController.ImportRow>{
                row('Emily', 'Carter', 'emily.carter@acmecorp.com', 'Acme Corp', 'FinTech Summit 2026'),
                row('Emily', 'Carter', 'emily.carter@acmecorp.com', 'Acme Corp', 'fintech summit 2026')
            },
            'attendees.csv'
        );
        Test.stopTest();
        System.assertEquals(1, res.tagsRecorded, 'The event key is normalised, so casing is not a second event');
        System.assertEquals(1, [SELECT COUNT() FROM Event_History__c]);
    }

    /** Two events for one person are two facts, not a duplicate. */
    @IsTest
    static void oneAttendeeAccumulatesSeveralEvents() {
        Test.startTest();
        ContactImportController.applyChanges(
            new List<ContactImportController.ImportRow>{
                row('Emily', 'Carter', 'emily.carter@acmecorp.com', 'Acme Corp', 'FinTech Summit 2026'),
                row('Emily', 'Carter', 'emily.carter@acmecorp.com', 'Acme Corp', 'DevCon Berlin 2025')
            },
            'attendees.csv'
        );
        Test.stopTest();
        System.assertEquals(2, [SELECT COUNT() FROM Event_History__c]);
    }

    // ================= the cascade, one rung at a time =================

    @IsTest
    static void rungOne_uniqueOnNameAlone() {
        List<ContactImportController.PreviewResult> res = ContactImportController.previewMatches(
            one(row('Emily', 'Carter', null, null, 'Summit'))
        );
        System.assertEquals(ContactImportController.MATCHED_CONTACT, res[0].classification);
        System.assertEquals('Name', res[0].matchBasis);
    }

    @IsTest
    static void rungTwo_companySeparatesTwoOfTheSameName() {
        Account globex = new Account(Name = 'Globex');
        insert globex;
        insert new Contact(
            FirstName = 'Emily',
            LastName = 'Carter',
            Email = 'e.carter@globex.com',
            AccountId = globex.Id
        );

        List<ContactImportController.PreviewResult> res = ContactImportController.previewMatches(
            one(row('Emily', 'Carter', null, 'Globex', 'Summit'))
        );
        System.assertEquals(ContactImportController.MATCHED_CONTACT, res[0].classification);
        System.assertEquals('Name + Company', res[0].matchBasis);
        System.assertEquals(
            [SELECT Id FROM Contact WHERE Email = 'e.carter@globex.com'].Id,
            res[0].contactId,
            'The company must pick the Globex one, not the Acme one'
        );
    }

    @IsTest
    static void rungThree_emailSeparatesTwoAtTheSameCompany() {
        Account acme = [SELECT Id FROM Account WHERE Name = 'Acme Corp'];
        insert new Contact(
            FirstName = 'Emily',
            LastName = 'Carter',
            Email = 'e.carter2@acmecorp.com',
            AccountId = acme.Id
        );

        List<ContactImportController.PreviewResult> res = ContactImportController.previewMatches(
            one(row('Emily', 'Carter', 'e.carter2@acmecorp.com', 'Acme Corp', 'Summit'))
        );
        System.assertEquals(ContactImportController.MATCHED_CONTACT, res[0].classification);
        System.assertEquals('Name + Company + Email', res[0].matchBasis);
        System.assertEquals([SELECT Id FROM Contact WHERE Email = 'e.carter2@acmecorp.com'].Id, res[0].contactId);
    }

    /**
     * Open Question 10, settled as "skip". Two Emily Carters exist, neither at the
     * company the file claims — she changed jobs. The stale company must not erase her,
     * and email still separates the two.
     */
    @IsTest
    static void emptyNarrowingStepIsSkippedNotFatal() {
        Account acme = [SELECT Id FROM Account WHERE Name = 'Acme Corp'];
        insert new Contact(
            FirstName = 'Emily',
            LastName = 'Carter',
            Email = 'e.carter2@acmecorp.com',
            AccountId = acme.Id
        );

        List<ContactImportController.PreviewResult> res = ContactImportController.previewMatches(
            one(row('Emily', 'Carter', 'e.carter2@acmecorp.com', 'Somewhere She No Longer Works', 'Summit'))
        );
        System.assertEquals(
            ContactImportController.MATCHED_CONTACT,
            res[0].classification,
            'A company that matches nobody is a wrong criterion, not a missing person'
        );
        System.assertEquals('Name + Company + Email', res[0].matchBasis);
    }

    /** A single row whose company matches nothing still matches on name alone. */
    @IsTest
    static void staleCompanyOnAUniqueNameStillMatches() {
        List<ContactImportController.PreviewResult> res = ContactImportController.previewMatches(
            one(row('James', 'Mueller', null, 'A Company He Left', 'Summit'))
        );
        System.assertEquals(ContactImportController.MATCHED_CONTACT, res[0].classification);
        System.assertEquals('Name', res[0].matchBasis);
    }

    /** Nothing separates them, so nothing is written and both candidates are named. */
    @IsTest
    static void unseparableNamesAreAmbiguousAndWriteNothing() {
        Account acme = [SELECT Id FROM Account WHERE Name = 'Acme Corp'];
        insert new Contact(
            FirstName = 'Emily',
            LastName = 'Carter',
            Email = 'e.carter2@acmecorp.com',
            AccountId = acme.Id
        );

        Test.startTest();
        List<ContactImportController.PreviewResult> preview = ContactImportController.previewMatches(
            one(row('Emily', 'Carter', null, 'Acme Corp', 'Summit'))
        );
        ContactImportController.ApplyResult res = ContactImportController.applyChanges(
            one(row('Emily', 'Carter', null, 'Acme Corp', 'Summit')),
            'attendees.csv'
        );
        Test.stopTest();

        System.assertEquals(ContactImportController.AMBIGUOUS, preview[0].classification);
        System.assertEquals(
            2,
            preview[0].candidates.size(),
            'The manual-review list needs to name who it could not choose between'
        );
        System.assert(preview[0].candidates[0].contains('Emily Carter'));
        System.assertEquals(0, res.tagsRecorded, 'An ambiguous row writes nothing');
        System.assertEquals(0, [SELECT COUNT() FROM Event_History__c]);
        System.assertEquals(0, [SELECT COUNT() FROM Lead], 'And it certainly does not become a new lead');
    }

    // ================= the lead pass =================

    @IsTest
    static void existingLeadIsMatchedAndTagged() {
        insert new Lead(
            FirstName = 'Hélène',
            LastName = 'Dubois',
            Company = 'Université de Genève',
            Email = 'h.dubois@unige.test',
            Title = 'Professor'
        );

        Test.startTest();
        ContactImportController.ApplyResult res = ContactImportController.applyChanges(
            one(row('Hélène', 'Dubois', 'h.dubois@unige.test', 'Université de Genève', 'DevCon 2026')),
            'attendees.csv'
        );
        Test.stopTest();

        System.assertEquals(1, res.tagsRecorded);
        System.assertEquals(0, res.leadsCreated, 'She already exists — matched, not duplicated');
        System.assertEquals(1, [SELECT COUNT() FROM Lead]);
        Event_History__c tag = [SELECT Attendee_Name__c, Attendee_Type__c, Match_Basis__c FROM Event_History__c];
        System.assertEquals('Lead', tag.Attendee_Type__c);
        System.assertEquals('Hélène Dubois', tag.Attendee_Name__c, 'Non-ASCII names survive intact');
        System.assertEquals('Name', tag.Match_Basis__c);
    }

    /** A converted lead is invisible to the lead pass — its Contact matched first. */
    @IsTest
    static void contactBeatsLeadForTheSamePerson() {
        insert new Lead(
            FirstName = 'Emily',
            LastName = 'Carter',
            Company = 'Acme Corp',
            Email = 'emily.carter@acmecorp.com'
        );

        List<ContactImportController.PreviewResult> res = ContactImportController.previewMatches(
            one(row('Emily', 'Carter', 'emily.carter@acmecorp.com', 'Acme Corp', 'Summit'))
        );
        System.assertEquals(ContactImportController.MATCHED_CONTACT, res[0].classification);
        System.assertNotEquals(null, res[0].contactId);
        System.assertEquals(null, res[0].leadId, 'A customer Contact outranks a Lead for the same person');
    }

    @IsTest
    static void unaffiliatedRowBecomesALeadWithAPlaceholderCompany() {
        Test.startTest();
        ContactImportController.applyChanges(
            one(row('Independent', 'Consultant', 'indie@nowhere.test', null, 'DevCon 2026')),
            'attendees.csv'
        );
        Test.stopTest();
        System.assertEquals(
            'Unaffiliated',
            [SELECT Company FROM Lead].Company,
            'Lead.Company is required, so a blank company needs a placeholder rather than a failed insert'
        );
        System.assertEquals(ContactImportController.LEAD_SOURCE, [SELECT LeadSource FROM Lead].LeadSource);
    }

    // ================= refusals =================

    @IsTest
    static void rowsWithoutANameOrAnEventAreSkipped() {
        List<ContactImportController.PreviewResult> res = ContactImportController.previewMatches(
            new List<ContactImportController.ImportRow>{
                row('Nameless', '', 'x@y.test', 'Acme Corp', 'Summit'),
                row('Emily', 'Carter', 'emily.carter@acmecorp.com', 'Acme Corp', null)
            }
        );
        System.assertEquals(ContactImportController.SKIPPED, res[0].classification);
        System.assert(res[0].reason.contains('last name'));
        System.assertEquals(ContactImportController.SKIPPED, res[1].classification);
        System.assert(
            res[1].reason.contains('event'),
            'A row with nothing to tag is not a match failure: ' + res[1].reason
        );
    }

    @IsTest
    static void rejectsOversizedAndEmptyInput() {
        List<ContactImportController.ImportRow> tooMany = new List<ContactImportController.ImportRow>();
        for (Integer i = 0; i <= ContactImportController.MAX_ROWS; i++) {
            tooMany.add(row('A', 'B' + i, 'a' + i + '@x.com', null, 'Summit'));
        }
        Boolean threwOversize = false;
        try {
            ContactImportController.previewMatches(tooMany);
        } catch (AuraHandledException e) {
            threwOversize = true;
        }
        System.assert(threwOversize, 'Should reject > MAX_ROWS');

        Boolean threwEmpty = false;
        try {
            ContactImportController.applyChanges(new List<ContactImportController.ImportRow>(), 'x.csv');
        } catch (AuraHandledException e) {
            threwEmpty = true;
        }
        System.assert(threwEmpty, 'Should reject empty input');
    }

    /** Both lookups blank, or both set, must be refused at the database. */
    @IsTest
    static void eventHistoryNeedsExactlyOneParent() {
        Contact emily = [SELECT Id FROM Contact WHERE Email = 'emily.carter@acmecorp.com'];
        Lead l = new Lead(LastName = 'Nobody', Company = 'Nowhere University');
        insert l;

        Boolean neitherThrew = false;
        try {
            insert new Event_History__c(Event_Name__c = 'Summit', Unique_Key__c = 'k-neither');
        } catch (DmlException e) {
            neitherThrew = true;
        }
        System.assert(neitherThrew, 'A tag against nobody must be refused');

        Boolean bothThrew = false;
        try {
            insert new Event_History__c(
                Contact__c = emily.Id,
                Lead__c = l.Id,
                Event_Name__c = 'Summit',
                Unique_Key__c = 'k-both'
            );
        } catch (DmlException e) {
            bothThrew = true;
        }
        System.assert(bothThrew, 'Two identities on one row would silently prefer the Contact');
    }
}
