/**
 * Demo seed data for the Event Management PoC.
 * Run with:  sf apex run --file scripts/seed-demo-data.apex -o <sandbox-alias>
 *
 * ★R5 this script no longer creates a single Account, Contact or Lead. There is
 * nothing left in the workflow that reads one: attendees are their own object and
 * approval routes to the submitter's manager. Anything the demo needs from the
 * standard objects, it does not need.
 *
 * The handful of attendees below exist so the demo has something to invite before
 * anyone has uploaded a file, and so that re-running the demo CSV shows a mix of
 * "New" and "Already known" rather than 49 identical New rows. They are keyed the
 * same way AttendeeImportController keys them — last|first|company|email, lower
 * case, whitespace collapsed — so the import recognises them as the same people.
 */

// ---- Attendees (idempotent by Unique_Key__c) ----
// Deliberately a subset of demo-data/FinTech_Summit_2026_Attendees.csv: those rows
// come back as EXISTING_ATTENDEE, the rest as NEW_ATTENDEE.
List<List<String>> seed = new List<List<String>>{
// ★R12 The sixth column is the customer code the CSV carries. Blank for the professors,
// the researcher and the journalist — they belong to no customer, and that blank is the
// same fact that leaves them without a Contact and therefore without an approval chain.
List<List<String>> seed = new List<List<String>>{
    new List<String>{ 'Emily',  'Carter',   'emily.carter@acmecorp.example', 'Senior Manager', 'Acme Corp', 'CUST-0042' },
    new List<String>{ 'James',  'Mueller',  'j.mueller@nordbank.example',    'Director',       'Nordbank AG', 'CUST-0077' },
    new List<String>{ 'Robert', 'Kim',      'robert.kim@acmecorp.example',   'SVP, Operations','Acme Corp', 'CUST-0042' },
    new List<String>{ 'Hélène', 'Dubois',   'h.dubois@unige.example',        'Professor of Cryptography', 'Université de Genève', '' },
    new List<String>{ 'Anke',   'Weber',    'a.weber@tuberlin.example',      'Professor, Distributed Systems', 'TU Berlin', '' },
    new List<String>{ 'Tomas',  'Lindqvist','t.lindqvist@kth.example',       'Senior Researcher', 'KTH Royal Institute', '' },
    new List<String>{ 'Priya',  'Raman',    'p.raman@techpress.example',     'Editor',         'TechPress Media', '' }
};

List<Event_Attendee__c> attendees = new List<Event_Attendee__c>();
for (List<String> s : seed) {
    String first = s[0], last = s[1], email = s[2], title = s[3], company = s[4];
    // ★R12 Deliberately NOT folded into the key below — Unique_Key__c does not include
    // the code, so a reassigned code refreshes one attendee rather than creating a second.
    String custCd = s[5];
    // Must match AttendeeImportController.attendeeKey exactly, or the import will
    // create second copies of these people instead of recognising them.
    String key =
        last.trim().toLowerCase().replaceAll('\\s+', ' ').left(80) + '|' +
        first.trim().toLowerCase().replaceAll('\\s+', ' ').left(40) + '|' +
        company.trim().toLowerCase().replaceAll('\\s+', ' ').left(60) + '|' +
        email.trim().toLowerCase().replaceAll('\\s+', ' ').left(70);
    attendees.add(new Event_Attendee__c(
        Name = first + ' ' + last,
        First_Name__c = first,
        Last_Name__c = last,
        Email__c = email,
        Title__c = title,
        Company__c = company,
        Cust_Cd__c = String.isBlank(custCd) ? null : custCd,
        Source_File__c = 'seed-demo-data.apex',
        Imported_On__c = Datetime.now(),
        Unique_Key__c = key
    ));
}
upsert attendees Unique_Key__c;

// ---- A sample event ----
if ([SELECT COUNT() FROM Marketing_Event__c WHERE Name = 'Q3 2026 Customer Appreciation Gala'] == 0) {
    insert new Marketing_Event__c(
        Name = 'Q3 2026 Customer Appreciation Gala',
        Event_Date__c = Date.newInstance(2026, 9, 18),
        Location__c = 'The Plaza, New York',
        Event_Type__c = 'Conference',
        Expected_Attendees__c = 150,
        Description__c = 'Annual appreciation event for key financial-sector customers.'
    );
}

// ---- ★R6 A second, past event, so the demo has attendance history to recommend from ----
// One event gives you a guest list; two give you "this person came to the Payments
// symposium, so the Payments conference is a fair suggestion". A recommendation demo
// with a single event in the org demonstrates nothing.
if ([SELECT COUNT() FROM Marketing_Event__c WHERE Name = 'Payments Innovation Symposium 2025'] == 0) {
    insert new Marketing_Event__c(
        Name = 'Payments Innovation Symposium 2025',
        Event_Date__c = Date.newInstance(2025, 11, 6),
        Location__c = 'Frankfurt',
        Event_Type__c = 'Symposium',
        Expected_Attendees__c = 80,
        Description__c = 'Past event. Its attendance is what the Attendee Event History report reads.'
    );
}

// ---- ★R11 Topics — free tags a BD adds from the event page, not a picklist an admin
// seeds in Setup. Tagged here only so the demo has something to show; re-running this
// script must not create the same tag twice on the same event, so each event's
// existing tags are read first and only the missing ones are inserted.
Map<String, Set<String>> topicsByEvent = new Map<String, Set<String>>{
    'Q3 2026 Customer Appreciation Gala' => new Set<String>{ 'Digital Banking', 'Payments' },
    'Payments Innovation Symposium 2025' => new Set<String>{ 'Payments', 'AI & Data' }
};
Map<Id, String> eventNameById = new Map<Id, String>();
for (Marketing_Event__c e : [
    SELECT Id, Name
    FROM Marketing_Event__c
    WHERE Name IN :topicsByEvent.keySet()
]) {
    eventNameById.put(e.Id, e.Name);
}
Set<String> alreadyTagged = new Set<String>(); // 'eventId|topic name'
for (Event_Topic__c t : [
    SELECT Marketing_Event__c, Name
    FROM Event_Topic__c
    WHERE Marketing_Event__c IN :eventNameById.keySet()
]) {
    alreadyTagged.add(t.Marketing_Event__c + '|' + t.Name);
}
List<Event_Topic__c> newTopics = new List<Event_Topic__c>();
for (Id eventId : eventNameById.keySet()) {
    for (String topic : topicsByEvent.get(eventNameById.get(eventId))) {
        if (!alreadyTagged.contains(eventId + '|' + topic)) {
            newTopics.add(new Event_Topic__c(Marketing_Event__c = eventId, Name = topic));
        }
    }
}
if (!newTopics.isEmpty()) {
    insert newTopics;
}

// ---- ★R9 What this script deliberately cannot do for you ----
// The approval chain starts at the Account Owner of the customer a guest belongs to, reached
// through Event_Attendee__c.Contact__c. This script creates no Account and no Contact — that
// invariant is what makes it safe to run in an org full of real ones — so the attendees above
// arrive with no customer behind them and cannot be submitted for approval yet.
//
// ★R12 There are now two ways to link them, and the import is the better one. Create Accounts
// whose AccountNumber matches the codes above (CUST-0042, CUST-0077) with Contacts whose Email
// matches, then re-upload demo-data/FinTech_Summit_2026_Attendees.csv — the import links them
// for you and the whole matched path is demonstrated rather than described. By hand, still:
//
//   update new Event_Attendee__c(Id = '<attendee id>', Contact__c = '<contact id>');
//
// Nothing here should create those Accounts either. Which customers the demo uses, and which
// account holds guests who are nobody's customer, are decisions for whoever owns the org's data.
System.debug('Seed complete. Attendees now in the org: ' + [SELECT COUNT() FROM Event_Attendee__c]);
System.debug('★R9 Approval routes: Account Owner -> their manager -> theirs, stopping at a Regional Head.');
System.debug('★R9 An attendee with no Contact link has no Account Owner and cannot be submitted at all.');
