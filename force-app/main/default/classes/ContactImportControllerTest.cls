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
        String title,
        String company,
        String mobile
    ) {
        ContactImportController.ImportRow r = new ContactImportController.ImportRow();
        r.firstName = first;
        r.lastName = last;
        r.email = email;
        r.title = title;
        r.company = company;
        r.mobile = mobile;
        return r;
    }

    @IsTest
    static void classifiesEveryCategory() {
        insert new Lead(
            FirstName = 'Hélène',
            LastName = 'Dubois',
            Company = 'Université de Genève',
            Email = 'h.dubois@unige.test',
            Title = 'Lecturer'
        );

        List<ContactImportController.ImportRow> rows = new List<ContactImportController.ImportRow>{
            // UPDATE: title changed
            row('Emily', 'Carter', 'emily.carter@acmecorp.com', 'Senior Manager', 'Acme Corp', null),
            // UNCHANGED: same title, no mobile
            row('James', 'Mueller', 'j.mueller@nordbank.de', 'Director', 'Nordbank AG', null),
            // NEW_CONTACT: unknown email, but the company is an existing Account
            row('David', 'Nguyen', 'd.nguyen@newco.io', 'CTO', 'Acme Corp', null),
            // COMPANY_CHANGE: known email, different company (also has title change — company wins)
            row('James', 'Mueller', 'j.mueller@nordbank.de', 'VP', 'Globex', null),
            // SKIPPED: bad email
            row('No', 'Email', 'not-an-email', null, null, null),
            // SKIPPED: new contact without last name
            row('OnlyFirst', '', 'onlyfirst@somewhere.com', null, null, null),
            // NEW_LEAD: unknown email and the company is not a customer Account
            row('Anke', 'Weber', 'a.weber@tuberlin.test', 'Professor', 'TU Berlin', null),
            // UPDATE_LEAD: matches an existing unconverted Lead by email
            row('Hélène', 'Dubois', 'h.dubois@unige.test', 'Professor', 'Université de Genève', null)
        };

        Test.startTest();
        List<ContactImportController.PreviewResult> results = ContactImportController.previewMatches(rows);
        Test.stopTest();

        System.assertEquals('UPDATE', results[0].classification);
        System.assertEquals(1, results[0].changes.size(), 'Title change expected');
        System.assertEquals('UNCHANGED', results[1].classification);
        System.assertEquals('NEW_CONTACT', results[2].classification, 'Company is a customer Account → Contact');
        System.assertEquals(
            'COMPANY_CHANGE',
            results[3].classification,
            'Company change must take precedence over the title update'
        );
        System.assertEquals('SKIPPED', results[4].classification);
        System.assertEquals('SKIPPED', results[5].classification);
        System.assertEquals(
            'NEW_LEAD',
            results[6].classification,
            'An unmatched company is the evidence this person is not at a customer'
        );
        System.assert(
            results[6].reason.contains('TU Berlin'),
            'The preview must name the company it could not match: ' + results[6].reason
        );
        System.assertEquals('UPDATE_LEAD', results[7].classification);
        System.assertEquals(1, results[7].changes.size(), 'Lecturer → Professor');
    }

    @IsTest
    static void appliesCreatesAndUpdatesOnly() {
        Integer accountsBefore = [SELECT COUNT() FROM Account];

        List<ContactImportController.ImportRow> rows = new List<ContactImportController.ImportRow>{
            row('Emily', 'Carter', 'emily.carter@acmecorp.com', 'Senior Manager', 'Acme Corp', '+1 555 0100'),
            row('David', 'Nguyen', 'd.nguyen@newco.io', 'CTO', 'Acme Corp', null), // existing account
            row('Sophie', 'Laurent', 'sophie@somewhere.eu', 'CFO', 'Unknown GmbH', null), // → Lead
            row('James', 'Mueller', 'j.mueller@nordbank.de', 'VP', 'Globex', null), // company change — not applied
            row('Bad', 'Row', 'no-at-sign', null, null, null) // skipped
        };

        Test.startTest();
        ContactImportController.ApplyResult res = ContactImportController.applyChanges(rows);
        Test.stopTest();

        System.assertEquals(1, res.created, 'Only the row whose company is a customer Account becomes a Contact');
        System.assertEquals(1, res.updated);
        System.assertEquals(1, res.leadsCreated);
        System.assertEquals(0, res.leadsUpdated);

        Contact emily = [SELECT Title, MobilePhone FROM Contact WHERE Email = 'emily.carter@acmecorp.com'];
        System.assertEquals('Senior Manager', emily.Title);
        System.assertEquals('+1 555 0100', emily.MobilePhone);

        Contact james = [SELECT Title, Account.Name FROM Contact WHERE Email = 'j.mueller@nordbank.de'];
        System.assertEquals('Director', james.Title, 'Company-change row must not be applied');
        System.assertEquals('Nordbank AG', james.Account.Name, 'Contact must not be reparented');

        Contact david = [SELECT Account.Name FROM Contact WHERE Email = 'd.nguyen@newco.io'];
        System.assertEquals('Acme Corp', david.Account.Name, 'Exact company match should link the existing account');

        Lead sophie = [SELECT Company, LeadSource, Title FROM Lead WHERE Email = 'sophie@somewhere.eu'];
        System.assertEquals('Unknown GmbH', sophie.Company, 'The company name lives on the Lead as free text');
        System.assertEquals(ContactImportController.LEAD_SOURCE, sophie.LeadSource);
        System.assertEquals('CFO', sophie.Title);

        // The point of the whole revision: an import can never widen what Account means.
        System.assertEquals(
            accountsBefore,
            [SELECT COUNT() FROM Account],
            'No Account may be created by an import — "Unknown GmbH" is not a customer'
        );
    }

    /** A row with no company at all still becomes a Lead — Lead.Company is required. */
    @IsTest
    static void unaffiliatedRowBecomesALeadWithAPlaceholderCompany() {
        Test.startTest();
        ContactImportController.ApplyResult res = ContactImportController.applyChanges(
            new List<ContactImportController.ImportRow>{
                row('Independent', 'Consultant', 'indie@nowhere.test', 'Advisor', null, null)
            }
        );
        Test.stopTest();

        System.assertEquals(1, res.leadsCreated);
        System.assertEquals(0, res.created);
        System.assertEquals(
            'Unaffiliated',
            [SELECT Company FROM Lead WHERE Email = 'indie@nowhere.test'].Company,
            'Lead.Company is required, so a blank company needs a placeholder rather than a failed insert'
        );
    }

    /** An existing Lead is updated in place, not duplicated. */
    @IsTest
    static void existingLeadIsUpdatedNotDuplicated() {
        insert new Lead(
            FirstName = 'Anke',
            LastName = 'Weber',
            Company = 'TU Berlin',
            Email = 'a.weber@tuberlin.test',
            Title = 'Lecturer'
        );

        Test.startTest();
        ContactImportController.ApplyResult res = ContactImportController.applyChanges(
            new List<ContactImportController.ImportRow>{
                row('Anke', 'Weber', 'a.weber@tuberlin.test', 'Professor', 'TU Berlin', '+49 30 000')
            }
        );
        Test.stopTest();

        System.assertEquals(0, res.leadsCreated);
        System.assertEquals(1, res.leadsUpdated);
        System.assertEquals(1, [SELECT COUNT() FROM Lead WHERE Email = 'a.weber@tuberlin.test']);
        Lead anke = [SELECT Title, MobilePhone FROM Lead WHERE Email = 'a.weber@tuberlin.test'];
        System.assertEquals('Professor', anke.Title);
        System.assertEquals('+49 30 000', anke.MobilePhone);
    }

    @IsTest
    static void rejectsOversizedAndEmptyInput() {
        List<ContactImportController.ImportRow> tooMany = new List<ContactImportController.ImportRow>();
        for (Integer i = 0; i <= ContactImportController.MAX_ROWS; i++) {
            tooMany.add(row('A', 'B', 'a' + i + '@x.com', null, null, null));
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
            ContactImportController.applyChanges(new List<ContactImportController.ImportRow>());
        } catch (AuraHandledException e) {
            threwEmpty = true;
        }
        System.assert(threwEmpty, 'Should reject empty input');
    }
}
