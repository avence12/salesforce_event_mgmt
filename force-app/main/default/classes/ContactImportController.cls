/**
 * Screen 1 — Import External Contact List.
 * The LWC parses the .xlsx client-side (SheetJS) and sends rows here.
 * Matching key: Email (case-insensitive). Classification precedence:
 * SKIPPED > COMPANY_CHANGE > UPDATE > UNCHANGED. In-file de-dup happens client-side.
 *
 * PoC note: DML runs in system mode by design — Status/snapshot fields are
 * FLS-read-only for users and only mutated through these controllers.
 */
public with sharing class ContactImportController {

    public static final Integer MAX_ROWS = 500;
    public static final String BUCKET_ACCOUNT_NAME = 'PoC Unassigned';

    public class ImportRow {
        @AuraEnabled public String firstName { get; set; }
        @AuraEnabled public String lastName { get; set; }
        @AuraEnabled public String email { get; set; }
        @AuraEnabled public String title { get; set; }
        @AuraEnabled public String company { get; set; }
        @AuraEnabled public String mobile { get; set; }
    }

    public class PreviewResult {
        @AuraEnabled public ImportRow row { get; set; }
        @AuraEnabled public String classification { get; set; } // NEW_CONTACT | UPDATE | UNCHANGED | COMPANY_CHANGE | SKIPPED
        @AuraEnabled public String reason { get; set; }         // for SKIPPED / COMPANY_CHANGE
        @AuraEnabled public Id contactId { get; set; }
        @AuraEnabled public List<String> changes { get; set; }  // human-readable "Title: Manager → Senior Manager"
    }

    public class ApplyResult {
        @AuraEnabled public Integer created { get; set; }
        @AuraEnabled public Integer updated { get; set; }
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
        Set<String> newCompanyNames = new Set<String>();

        for (PreviewResult pr : results) {
            if (pr.classification == 'NEW_CONTACT' && String.isNotBlank(pr.row.company)) {
                newCompanyNames.add(pr.row.company.trim());
            }
        }
        Map<String, Id> accountIdByName = resolveAccounts(newCompanyNames);

        for (PreviewResult pr : results) {
            if (pr.classification == 'NEW_CONTACT') {
                Id accId = String.isNotBlank(pr.row.company)
                    ? accountIdByName.get(pr.row.company.trim().toLowerCase())
                    : accountIdByName.get(BUCKET_ACCOUNT_NAME.toLowerCase());
                toInsert.add(new Contact(
                    FirstName = pr.row.firstName,
                    LastName = pr.row.lastName,
                    Email = pr.row.email == null ? null : pr.row.email.trim(),
                    Title = pr.row.title,
                    MobilePhone = pr.row.mobile,
                    AccountId = accId
                ));
            } else if (pr.classification == 'UPDATE') {
                Contact c = new Contact(Id = pr.contactId);
                if (String.isNotBlank(pr.row.title)) { c.Title = pr.row.title; }
                if (String.isNotBlank(pr.row.mobile)) { c.MobilePhone = pr.row.mobile; }
                toUpdate.add(c);
            }
            // UNCHANGED, COMPANY_CHANGE, SKIPPED: never applied here.
        }

        if (!toInsert.isEmpty()) { insert toInsert; }
        if (!toUpdate.isEmpty()) { update toUpdate; }

        ApplyResult res = new ApplyResult();
        res.created = toInsert.size();
        res.updated = toUpdate.size();
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
                if (String.isBlank(r.lastName)) {
                    pr.classification = 'SKIPPED';
                    pr.reason = 'New contact requires Last Name';
                } else {
                    pr.classification = 'NEW_CONTACT';
                }
                results.add(pr);
                continue;
            }

            pr.contactId = existing.Id;
            String currentCompany = existing.Account != null ? existing.Account.Name : null;
            Boolean companyChanged = String.isNotBlank(r.company)
                && String.isNotBlank(currentCompany)
                && !r.company.trim().equalsIgnoreCase(currentCompany.trim());

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

    /** Resolves account names (case-insensitive exact match) to Ids; unmatched names fall back to the bucket account, created on demand. */
    private static Map<String, Id> resolveAccounts(Set<String> companyNames) {
        Map<String, Id> byLowerName = new Map<String, Id>();
        Set<String> allNames = new Set<String>(companyNames);
        allNames.add(BUCKET_ACCOUNT_NAME);

        for (Account a : [SELECT Id, Name FROM Account WHERE Name IN :allNames]) {
            byLowerName.put(a.Name.trim().toLowerCase(), a.Id);
        }

        Id bucketId = byLowerName.get(BUCKET_ACCOUNT_NAME.toLowerCase());
        if (bucketId == null) {
            Account bucket = new Account(Name = BUCKET_ACCOUNT_NAME);
            insert bucket;
            bucketId = bucket.Id;
            byLowerName.put(BUCKET_ACCOUNT_NAME.toLowerCase(), bucketId);
        }
        // Unmatched companies map to the bucket (row keeps its company text for later manual fix).
        for (String name : companyNames) {
            String key = name.trim().toLowerCase();
            if (!byLowerName.containsKey(key)) {
                byLowerName.put(key, bucketId);
            }
        }
        return byLowerName;
    }

    private static String nullToEmpty(String s) {
        return s == null ? '' : s;
    }
}
