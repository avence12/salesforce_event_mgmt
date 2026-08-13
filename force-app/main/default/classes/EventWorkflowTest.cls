/**
 * End-to-end workflow tests: add → submit (approver resolution + notifications) →
 * approve/reject through the standard approval process → completion notification →
 * rejected re-add.
 *
 * Two AMs share one manager, which is the whole of the R5 routing rule. The
 * Account Owner and Lead Owner rungs the earlier revisions tested went with the
 * Account and Lead lookups; what replaces those tests is an assertion that a
 * submitter with no manager is refused, because that is now the only way routing
 * can fail.
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

    private static Event_Attendee__c attendee(String first, String last, String company) {
        return new Event_Attendee__c(
            Name = first + ' ' + last,
            First_Name__c = first,
            Last_Name__c = last,
            Email__c = first.toLowerCase() + '@' + 'evt.example',
            Title__c = 'Attendee',
            Company__c = company,
            Unique_Key__c = (last + '|' + first + '|' + company).toLowerCase()
        );
    }

    @TestSetup
    static void setup() {
        Profile std = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        List<User> users = new List<User>();
        for (String alias : new List<String>{ 'amalex', 'ammaria', 'mgrdana' }) {
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
            // Dana manages both AMs — the only rung the R5 ladder has.
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
            Name = 'Q3 2026 Customer Appreciation Gala',
            Event_Date__c = Date.today().addDays(60),
            Location__c = 'The Plaza, New York',
            Event_Type__c = 'Conference'
        );
    }

    private static Id attendeeId(String last) {
        return [SELECT Id FROM Event_Attendee__c WHERE Last_Name__c = :last LIMIT 1].Id;
    }

    @IsTest
    static void fullWorkflow_submitApproveReject() {
        User alex = findUser('amalex');
        User maria = findUser('ammaria');
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
            System.assertEquals(1, sub.approversNotified, 'One submitter has one manager');
        }
        System.runAs(maria) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ james });
            InviteeSelectorController.submitMyInvitees(evt.Id);
        }

        // The approval process, not our Apex, owns the status from submission onwards.
        for (Event_Invitee__c inv : [SELECT Approver__c, Status__c, Submitted_At__c FROM Event_Invitee__c]) {
            System.assertEquals('Pending Approval', inv.Status__c, 'Initial submission action must set the status');
            System.assertEquals(dana.Id, inv.Approver__c, 'Every invitee routes to the submitter’s manager');
            System.assertNotEquals(null, inv.Submitted_At__c);
        }
        System.assertEquals(3, [SELECT COUNT() FROM ProcessInstance], 'One approval instance per invitee');

        List<Event_Invitee__c> alexRows = [
            SELECT Id
            FROM Event_Invitee__c
            WHERE Event_Attendee__c IN (:emily, :robert)
            ORDER BY Id
        ];

        Test.startTest();
        System.runAs(dana) {
            decide(alexRows[0].Id, true);
            decide(alexRows[1].Id, false);
        }
        Test.stopTest();

        Map<Id, Event_Invitee__c> after = new Map<Id, Event_Invitee__c>(
            [SELECT Id, Status__c, Decided_At__c FROM Event_Invitee__c WHERE Id IN :alexRows]
        );
        System.assertEquals('Approved', after.get(alexRows[0].Id).Status__c);
        System.assertEquals('Rejected', after.get(alexRows[1].Id).Status__c);
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
        System.assertEquals(1, counts.Pending_Count__c, 'Maria’s row is untouched');
    }

    /**
     * The formula fields are what let the reports and the approval page read an
     * invitee without knowing there is an attendee behind it. Nothing about an
     * attendee's own record should have to be re-taught to those consumers.
     */
    @IsTest
    static void inviteeReadsThroughToTheAttendee() {
        User alex = findUser('amalex');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        Id helene = attendeeId('Dubois');

        System.runAs(alex) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ helene });
        }

        Event_Invitee__c inv = [
            SELECT Invitee_Name__c, Invitee_Org__c, Invitee_Title__c, Invitee_Email__c
            FROM Event_Invitee__c
            WHERE Event_Attendee__c = :helene
        ];
        System.assertEquals('Hélène Dubois', inv.Invitee_Name__c, 'Non-ASCII names survive the formula');
        System.assertEquals('Université de Genève', inv.Invitee_Org__c, 'Company text stands in for an Account');
        System.assertEquals('Attendee', inv.Invitee_Title__c);
        System.assertNotEquals(null, inv.Invitee_Email__c);

        // The point of the whole revision: inviting somebody invents no customer record.
        System.assertEquals(0, [SELECT COUNT() FROM Account], 'No Account may be created anywhere in this flow');
        System.assertEquals(0, [SELECT COUNT() FROM Contact]);
        System.assertEquals(0, [SELECT COUNT() FROM Lead]);
    }

    /**
     * The orphan-row defect, made unreachable. With one rung on the ladder, a
     * submitter with no manager has nowhere to route at all; the submit must fail
     * with a named error and leave everything in Draft, rather than creating a
     * pending row no approver can ever see.
     */
    @IsTest
    static void unroutableSubmitIsRefusedAndNothingMoves() {
        User maria = findUser('ammaria');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            update new User(Id = maria.Id, ManagerId = null);
        }
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        Id emily = attendeeId('Carter');

        System.runAs(maria) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ emily });

            Boolean threw = false;
            try {
                InviteeSelectorController.submitMyInvitees(evt.Id);
            } catch (AuraHandledException e) {
                threw = true;
            }
            System.assert(threw, 'No manager → the submit must fail loudly');
        }

        System.assertEquals(
            0,
            [SELECT COUNT() FROM Event_Invitee__c WHERE Status__c = 'Pending Approval'],
            'A refused submit must move nothing — no half-submitted batch'
        );
        System.assertEquals(1, [SELECT COUNT() FROM Event_Invitee__c WHERE Status__c = 'Draft']);
        System.assertEquals(0, [SELECT COUNT() FROM ProcessInstance], 'Nothing entered the approval process');
    }

    /** An invitee pointing at nobody has a blank name everywhere it is read. */
    @IsTest
    static void inviteeWithoutAnAttendeeIsRefused() {
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        Boolean threw = false;
        try {
            insert new Event_Invitee__c(Marketing_Event__c = evt.Id, Status__c = 'Draft', Unique_Key__c = 'k-none');
        } catch (DmlException e) {
            threw = true;
        }
        System.assert(threw, 'Invitee_Requires_Attendee must refuse it');
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
        User alex = findUser('amalex');
        User dana = findUser('mgrdana');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];

        System.runAs(alex) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ attendeeId('Carter'), attendeeId('Kim') });
            InviteeSelectorController.submitMyInvitees(evt.Id);
        }
        List<Event_Invitee__c> rows = [SELECT Id FROM Event_Invitee__c ORDER BY Id];

        Test.startTest();
        EventNotificationService.emailsSent = 0;
        // One of two decided: the AM still has something pending, so stay quiet.
        System.runAs(dana) {
            decide(rows[0].Id, true);
        }
        EventNotificationService.notifyCompletions(new List<Id>{ rows[0].Id });
        System.assertEquals(0, EventNotificationService.emailsSent, 'One row left pending — no completion email yet');

        System.runAs(dana) {
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

        System.runAs(alex) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ attendeeId('Carter'), attendeeId('Kim') });
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
    static void rejectedAttendeeCanBeReAdded() {
        User alex = findUser('amalex');
        User dana = findUser('mgrdana');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        Id emily = attendeeId('Carter');

        System.runAs(alex) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ emily });
            InviteeSelectorController.submitMyInvitees(evt.Id);
        }
        Event_Invitee__c inv = [SELECT Id FROM Event_Invitee__c WHERE Event_Attendee__c = :emily];

        Test.startTest();
        System.runAs(dana) {
            decide(inv.Id, false);
        }
        Test.stopTest();

        System.runAs(alex) {
            System.assertEquals(
                1,
                InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ emily }),
                'Rejected row should reset, not error'
            );
        }
        inv = [
            SELECT Status__c, Submitted_At__c, Decided_At__c, Approver__c
            FROM Event_Invitee__c
            WHERE Id = :inv.Id
        ];
        System.assertEquals('Draft', inv.Status__c);
        System.assertEquals(null, inv.Submitted_At__c);
        System.assertEquals(null, inv.Decided_At__c);
        System.assertEquals(
            null,
            inv.Approver__c,
            'A stale approver would let the next submit skip resolution and reuse whoever decided last time'
        );
        System.assertEquals(
            1,
            [SELECT COUNT() FROM Event_Invitee__c WHERE Event_Attendee__c = :emily],
            'Never a second row per event+attendee'
        );
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
            System.assertEquals('Acme Corp', all[0].company, 'Read through Invitee_Org__c, not the lookup');
        }
    }

    /** A rejected invitee reappears in the picker; that is what makes re-adding possible at all. */
    @IsTest
    static void aRejectedAttendeeReappearsInTheSelector() {
        User alex = findUser('amalex');
        User dana = findUser('mgrdana');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        Id emily = attendeeId('Carter');

        System.runAs(alex) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ emily });
            InviteeSelectorController.submitMyInvitees(evt.Id);
        }
        Test.startTest();
        System.runAs(dana) {
            decide([SELECT Id FROM Event_Invitee__c WHERE Event_Attendee__c = :emily].Id, false);
        }
        Test.stopTest();

        System.runAs(alex) {
            InviteeSelectorController.SelectableResult sel = InviteeSelectorController.getSelectableAttendees(evt.Id);
            System.assertEquals(4, sel.attendees.size(), 'A rejected invitee is selectable again');
        }
    }

    // ================= ★R6 attendance =================

    /** Drives one attendee all the way to Approved, so attendance can be recorded on it. */
    private static Id approvedInvitee(String lastName) {
        User alex = findUser('amalex');
        User dana = findUser('mgrdana');
        Marketing_Event__c evt = [SELECT Id FROM Marketing_Event__c LIMIT 1];
        Id att = attendeeId(lastName);
        System.runAs(alex) {
            InviteeSelectorController.addAttendees(evt.Id, new List<Id>{ att });
            InviteeSelectorController.submitMyInvitees(evt.Id);
        }
        Id invId = [SELECT Id FROM Event_Invitee__c WHERE Event_Attendee__c = :att].Id;
        System.runAs(dana) {
            decide(invId, true);
        }
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
}
