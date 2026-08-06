/**
 * Demo seed data for the Event Management PoC.
 * Run with:  sf apex run --file scripts/seed-demo-data.apex -o <sandbox-alias>
 *
 * Owners: set the two usernames below to real sandbox users to demo the
 * multi-owner approval split. Left blank, everything is owned by you
 * (the flow still works — you'll approve your own submissions).
 */
String OWNER_A_USERNAME = ''; // e.g. 'sarah.whitman@yourco.com.sandbox'  (Account Owner / approver)
String OWNER_B_USERNAME = ''; // e.g. 'marcus.weber@yourco.com.sandbox'   (second approver)

Id ownerA = UserInfo.getUserId();
Id ownerB = UserInfo.getUserId();
if (String.isNotBlank(OWNER_A_USERNAME)) {
    ownerA = [SELECT Id FROM User WHERE Username = :OWNER_A_USERNAME LIMIT 1].Id;
}
if (String.isNotBlank(OWNER_B_USERNAME)) {
    ownerB = [SELECT Id FROM User WHERE Username = :OWNER_B_USERNAME LIMIT 1].Id;
}

// ---- Accounts (idempotent by name) ----
Map<String, Account> wanted = new Map<String, Account>{
    'Acme Corp'      => new Account(Name = 'Acme Corp', OwnerId = ownerA),
    'Acme Insurance' => new Account(Name = 'Acme Insurance', OwnerId = ownerA),
    'Nordbank AG'    => new Account(Name = 'Nordbank AG', OwnerId = ownerB),
    'Globex'         => new Account(Name = 'Globex', OwnerId = ownerB)
};
// No bucket Account: an Account is a transacting customer, so guests without one
// are seeded as Leads below.
for (Account existing : [SELECT Id, Name FROM Account WHERE Name IN :wanted.keySet()]) {
    wanted.remove(existing.Name);
}
if (!wanted.isEmpty()) { insert wanted.values(); }

Map<String, Id> accId = new Map<String, Id>();
for (Account a : [SELECT Id, Name FROM Account WHERE Name IN ('Acme Corp','Acme Insurance','Nordbank AG','Globex')]) {
    accId.put(a.Name, a.Id);
}

// ---- Contacts (idempotent by email) ----
List<Contact> contacts = new List<Contact>{
    new Contact(FirstName='Emily',  LastName='Carter',   Email='emily.carter@acmecorp.example',  Title='Manager',          AccountId=accId.get('Acme Corp')),
    new Contact(FirstName='Robert', LastName='Kim',      Email='robert.kim@acmecorp.example',    Title='SVP, Operations',  AccountId=accId.get('Acme Corp')),
    new Contact(FirstName='Laura',  LastName='Chen',     Email='laura.chen@acmeins.example',     Title='VP, Finance',      AccountId=accId.get('Acme Insurance')),
    new Contact(FirstName='James',  LastName='Mueller',  Email='j.mueller@nordbank.example',     Title='Director',         AccountId=accId.get('Nordbank AG')),
    new Contact(FirstName='Anna',   LastName='Kowalski', Email='a.kowalski@nordbank.example',    Title='Associate',        AccountId=accId.get('Nordbank AG')),
    new Contact(FirstName='Sophie', LastName='Laurent',  Email='sophie.laurent@globex.example',  Title='CMO',              AccountId=accId.get('Globex'))
};
Set<String> emails = new Set<String>();
for (Contact c : contacts) { emails.add(c.Email); }
Set<String> existingEmails = new Set<String>();
for (Contact c : [SELECT Email FROM Contact WHERE Email IN :emails]) { existingEmails.add(c.Email); }
List<Contact> newContacts = new List<Contact>();
for (Contact c : contacts) {
    if (!existingEmails.contains(c.Email)) { newContacts.add(c); }
}
if (!newContacts.isEmpty()) { insert newContacts; }

// ---- Leads: conference guests with no customer relationship ----
// These are the people the Add Leads tab is for. They belong to institutions, not
// to Accounts, and the ladder routes their approval to the submitter's manager.
List<Lead> leads = new List<Lead>{
    new Lead(FirstName='Hélène', LastName='Dubois',    Email='h.dubois@unige.example',    Title='Professor of Cryptography', Company='Université de Genève',      LeadSource='Event Import', OwnerId=ownerA),
    new Lead(FirstName='Anke',   LastName='Weber',     Email='a.weber@tuberlin.example',  Title='Professor, Distributed Systems', Company='TU Berlin',            LeadSource='Event Import', OwnerId=ownerA),
    new Lead(FirstName='Tomas',  LastName='Lindqvist', Email='t.lindqvist@kth.example',   Title='Senior Researcher',         Company='KTH Royal Institute',       LeadSource='Event Import', OwnerId=ownerB),
    new Lead(FirstName='Priya',  LastName='Raman',     Email='p.raman@techpress.example', Title='Editor',                    Company='TechPress Media',           LeadSource='Event Import', OwnerId=ownerB)
};
Set<String> leadEmails = new Set<String>();
for (Lead l : leads) { leadEmails.add(l.Email); }
Set<String> existingLeadEmails = new Set<String>();
for (Lead l : [SELECT Email FROM Lead WHERE Email IN :leadEmails]) { existingLeadEmails.add(l.Email); }
List<Lead> newLeads = new List<Lead>();
for (Lead l : leads) {
    if (!existingLeadEmails.contains(l.Email)) { newLeads.add(l); }
}
if (!newLeads.isEmpty()) { insert newLeads; }

// ---- A sample event ----
if ([SELECT COUNT() FROM Marketing_Event__c WHERE Name = 'Q3 2026 Customer Appreciation Gala'] == 0) {
    insert new Marketing_Event__c(
        Name = 'Q3 2026 Customer Appreciation Gala',
        Event_Date__c = Date.newInstance(2026, 9, 18),
        Location__c = 'The Plaza, New York',
        Event_Type__c = 'Dinner / Gala',
        Expected_Attendees__c = 150,
        Description__c = 'Annual appreciation event for key financial-sector customers.'
    );
}

System.debug('Seed complete. Accounts: ' + accId.size() + ', new contacts: ' + newContacts.size() + ', new leads: ' + newLeads.size());
System.debug('Reminder: the approver ladder needs a Manager on each AM user, or a lead they do not own.');
