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
    new List<String>{ 'Emily',  'Carter',   'emily.carter@acmecorp.example', 'Senior Manager', 'Acme Corp' },
    new List<String>{ 'James',  'Mueller',  'j.mueller@nordbank.example',    'Director',       'Nordbank AG' },
    new List<String>{ 'Robert', 'Kim',      'robert.kim@acmecorp.example',   'SVP, Operations','Acme Corp' },
    new List<String>{ 'Hélène', 'Dubois',   'h.dubois@unige.example',        'Professor of Cryptography', 'Université de Genève' },
    new List<String>{ 'Anke',   'Weber',    'a.weber@tuberlin.example',      'Professor, Distributed Systems', 'TU Berlin' },
    new List<String>{ 'Tomas',  'Lindqvist','t.lindqvist@kth.example',       'Senior Researcher', 'KTH Royal Institute' },
    new List<String>{ 'Priya',  'Raman',    'p.raman@techpress.example',     'Editor',         'TechPress Media' }
};

List<Event_Attendee__c> attendees = new List<Event_Attendee__c>();
for (List<String> s : seed) {
    String first = s[0], last = s[1], email = s[2], title = s[3], company = s[4];
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
        Topic__c = 'Digital Banking;Payments',
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
        Topic__c = 'Payments;AI & Data',
        Expected_Attendees__c = 80,
        Description__c = 'Past event. Its attendance is what the Attendee Event History report reads.'
    );
}

System.debug('Seed complete. Attendees now in the org: ' + [SELECT COUNT() FROM Event_Attendee__c]);
System.debug('Reminder: every AM user needs a Manager set — it is the only approver the R5 ladder has.');
System.debug('★R6 Topic__c values are placeholders. Replace them with the real taxonomy before trusting a recommendation.');
