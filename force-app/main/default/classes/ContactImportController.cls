/**
 * Screen 1 — Import External Contact List.
 * The LWC parses the .csv client-side and sends rows here.
 * Matching key: Email (case-insensitive). Classification precedence:
 * SKIPPED > COMPANY_CHANGE > UPDATE > UNCHANGED. In-file de-dup happens client-side.
 *
 * A row whose Company matches no Account becomes a **Lead**, not a Contact. An
 * Account is a transacting customer by definition, so an unmatched company name is
 * itself the evidence that this person is not attached to one — which is precisely
 * what a Lead is for. This replaced a "PoC Unassigned" bucket Account that existed
 * only because the earlier model had nowhere else to put these people.
 *
 * PoC note: DML runs in system mode by design — Status/snapshot fields are
 * FLS-read-only for users and only mutated through these controllers.
 */
public with sharing class ContactImportController {
    public static final Integer MAX_ROWS = 500;
    public static final String LEAD_SOURCE = 'Event Import';

    public class ImportRow {
        @AuraEnabled
        public String firstName { get; set; }
        @AuraEnabled
        public String lastName { get; set; }
        @AuraEnabled
        public String email { get; set; }
        @AuraEnabled
        public String title { get; set; }
        @AuraEnabled
        public String company { get; set; }
        @AuraEnabled
        public String mobile { get; set; }
    }

    public class PreviewResult {
        @AuraEnabled
        public ImportRow row { get; set; }
        // NEW_CONTACT | NEW_LEAD | UPDATE | UPDATE_LEAD | UNCHANGED | COMPANY_CHANGE | SKIPPED
        @AuraEnabled
        public String classification { get; set; }
        @AuraEnabled
        public String reason { get; set; } // for SKIPPED / COMPANY_CHANGE / NEW_LEAD
        @AuraEnabled
        public Id contactId { get; set; }
        @AuraEnabled
        public Id leadId { get; set; }
        @AuraEnabled
        public List<String> changes { get; set; } // human-readable "Title: Manager → Senior Manager"
    }

    public class ApplyResult {
        @AuraEnabled
        public Integer created { get; set; }
        @AuraEnabled
        public Integer updated { get; set; }
        @AuraEnabled
        public Integer leadsCreated { get; set; }
        @AuraEnabled
        public Integer leadsUpdated { get; set; }
    }

    @AuraEnabled
    public static List<PreviewResult> previewMatches(List<ImportRow> rows) {
        if (rows == null || rows.isEmpty()) {
            throw new AuraHandledException('No rows to preview.');
        }
        if (rows.size() > MAX_ROWS) {
            throw new AuraHandledException('File exceeds the ' + MAX_ROWS + '-row PoC limit. Please split the file.');
        }
        return classify(rows);
    }

    @AuraEnabled
    public static ApplyResult applyChanges(List<ImportRow> rows) {
        if (rows == null || rows.isEmpty()) {
            throw new AuraHandledException('No rows to apply.');
        }
        if (rows.size() > MAX_ROWS) {
            throw new AuraHandledException('File exceeds the ' + MAX_ROWS + '-row PoC limit. Please split the file.');
        }
        // Server-side re-classification — never trust client classification for DML.
        List<PreviewResult> results = classify(rows);

        List<Contact> toInsert = new List<Contact>();
        List<Contact> toUpdate = new List<Contact>();
        List<Lead> leadsToInsert = new List<Lead>();
        List<Lead> leadsToUpdate = new List<Lead>();
        Set<String> newCompanyNames = new Set<String>();

        for (PreviewResult pr : results) {
            if (pr.classification == 'NEW_CONTACT' && String.isNotBlank(pr.row.company)) {
                newCompanyNames.add(pr.row.company.trim());
            }
        }
        Map<String, Id> accountIdByName = resolveAccounts(newCompanyNames);

        for (PreviewResult pr : results) {
            if (pr.classification == 'NEW_CONTACT') {
                toInsert.add(
                    new Contact(
                        FirstName = pr.row.firstName,
                        LastName = pr.row.lastName,
                        Email = pr.row.email == null ? null : pr.row.email.trim(),
                        Title = pr.row.title,
                        MobilePhone = pr.row.mobile,
                        AccountId = accountIdByName.get(pr.row.company.trim().toLowerCase())
                    )
                );
            } else if (pr.classification == 'NEW_LEAD') {
                leadsToInsert.add(
                    new Lead(
                        FirstName = pr.row.firstName,
                        LastName = pr.row.lastName,
                        Email = pr.row.email == null ? null : pr.row.email.trim(),
                        Title = pr.row.title,
                        MobilePhone = pr.row.mobile,
                        // Company is required on Lead and is free text — the university
                        // or agency name lands here without an Account existing for it.
                        Company = String.isNotBlank(pr.row.company) ? pr.row.company.trim() : 'Unaffiliated',
                        LeadSource = LEAD_SOURCE
                    )
                );
            } else if (pr.classification == 'UPDATE') {
                Contact c = new Contact(Id = pr.contactId);
                if (String.isNotBlank(pr.row.title)) {
                    c.Title = pr.row.title;
                }
                if (String.isNotBlank(pr.row.mobile)) {
                    c.MobilePhone = pr.row.mobile;
                }
                toUpdate.add(c);
            } else if (pr.classification == 'UPDATE_LEAD') {
                Lead l = new Lead(Id = pr.leadId);
                if (String.isNotBlank(pr.row.title)) {
                    l.Title = pr.row.title;
                }
                if (String.isNotBlank(pr.row.mobile)) {
                    l.MobilePhone = pr.row.mobile;
                }
                leadsToUpdate.add(l);
            }
            // UNCHANGED, COMPANY_CHANGE, SKIPPED: never applied here.
        }

        if (!toInsert.isEmpty()) {
            insert toInsert;
        }
        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
        if (!leadsToInsert.isEmpty()) {
            insert leadsToInsert;
        }
        if (!leadsToUpdate.isEmpty()) {
            update leadsToUpdate;
        }

        ApplyResult res = new ApplyResult();
        res.created = toInsert.size();
        res.updated = toUpdate.size();
        res.leadsCreated = leadsToInsert.size();
        res.leadsUpdated = leadsToUpdate.size();
        return res;
    }

    // ---------- internals ----------

    private static List<PreviewResult> classify(List<ImportRow> rows) {
        Set<String> emails = new Set<String>();
        for (ImportRow r : rows) {
            if (r.email != null && String.isNotBlank(r.email)) {
                emails.add(r.email.trim().toLowerCase());
            }
        }

        Map<String, Contact> contactByEmail = new Map<String, Contact>();
        if (!emails.isEmpty()) {
            for (Contact c : [
                SELECT Id, Email, Title, MobilePhone, AccountId, Account.Name
                FROM Contact
                WHERE Email IN :emails
            ]) {
                String key = c.Email == null ? null : c.Email.trim().toLowerCase();
                // First match wins if org data itself has duplicate emails.
                if (key != null && !contactByEmail.containsKey(key)) {
                    contactByEmail.put(key, c);
                }
            }
        }

        // Leads are consulted only for emails no Contact matched — a person who is
        // already a customer Contact is not also a Lead as far as this import cares.
        Map<String, Lead> leadByEmail = new Map<String, Lead>();
        if (!emails.isEmpty()) {
            for (Lead l : [
                SELECT Id, Email, Title, MobilePhone, Company
                FROM Lead
                WHERE Email IN :emails AND IsConverted = FALSE
            ]) {
                String key = l.Email == null ? null : l.Email.trim().toLowerCase();
                if (key != null && !leadByEmail.containsKey(key)) {
                    leadByEmail.put(key, l);
                }
            }
        }

        // Which companies exist as Accounts decides Contact vs Lead for every new row.
        Set<String> companyNames = new Set<String>();
        for (ImportRow r : rows) {
            if (String.isNotBlank(r.company)) {
                companyNames.add(r.company.trim());
            }
        }
        Set<String> knownAccountNames = new Set<String>();
        if (!companyNames.isEmpty()) {
            for (Account a : [SELECT Name FROM Account WHERE Name IN :companyNames]) {
                knownAccountNames.add(a.Name.trim().toLowerCase());
            }
        }

        List<PreviewResult> results = new List<PreviewResult>();
        for (ImportRow r : rows) {
            PreviewResult pr = new PreviewResult();
            pr.row = r;
            pr.changes = new List<String>();

            String email = r.email == null ? '' : r.email.trim();
            if (String.isBlank(email) || !email.contains('@')) {
                pr.classification = 'SKIPPED';
                pr.reason = 'Missing or malformed email';
                results.add(pr);
                continue;
            }

            Contact existing = contactByEmail.get(email.toLowerCase());
            if (existing == null) {
                classifyUnmatched(pr, r, leadByEmail.get(email.toLowerCase()), knownAccountNames);
                results.add(pr);
                continue;
            }

            pr.contactId = existing.Id;
            String currentCompany = existing.Account != null ? existing.Account.Name : null;
            Boolean companyChanged =
                String.isNotBlank(r.company) &&
                String.isNotBlank(currentCompany) &&
                !r.company.trim().equalsIgnoreCase(currentCompany.trim());

            // Precedence: company change wins over field updates.
            if (companyChanged) {
                pr.classification = 'COMPANY_CHANGE';
                pr.reason = 'Company: ' + currentCompany + ' → ' + r.company + ' (manual review)';
                results.add(pr);
                continue;
            }

            if (String.isNotBlank(r.title) && !r.title.trim().equalsIgnoreCase(nullToEmpty(existing.Title).trim())) {
                pr.changes.add('Title: ' + nullToEmpty(existing.Title) + ' → ' + r.title);
            }
            if (String.isNotBlank(r.mobile) && !r.mobile.trim().equals(nullToEmpty(existing.MobilePhone).trim())) {
                pr.changes.add('Mobile: ' + nullToEmpty(existing.MobilePhone) + ' → ' + r.mobile);
            }
            pr.classification = pr.changes.isEmpty() ? 'UNCHANGED' : 'UPDATE';
            results.add(pr);
        }
        return results;
    }

    /**
     * An email that matched no Contact is either an existing Lead to update, or a new
     * person — and whether that person becomes a Contact or a Lead turns on one
     * question: does their company already exist as an Account, i.e. are we already
     * doing business with them?
     */
    private static void classifyUnmatched(
        PreviewResult pr,
        ImportRow r,
        Lead existingLead,
        Set<String> knownAccountNames
    ) {
        if (existingLead != null) {
            pr.leadId = existingLead.Id;
            if (
                String.isNotBlank(r.title) && !r.title.trim().equalsIgnoreCase(nullToEmpty(existingLead.Title).trim())
            ) {
                pr.changes.add('Title: ' + nullToEmpty(existingLead.Title) + ' → ' + r.title);
            }
            if (String.isNotBlank(r.mobile) && !r.mobile.trim().equals(nullToEmpty(existingLead.MobilePhone).trim())) {
                pr.changes.add('Mobile: ' + nullToEmpty(existingLead.MobilePhone) + ' → ' + r.mobile);
            }
            pr.classification = pr.changes.isEmpty() ? 'UNCHANGED' : 'UPDATE_LEAD';
            return;
        }

        if (String.isBlank(r.lastName)) {
            pr.classification = 'SKIPPED';
            pr.reason = 'New contact requires Last Name';
            return;
        }

        Boolean companyIsCustomer =
            String.isNotBlank(r.company) && knownAccountNames.contains(r.company.trim().toLowerCase());
        if (companyIsCustomer) {
            pr.classification = 'NEW_CONTACT';
        } else {
            pr.classification = 'NEW_LEAD';
            pr.reason = String.isBlank(r.company)
                ? 'No company given — will be created as an unaffiliated Lead'
                : '"' + r.company.trim() + '" is not a customer Account — will be created as a Lead';
        }
    }

    /** Resolves account names (case-insensitive exact match) to Ids. Names with no Account never reach here — those rows are Leads. */
    private static Map<String, Id> resolveAccounts(Set<String> companyNames) {
        Map<String, Id> byLowerName = new Map<String, Id>();
        if (companyNames.isEmpty()) {
            return byLowerName;
        }
        for (Account a : [SELECT Id, Name FROM Account WHERE Name IN :companyNames]) {
            byLowerName.put(a.Name.trim().toLowerCase(), a.Id);
        }
        return byLowerName;
    }

    private static String nullToEmpty(String s) {
        return s == null ? '' : s;
    }
}
