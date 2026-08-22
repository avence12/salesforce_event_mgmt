/**
 * ★R12 The per-status snapshot rule, which is the whole of what this trigger decides.
 *
 * The test that matters most is approvedInviteesNeverMove. R8's argument — an approval
 * record that changes after the fact is not a record — is the thing R12 is narrowing,
 * and a narrowing is only safe if the case it was protecting still holds. If that test
 * fails, R12 broke the audit trail and the rest of this class is irrelevant.
 */
@IsTest
private class EventAttendeeSyncTest {
    private static final String OLD_TITLE = 'Engineer';
    private static final String NEW_TITLE = 'Chief Engineer';

    @TestSetup
    static void setup() {
        Account acme = new Account(Name = 'Acme Corp', AccountNumber = 'CUST-0042');
        insert acme;
        Contact emily = new Contact(FirstName = 'Emily', LastName = 'Carter', AccountId = acme.Id);
        insert emily;

        insert new Marketing_Event__c(Name = 'Spring Symposium', Event_Date__c = Date.today().addDays(30));

        insert new Event_Attendee__c(
            Name = 'Emily Carter',
            First_Name__c = 'Emily',
            Last_Name__c = 'Carter',
            Title__c = OLD_TITLE,
            Salutation__c = 'Ms.',
            Company__c = 'Acme Corp',
            Cust_Cd__c = 'CUST-0042',
            Contact__c = emily.Id,
            Unique_Key__c = 'carter|emily|acme corp|'
        );
    }

    private static Event_Attendee__c theAttendee() {
        return [SELECT Id, Title__c, Cust_Cd__c, Company__c FROM Event_Attendee__c LIMIT 1];
    }

    /** One invitee in the given status, snapshotted as it stood at setup. */
    private static Event_Invitee__c inviteeIn(String status) {
        Event_Attendee__c a = theAttendee();
        Marketing_Event__c e = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        Event_Invitee__c inv = new Event_Invitee__c(
            Marketing_Event__c = e.Id,
            Event_Attendee__c = a.Id,
            Status__c = status,
            Invitee_Title__c = OLD_TITLE,
            Invitee_Salutation__c = 'Ms.',
            Invitee_Org__c = 'Acme Corp',
            Cust_Cd__c = 'CUST-0042',
            Account_Manager__c = UserInfo.getUserId(),
            Unique_Key__c = String.valueOf(e.Id) + '-' + String.valueOf(a.Id)
        );
        insert inv;
        return inv;
    }

    private static Event_Invitee__c reread(Id inviteeId) {
        return [
            SELECT Invitee_Title__c, Invitee_Org__c, Cust_Cd__c, Account__c, Account_Manager__c
            FROM Event_Invitee__c
            WHERE Id = :inviteeId
        ];
    }

    private static void retitleTheAttendee() {
        Event_Attendee__c a = theAttendee();
        a.Title__c = NEW_TITLE;
        update a;
    }

    // ================= the requirement =================

    /**
     * R8's case, unchanged. A decided invitation is a record of what the approver saw,
     * and correcting the attendee afterwards must not rewrite it.
     */
    @IsTest
    static void approvedInviteesNeverMove() {
        Event_Invitee__c inv = inviteeIn('Approved');

        Test.startTest();
        retitleTheAttendee();
        Test.stopTest();

        System.assertEquals(
            OLD_TITLE,
            reread(inv.Id).Invitee_Title__c,
            'An approval that changes after the fact is not a record'
        );
    }

    /** Same reasoning: a rejection is a decision too. */
    @IsTest
    static void rejectedInviteesNeverMove() {
        Event_Invitee__c inv = inviteeIn('Rejected');

        Test.startTest();
        retitleTheAttendee();
        Test.stopTest();

        System.assertEquals(OLD_TITLE, reread(inv.Id).Invitee_Title__c);
    }

    // ================= what R12 adds =================

    /** Nothing is frozen on a Draft, so a correction reaches it before anyone is asked to approve it. */
    @IsTest
    static void draftInviteesFollowTheAttendee() {
        Event_Invitee__c inv = inviteeIn('Draft');

        Test.startTest();
        retitleTheAttendee();
        Test.stopTest();

        System.assertEquals(
            NEW_TITLE,
            reread(inv.Id).Invitee_Title__c,
            'A Draft has been approved by nobody — freezing a typo into it protects nothing'
        );
    }

    /** An approver should read what is true now, not what was true when the AM added the row. */
    @IsTest
    static void pendingInviteesFollowTheAttendeesDisplayFields() {
        Event_Invitee__c inv = inviteeIn('Pending Approval');

        Test.startTest();
        Event_Attendee__c a = theAttendee();
        a.Title__c = NEW_TITLE;
        a.Cust_Cd__c = 'CUST-0099';
        update a;
        Test.stopTest();

        Event_Invitee__c after = reread(inv.Id);
        System.assertEquals(NEW_TITLE, after.Invitee_Title__c);
        System.assertEquals('CUST-0099', after.Cust_Cd__c, 'The code is a display field — nothing routes on it');
    }

    /**
     * The reason Pending is display-only rather than a full re-stamp.
     *
     * The approver chain was resolved and frozen onto Approver_1..5__c at submit. Moving
     * Account_Manager__c underneath it would leave the row describing one approver while
     * addressed to another — an inconsistency nothing downstream would notice and no
     * report could explain.
     */
    @IsTest
    static void pendingInviteesKeepTheirRoutingFields() {
        Event_Invitee__c inv = inviteeIn('Pending Approval');
        Id manager = reread(inv.Id).Account_Manager__c;
        System.assertNotEquals(null, manager, 'Precondition: the row was routed');

        Test.startTest();
        // Unlinking the Contact is the sharpest version of the case: a full re-stamp
        // would blank Account_Manager__c outright.
        Event_Attendee__c a = [SELECT Id, Contact__c FROM Event_Attendee__c LIMIT 1];
        a.Contact__c = null;
        update a;
        Test.stopTest();

        System.assertEquals(
            manager,
            reread(inv.Id).Account_Manager__c,
            'A chain in flight must not be re-pointed underneath itself'
        );
    }

    /** An edit that moves nothing an invitee shows must not write invitees at all. */
    @IsTest
    static void anUnrelatedEditSyncsNothing() {
        Event_Invitee__c inv = inviteeIn('Draft');
        Datetime before = [SELECT LastModifiedDate FROM Event_Invitee__c WHERE Id = :inv.Id].LastModifiedDate;

        Test.startTest();
        Event_Attendee__c a = [SELECT Id, Mobile__c FROM Event_Attendee__c LIMIT 1];
        a.Mobile__c = '+41 79 000 0000';
        update a;
        Test.stopTest();

        System.assertEquals(
            before,
            [SELECT LastModifiedDate FROM Event_Invitee__c WHERE Id = :inv.Id].LastModifiedDate,
            'A phone number is not snapshotted — touching invitees for it would cost DML on every re-import'
        );
    }

    /**
     * The invariant from CLAUDE.md, asserted here as well as in the import's tests:
     * this trigger writes Event_Invitee__c and no standard object.
     */
    @IsTest
    static void syncNeverTouchesContactsOrAccounts() {
        inviteeIn('Draft');
        List<Contact> contactsBefore = [SELECT Id, LastModifiedDate, Title FROM Contact ORDER BY Id];
        List<Account> accountsBefore = [SELECT Id, LastModifiedDate, Name FROM Account ORDER BY Id];

        Test.startTest();
        retitleTheAttendee();
        Test.stopTest();

        List<Contact> contactsAfter = [SELECT Id, LastModifiedDate, Title FROM Contact ORDER BY Id];
        System.assertEquals(contactsBefore.size(), contactsAfter.size());
        for (Integer i = 0; i < contactsBefore.size(); i++) {
            System.assertEquals(
                contactsBefore[i].LastModifiedDate,
                contactsAfter[i].LastModifiedDate,
                'No Contact may be modified'
            );
        }
        List<Account> accountsAfter = [SELECT Id, LastModifiedDate, Name FROM Account ORDER BY Id];
        System.assertEquals(accountsBefore.size(), accountsAfter.size());
        for (Integer i = 0; i < accountsBefore.size(); i++) {
            System.assertEquals(
                accountsBefore[i].LastModifiedDate,
                accountsAfter[i].LastModifiedDate,
                'No Account may be modified'
            );
        }
    }

    /** Bulk: one update of many attendees is one pass, not one per record. */
    @IsTest
    static void syncIsBulkSafe() {
        Marketing_Event__c e = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        List<Event_Attendee__c> people = new List<Event_Attendee__c>();
        for (Integer i = 0; i < 200; i++) {
            people.add(
                new Event_Attendee__c(
                    Name = 'Person ' + i,
                    Last_Name__c = 'Person' + i,
                    Title__c = OLD_TITLE,
                    Unique_Key__c = 'person' + i + '||||'
                )
            );
        }
        insert people;

        List<Event_Invitee__c> invitees = new List<Event_Invitee__c>();
        for (Event_Attendee__c a : people) {
            invitees.add(
                new Event_Invitee__c(
                    Marketing_Event__c = e.Id,
                    Event_Attendee__c = a.Id,
                    Status__c = 'Draft',
                    Invitee_Title__c = OLD_TITLE,
                    Unique_Key__c = String.valueOf(e.Id) + '-' + String.valueOf(a.Id)
                )
            );
        }
        insert invitees;

        for (Event_Attendee__c a : people) {
            a.Title__c = NEW_TITLE;
        }

        Test.startTest();
        update people;
        Test.stopTest();

        System.assertEquals(
            200,
            [SELECT COUNT() FROM Event_Invitee__c WHERE Invitee_Title__c = :NEW_TITLE],
            'Every draft invitee in the batch follows its attendee'
        );
    }
}
