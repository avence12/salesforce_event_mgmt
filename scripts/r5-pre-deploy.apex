/**
 * R5 migration — run ONCE, against an org that already has R3 or R4, AFTER the
 * source deploy and BEFORE the destructive manifests.
 *
 *   sf apex run --file scripts/r5-pre-deploy.apex -o poc-sandbox
 *
 * Why the ordering is not negotiable: this script is the only thing that carries
 * "who was this invitee?" across the revision. `destructiveChangesPre.xml` drops
 * `Event_Invitee__c.Contact__c` and `Lead__c`, and once they are gone every
 * un-migrated invitee points at nobody, permanently and unrecoverably.
 *
 * What it does:
 *   1. For every invitee still carrying a Contact or a Lead, create (or reuse) an
 *      `Event_Attendee__c` for that person.
 *   2. Back-fill `Event_Invitee__c.Event_Attendee__c`.
 *
 * It is idempotent: attendees are upserted on `Unique_Key__c` and only invitees
 * whose `Event_Attendee__c` is still blank are touched. Re-running it is safe.
 *
 * NOTE this script references Contact__c and Lead__c, which the R5 source no longer
 * contains. That is deliberate — it is anonymous Apex run against an org where those
 * fields still exist, and it must be run before they are deleted. It will not
 * compile after the destructive manifests have run, which is the correct behaviour:
 * by then there is nothing left for it to do.
 *
 * The key built here must match AttendeeImportController.attendeeKey exactly, or a
 * later import will create second copies of everybody this script migrated.
 */

String norm(String s) {
    return String.isBlank(s) ? '' : s.trim().toLowerCase().replaceAll('\\s+', ' ');
}
String keyOf(String last, String first, String company, String email) {
    return norm(last).left(80) + '|' + norm(first).left(40) + '|' + norm(company).left(60) + '|' + norm(email).left(70);
}
String clip(String s, Integer max) {
    return String.isBlank(s) ? null : s.trim().abbreviate(max);
}
// Email__c is a typed field. An address the org already holds is normally fine, but
// a hand-entered Contact can carry junk too, and one bad row must not fail the
// migration for everybody else.
String storableEmail(String s) {
    if (String.isBlank(s)) { return null; }
    String t = s.trim();
    if (t.length() > 80) { return null; }
    return Pattern.matches('[^@\\s]+@[^@\\s.]+\\.[^@\\s]+', t) ? t : null;
}

List<Event_Invitee__c> toMigrate = Database.query(
    'SELECT Id, Contact__c, Contact__r.FirstName, Contact__r.LastName, Contact__r.Email, ' +
    'Contact__r.Title, Contact__r.Account.Name, ' +
    'Lead__c, Lead__r.FirstName, Lead__r.LastName, Lead__r.Email, Lead__r.Title, ' +
    'Lead__r.Company, Lead__r.MobilePhone ' +
    'FROM Event_Invitee__c WHERE Event_Attendee__c = NULL LIMIT 10000'
);
System.debug('Invitees to migrate: ' + toMigrate.size());

Map<String, Event_Attendee__c> byKey = new Map<String, Event_Attendee__c>();
Map<Id, String> keyByInvitee = new Map<Id, String>();

for (Event_Invitee__c inv : toMigrate) {
    String first, last, email, title, company, mobile;
    if (inv.Contact__c != null) {
        first = inv.Contact__r.FirstName;
        last = inv.Contact__r.LastName;
        email = inv.Contact__r.Email;
        title = inv.Contact__r.Title;
        // The Account name becomes plain text on the attendee. That is the whole
        // point of R5 and also the moment the link to the customer record is cut —
        // export Event_Invitee__c with its Contact ids first if you may want it back.
        company = inv.Contact__r.Account != null ? inv.Contact__r.Account.Name : null;
    } else if (inv.Lead__c != null) {
        first = inv.Lead__r.FirstName;
        last = inv.Lead__r.LastName;
        email = inv.Lead__r.Email;
        title = inv.Lead__r.Title;
        company = inv.Lead__r.Company;
        mobile = inv.Lead__r.MobilePhone;
    } else {
        // Neither head set. Should be impossible under the old XOR rule, but an
        // orphan here would fail Invitee_Requires_Attendee later with no clue why.
        System.debug(LoggingLevel.WARN, 'Invitee with neither Contact nor Lead, skipped: ' + inv.Id);
        continue;
    }
    if (String.isBlank(last)) {
        System.debug(LoggingLevel.WARN, 'Invitee whose person has no last name, skipped: ' + inv.Id);
        continue;
    }

    String key = keyOf(last, first, company, email);
    keyByInvitee.put(inv.Id, key);
    byKey.put(key, new Event_Attendee__c(
        Name = (String.isBlank(first) ? last.trim() : first.trim() + ' ' + last.trim()).abbreviate(80),
        First_Name__c = clip(first, 40),
        Last_Name__c = last.trim().abbreviate(80),
        Email__c = storableEmail(email),
        Title__c = clip(title, 128),
        Company__c = clip(company, 255),
        Mobile__c = clip(mobile, 40),
        Source_File__c = 'r5-pre-deploy.apex',
        Imported_On__c = Datetime.now(),
        Unique_Key__c = key
    ));
}

if (!byKey.isEmpty()) {
    upsert byKey.values() Unique_Key__c;
}
System.debug('Attendees upserted: ' + byKey.size());

Map<String, Id> idByKey = new Map<String, Id>();
for (Event_Attendee__c a : [SELECT Id, Unique_Key__c FROM Event_Attendee__c WHERE Unique_Key__c IN :byKey.keySet()]) {
    idByKey.put(a.Unique_Key__c.toLowerCase(), a.Id);
}

List<Event_Invitee__c> updates = new List<Event_Invitee__c>();
for (Event_Invitee__c inv : toMigrate) {
    String key = keyByInvitee.get(inv.Id);
    if (key != null && idByKey.containsKey(key)) {
        updates.add(new Event_Invitee__c(Id = inv.Id, Event_Attendee__c = idByKey.get(key)));
    }
}
if (!updates.isEmpty()) {
    update updates;
}

System.debug('Invitees back-filled: ' + updates.size());
System.debug('Invitees still without an attendee (must be zero before the destructive deploy): ' +
    Database.countQuery('SELECT COUNT() FROM Event_Invitee__c WHERE Event_Attendee__c = NULL'));
