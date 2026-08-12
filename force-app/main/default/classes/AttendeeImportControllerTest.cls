/**
 * R5: the import writes attendees and nothing else.
 *
 * The tests that matter most are the negative ones — no Contact, no Lead and no
 * Account is created, updated or deleted, even when the file names people who
 * exist as all three. Those assertions ARE the requirement; the rest of this
 * class is detail about how de-duplication reaches one attendee per person.
 */
@IsTest
private class AttendeeImportControllerTest {
    @TestSetup
    static void setup() {
        // Deliberately populated: the file below names these same people, and the
        // import must walk straight past them. An empty org would prove nothing.
        Account acme = new Account(Name = 'Acme Corp');
        insert acme;
        insert new Contact(
            FirstName = 'Emily',
            LastName = 'Carter',
            Email = 'emily.carter@acmecorp.example',
            Title = 'Manager',
            AccountId = acme.Id
        );
        insert new Lead(
            FirstName = 'Hélène',
            LastName = 'Dubois',
            Company = 'Université de Genève',
            Email = 'h.dubois@unige.example',
            Title = 'Professor'
        );
    }

    private static AttendeeImportController.ImportRow row(String first, String last, String email, String company) {
        AttendeeImportController.ImportRow r = new AttendeeImportController.ImportRow();
        r.firstName = first;
        r.lastName = last;
        r.email = email;
        r.company = company;
        return r;
    }

    private static List<AttendeeImportController.ImportRow> one(AttendeeImportController.ImportRow r) {
        return new List<AttendeeImportController.ImportRow>{ r };
    }

    // ================= the requirement =================

    /**
     * The whole point of R5. If this fails, nothing else about the feature matters.
     * The file names an existing Contact and an existing Lead, with contradictory
     * title and company values, and neither record may move a millimetre.
     */
    @IsTest
    static void importNeverTouchesContactsLeadsOrAccounts() {
        List<Contact> contactsBefore = [SELECT Id, LastModifiedDate, Title, AccountId FROM Contact ORDER BY Id];
        List<Lead> leadsBefore = [SELECT Id, LastModifiedDate, Title, Company FROM Lead ORDER BY Id];
        Integer accountsBefore = [SELECT COUNT() FROM Account];

        Test.startTest();
        AttendeeImportController.applyChanges(
            new List<AttendeeImportController.ImportRow>{
                row('Emily', 'Carter', 'emily.carter@acmecorp.example', 'Globex'),
                row('Hélène', 'Dubois', 'h.dubois@unige.example', 'ETH Zürich'),
                row('Someone', 'Entirely New', 'new@nowhere.example', 'NewCo Labs')
            },
            'attendees.csv'
        );
        Test.stopTest();

        List<Contact> contactsAfter = [SELECT Id, LastModifiedDate, Title, AccountId FROM Contact ORDER BY Id];
        System.assertEquals(contactsBefore.size(), contactsAfter.size(), 'No Contact may be created or deleted');
        for (Integer i = 0; i < contactsBefore.size(); i++) {
            System.assertEquals(
                contactsBefore[i].LastModifiedDate,
                contactsAfter[i].LastModifiedDate,
                'No Contact may be modified — not even a field the CSV disagrees with'
            );
            System.assertEquals(contactsBefore[i].AccountId, contactsAfter[i].AccountId, 'Never reparented');
        }

        List<Lead> leadsAfter = [SELECT Id, LastModifiedDate, Title, Company FROM Lead ORDER BY Id];
        System.assertEquals(
            leadsBefore.size(),
            leadsAfter.size(),
            'R5 stopped creating Leads: an unmatched person is an attendee, not a lead'
        );
        for (Integer i = 0; i < leadsBefore.size(); i++) {
            System.assertEquals(leadsBefore[i].LastModifiedDate, leadsAfter[i].LastModifiedDate);
            System.assertEquals(leadsBefore[i].Company, leadsAfter[i].Company);
        }

        System.assertEquals(accountsBefore, [SELECT COUNT() FROM Account], 'No Account may be created');
    }

    /**
     * A person who is already a customer Contact is still imported as an attendee.
     * This is not an oversight to be fixed later — it is the shape R5 chose, and a
     * test that asserts it stops someone quietly reintroducing Contact matching.
     */
    @IsTest
    static void anExistingContactIsImportedAsAnAttendeeAnyway() {
        Test.startTest();
        AttendeeImportController.ApplyResult res = AttendeeImportController.applyChanges(
            one(row('Emily', 'Carter', 'emily.carter@acmecorp.example', 'Acme Corp')),
            'attendees.csv'
        );
        Test.stopTest();

        System.assertEquals(1, res.attendeesCreated);
        System.assertEquals(
            1,
            [SELECT COUNT() FROM Event_Attendee__c WHERE Last_Name__c = 'Carter'],
            'The import does not look at Contact, so it cannot skip her'
        );
    }

    // ================= what an attendee carries =================

    @IsTest
    static void createsAnAttendeeCarryingEveryColumnTheFileHad() {
        AttendeeImportController.ImportRow r = row('Zoë', 'Müller-Sørensen', 'z.m@newco.example', 'NewCo Labs');
        r.title = 'Head of Analytics';
        r.mobile = '+49 170 1234567';

        Test.startTest();
        AttendeeImportController.ApplyResult res = AttendeeImportController.applyChanges(one(r), 'attendees.csv');
        Test.stopTest();

        System.assertEquals(1, res.attendeesCreated);
        System.assertEquals(0, res.attendeesUpdated);

        Event_Attendee__c a = [
            SELECT Name, First_Name__c, Last_Name__c, Email__c, Title__c, Company__c, Mobile__c, Source_File__c
            FROM Event_Attendee__c
        ];
        System.assertEquals('Zoë Müller-Sørensen', a.Name, 'Non-ASCII names survive intact');
        System.assertEquals('Zoë', a.First_Name__c);
        System.assertEquals('Müller-Sørensen', a.Last_Name__c);
        System.assertEquals('z.m@newco.example', a.Email__c);
        // Title and Mobile were parsed and thrown away in R4 for want of anywhere to
        // put them that was not a Contact. Losing them again would be a regression.
        System.assertEquals('Head of Analytics', a.Title__c);
        System.assertEquals('+49 170 1234567', a.Mobile__c);
        System.assertEquals('attendees.csv', a.Source_File__c);
    }

    /** No first name is a legitimate list, not an error: the name field falls back to the surname. */
    @IsTest
    static void anAttendeeWithNoFirstNameIsStillUsable() {
        Test.startTest();
        AttendeeImportController.applyChanges(one(row(null, 'Prince', 'p@x.example', 'Paisley Park')), 'a.csv');
        Test.stopTest();
        Event_Attendee__c a = [SELECT Name, First_Name__c FROM Event_Attendee__c];
        System.assertEquals('Prince', a.Name);
        System.assertEquals(null, a.First_Name__c);
    }

    /** No email at all is the common case on a conference list, and must not be a blocker. */
    @IsTest
    static void anAttendeeWithNoEmailIsCreated() {
        Test.startTest();
        AttendeeImportController.applyChanges(one(row('Marie', 'Dupont', null, 'Acme Corp')), 'a.csv');
        Test.stopTest();
        System.assertEquals(null, [SELECT Email__c FROM Event_Attendee__c].Email__c);
        System.assertEquals(1, [SELECT COUNT() FROM Event_Attendee__c]);
    }

    // ================= de-duplication =================

    /** Re-running the same file updates the same attendees rather than cloning them. */
    @IsTest
    static void reRunningTheSameFileCreatesNobodyNew() {
        List<AttendeeImportController.ImportRow> rows = new List<AttendeeImportController.ImportRow>{
            row('Emily', 'Carter', 'emily.carter@acmecorp.example', 'Acme Corp'),
            row('Anke', 'Weber', 'a.weber@tuberlin.example', 'TU Berlin')
        };

        Test.startTest();
        AttendeeImportController.ApplyResult first = AttendeeImportController.applyChanges(rows, 'run1.csv');
        AttendeeImportController.ApplyResult second = AttendeeImportController.applyChanges(rows, 'run2.csv');
        Test.stopTest();

        System.assertEquals(2, first.attendeesCreated);
        System.assertEquals(0, second.attendeesCreated, 'Upsert on Unique_Key__c, not insert');
        System.assertEquals(2, second.attendeesUpdated);
        System.assertEquals(2, [SELECT COUNT() FROM Event_Attendee__c]);
        System.assertEquals(
            2,
            [SELECT COUNT() FROM Event_Attendee__c WHERE Source_File__c = 'run2.csv'],
            'The newest file wins on the fields that are not part of the identity'
        );
    }

    /** A second file that corrects a title updates the attendee instead of adding one. */
    @IsTest
    static void aLaterFileRefreshesTitleAndMobile() {
        AttendeeImportController.ImportRow before = row('Anke', 'Weber', 'a.weber@tuberlin.example', 'TU Berlin');
        before.title = 'Professor';
        AttendeeImportController.ImportRow after = row('Anke', 'Weber', 'a.weber@tuberlin.example', 'TU Berlin');
        after.title = 'Dean of Engineering';

        Test.startTest();
        AttendeeImportController.applyChanges(one(before), 'run1.csv');
        AttendeeImportController.applyChanges(one(after), 'run2.csv');
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Event_Attendee__c]);
        System.assertEquals('Dean of Engineering', [SELECT Title__c FROM Event_Attendee__c].Title__c);
    }

    /** The same person twice in one file collapses before any DML happens. */
    @IsTest
    static void duplicateRowsInOneFileCollapse() {
        Test.startTest();
        AttendeeImportController.ApplyResult res = AttendeeImportController.applyChanges(
            new List<AttendeeImportController.ImportRow>{
                row('Dana', 'Duplicate', 'dana@dupe.example', 'Acme Corp'),
                row('DANA', ' duplicate ', 'DANA@DUPE.EXAMPLE', 'acme  corp')
            },
            'attendees.csv'
        );
        Test.stopTest();
        System.assertEquals(
            1,
            res.attendeesCreated,
            'Case, padding and doubled spaces are normalised out of the key, so this is one person'
        );
        System.assertEquals(1, [SELECT COUNT() FROM Event_Attendee__c]);
    }

    /** Two different people who share an email are two attendees — an email is not an identity. */
    @IsTest
    static void twoPeopleSharingOneInboxStayTwoAttendees() {
        Test.startTest();
        AttendeeImportController.applyChanges(
            new List<AttendeeImportController.ImportRow>{
                row('Jane', 'Doe', 'events@acme.example', 'Acme Corp'),
                row('John', 'Roe', 'events@acme.example', 'Acme Corp')
            },
            'attendees.csv'
        );
        Test.stopTest();
        System.assertEquals(2, [SELECT COUNT() FROM Event_Attendee__c]);
    }

    /**
     * The cost of choosing an identity from the columns a file has, asserted so it
     * is a known behaviour rather than a surprise: two same-named people at one
     * company, separated only by an email one row lacks, collapse into one attendee.
     */
    @IsTest
    static void sameNameAndCompanyWithoutAnEmailCollapses() {
        Test.startTest();
        AttendeeImportController.applyChanges(
            new List<AttendeeImportController.ImportRow>{
                row('Marie', 'Dupont', null, 'Acme Corp'),
                row('Marie', 'Dupont', null, 'Acme Corp')
            },
            'attendees.csv'
        );
        Test.stopTest();
        System.assertEquals(1, [SELECT COUNT() FROM Event_Attendee__c]);
    }

    /** …and the same two, once their emails are known, are correctly two people. */
    @IsTest
    static void anEmailSeparatesTwoPeopleOfTheSameNameAtOneCompany() {
        Test.startTest();
        AttendeeImportController.applyChanges(
            new List<AttendeeImportController.ImportRow>{
                row('Marie', 'Dupont', 'm.dupont@acmecorp.example', 'Acme Corp'),
                row('Marie', 'Dupont', 'marie.dupont@acmecorp.example', 'Acme Corp')
            },
            'attendees.csv'
        );
        Test.stopTest();
        System.assertEquals(2, [SELECT COUNT() FROM Event_Attendee__c]);
    }

    // ================= preview =================

    @IsTest
    static void previewTellsNewApartFromExisting() {
        AttendeeImportController.applyChanges(
            one(row('Emily', 'Carter', 'emily.carter@acmecorp.example', 'Acme Corp')),
            'run1.csv'
        );

        Test.startTest();
        List<AttendeeImportController.PreviewResult> res = AttendeeImportController.previewMatches(
            new List<AttendeeImportController.ImportRow>{
                row('Emily', 'Carter', 'emily.carter@acmecorp.example', 'Acme Corp'),
                row('Brand', 'New', 'b.new@elsewhere.example', 'Elsewhere Ltd')
            }
        );
        Test.stopTest();

        System.assertEquals(AttendeeImportController.EXISTING_ATTENDEE, res[0].classification);
        System.assertNotEquals(null, res[0].attendeeId, 'The preview links to the record it will refresh');
        System.assertEquals(AttendeeImportController.NEW_ATTENDEE, res[1].classification);
        System.assertEquals(null, res[1].attendeeId);
    }

    @IsTest
    static void previewWritesNothing() {
        Test.startTest();
        AttendeeImportController.previewMatches(one(row('Brand', 'New', 'b@x.example', 'Elsewhere Ltd')));
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM Event_Attendee__c], 'Preview is read-only');
    }

    // ================= refusals =================

    @IsTest
    static void rowsWithoutALastNameAreSkippedAndWriteNothing() {
        Test.startTest();
        List<AttendeeImportController.PreviewResult> preview = AttendeeImportController.previewMatches(
            one(row('Nameless', '', 'x@y.example', 'Acme Corp'))
        );
        AttendeeImportController.ApplyResult res = AttendeeImportController.applyChanges(
            one(row('Nameless', '', 'x@y.example', 'Acme Corp')),
            'attendees.csv'
        );
        Test.stopTest();

        System.assertEquals(AttendeeImportController.SKIPPED, preview[0].classification);
        System.assert(preview[0].reason.contains('last name'), 'Say why: ' + preview[0].reason);
        System.assertEquals(0, res.attendeesCreated);
        System.assertEquals(0, [SELECT COUNT() FROM Event_Attendee__c]);
    }

    @IsTest
    static void rejectsOversizedAndEmptyInput() {
        List<AttendeeImportController.ImportRow> tooMany = new List<AttendeeImportController.ImportRow>();
        for (Integer i = 0; i <= AttendeeImportController.MAX_ROWS; i++) {
            tooMany.add(row('A', 'B' + i, 'a' + i + '@x.example', null));
        }
        Boolean threwOversize = false;
        try {
            AttendeeImportController.previewMatches(tooMany);
        } catch (AuraHandledException e) {
            threwOversize = true;
        }
        System.assert(threwOversize, 'Should reject > MAX_ROWS');

        Boolean threwEmpty = false;
        try {
            AttendeeImportController.applyChanges(new List<AttendeeImportController.ImportRow>(), 'x.csv');
        } catch (AuraHandledException e) {
            threwEmpty = true;
        }
        System.assert(threwEmpty, 'Should reject empty input');
    }

    /**
     * A row where every column is far too long must still store. A CSV is not
     * obliged to respect our field lengths, and a whole upload failing on one
     * overlong cell is the failure mode this guards.
     */
    @IsTest
    static void anOverlongRowStillStores() {
        String huge = 'x'.repeat(300);
        Test.startTest();
        AttendeeImportController.applyChanges(one(row(huge, huge, huge + '@x.example', huge)), 'a.csv');
        Test.stopTest();

        Event_Attendee__c a = [SELECT Unique_Key__c, Last_Name__c, First_Name__c FROM Event_Attendee__c];
        System.assert(a.Unique_Key__c.length() <= 255, 'Key must fit the field, was ' + a.Unique_Key__c.length());
        System.assertEquals(80, a.Last_Name__c.length());
        System.assertEquals(40, a.First_Name__c.length());
    }

    /**
     * The junk a real Email column carries. Email__c is a typed field that refuses
     * these; the trade R5 takes is to keep the person and drop the address, and to
     * say which rows that happened to rather than swallowing it.
     */
    @IsTest
    static void junkInTheEmailColumnCostsTheAddressAndNotThePerson() {
        Test.startTest();
        List<AttendeeImportController.PreviewResult> preview = AttendeeImportController.previewMatches(
            one(row('Ben', 'Nomail', 'n/a', 'Acme Corp'))
        );
        AttendeeImportController.ApplyResult res = AttendeeImportController.applyChanges(
            new List<AttendeeImportController.ImportRow>{
                row('Ben', 'Nomail', 'n/a', 'Acme Corp'),
                row('Cara', 'Notes', 'see attached list', 'Acme Corp'),
                row('Dee', 'Fine', 'dee@acme.example', 'Acme Corp')
            },
            'attendees.csv'
        );
        Test.stopTest();

        System.assertEquals(AttendeeImportController.NEW_ATTENDEE, preview[0].classification, 'The person is kept');
        System.assert(
            preview[0].reason.contains('not an address'),
            'The preview has to admit what it dropped: ' + preview[0].reason
        );
        System.assertEquals(3, res.attendeesCreated, 'One bad cell must not fail the other rows');
        System.assertEquals(2, [SELECT COUNT() FROM Event_Attendee__c WHERE Email__c = NULL]);
        System.assertEquals(
            'dee@acme.example',
            [SELECT Email__c FROM Event_Attendee__c WHERE Last_Name__c = 'Fine'].Email__c
        );
    }

    /** Unique_Key__c is what stops a hand-inserted duplicate, not just the Apex. */
    @IsTest
    static void theDatabaseRefusesASecondAttendeeWithTheSameKey() {
        insert new Event_Attendee__c(Name = 'Jane Doe', Last_Name__c = 'Doe', Unique_Key__c = 'doe|jane|acme|j@x');

        Boolean threw = false;
        try {
            insert new Event_Attendee__c(Name = 'Jane Doe', Last_Name__c = 'Doe', Unique_Key__c = 'doe|jane|acme|j@x');
        } catch (DmlException e) {
            threw = true;
        }
        System.assert(threw, 'De-duplication has to hold at the database, not only in the import');
    }
}
