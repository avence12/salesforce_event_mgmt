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
    static void classifiesAllFiveCategories() {
        List<ContactImportController.ImportRow> rows = new List<ContactImportController.ImportRow>{
            // UPDATE: title changed
            row('Emily', 'Carter', 'emily.carter@acmecorp.com', 'Senior Manager', 'Acme Corp', null),
            // UNCHANGED: same title, no mobile
            row('James', 'Mueller', 'j.mueller@nordbank.de', 'Director', 'Nordbank AG', null),
            // NEW_CONTACT: unknown email
            row('David', 'Nguyen', 'd.nguyen@newco.io', 'CTO', 'NewCo', null),
            // COMPANY_CHANGE: known email, different company (also has title change — company wins)
            row('Emily', 'Carter', 'EMILY.CARTER@ACMECORP.COM'.toLowerCase(), null, 'Globex', null),
            // SKIPPED: bad email
            row('No', 'Email', 'not-an-email', null, null, null),
            // SKIPPED: new contact without last name
            row('OnlyFirst', '', 'onlyfirst@somewhere.com', null, null, null)
        };
        // Make the 4th row a genuine company change on the second contact instead
        rows[3] = row('James', 'Mueller', 'j.mueller@nordbank.de', 'VP', 'Globex', null);

        Test.startTest();
        List<ContactImportController.PreviewResult> results = ContactImportController.previewMatches(rows);
        Test.stopTest();

        System.assertEquals('UPDATE', results[0].classification);
        System.assertEquals(1, results[0].changes.size(), 'Title change expected');
        System.assertEquals('UNCHANGED', results[1].classification);
        System.assertEquals('NEW_CONTACT', results[2].classification);
        System.assertEquals(
            'COMPANY_CHANGE',
            results[3].classification,
            'Company change must take precedence over the title update'
        );
        System.assertEquals('SKIPPED', results[4].classification);
        System.assertEquals('SKIPPED', results[5].classification);
    }

    @IsTest
    static void appliesCreatesAndUpdatesOnly() {
        List<ContactImportController.ImportRow> rows = new List<ContactImportController.ImportRow>{
            row('Emily', 'Carter', 'emily.carter@acmecorp.com', 'Senior Manager', 'Acme Corp', '+1 555 0100'),
            row('David', 'Nguyen', 'd.nguyen@newco.io', 'CTO', 'Acme Corp', null), // existing account
            row('Sophie', 'Laurent', 'sophie@somewhere.eu', 'CFO', 'Unknown GmbH', null), // bucket account
            row('James', 'Mueller', 'j.mueller@nordbank.de', 'VP', 'Globex', null), // company change — not applied
            row('Bad', 'Row', 'no-at-sign', null, null, null) // skipped
        };

        Test.startTest();
        ContactImportController.ApplyResult res = ContactImportController.applyChanges(rows);
        Test.stopTest();

        System.assertEquals(2, res.created);
        System.assertEquals(1, res.updated);

        Contact emily = [SELECT Title, MobilePhone FROM Contact WHERE Email = 'emily.carter@acmecorp.com'];
        System.assertEquals('Senior Manager', emily.Title);
        System.assertEquals('+1 555 0100', emily.MobilePhone);

        Contact james = [SELECT Title, Account.Name FROM Contact WHERE Email = 'j.mueller@nordbank.de'];
        System.assertEquals('Director', james.Title, 'Company-change row must not be applied');
        System.assertEquals('Nordbank AG', james.Account.Name, 'Contact must not be reparented');

        Contact david = [SELECT Account.Name FROM Contact WHERE Email = 'd.nguyen@newco.io'];
        System.assertEquals('Acme Corp', david.Account.Name, 'Exact company match should link the existing account');

        Contact sophie = [SELECT Account.Name FROM Contact WHERE Email = 'sophie@somewhere.eu'];
        System.assertEquals(
            ContactImportController.BUCKET_ACCOUNT_NAME,
            sophie.Account.Name,
            'Unmatched company should fall into the bucket account'
        );
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
