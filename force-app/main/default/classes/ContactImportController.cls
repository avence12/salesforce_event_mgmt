/**
 * Screen 1 — Import External Contact List.
 *
 * As of R4 this is an attendance log, not a reconciliation tool. It matches each CSV
 * row to a person already in the org and records that they were on the list for an
 * event. It does NOT create, update or delete Contacts, and does not edit any Contact
 * field — the only thing written against a matched Contact is an Event_History__c
 * child row. The one exception is people who match nothing at all: those become Leads,
 * because otherwise a professor invited to a conference could never enter the org.
 *
 * Matching is a narrowing cascade — name, then company, then email — replacing R3's
 * single email key. Two consequences shape the code below:
 *
 *   - A narrowing step that empties the candidate set is SKIPPED, not fatal. Someone
 *     who changed jobs still matches on name; letting a stale company column erase
 *     them would drop exactly the people a conference list is most out of date about.
 *   - "Could not tell" is a real outcome. Several candidates that cannot be separated
 *     write nothing and go to the manual-review list, rather than being guessed at.
 *
 * The LWC parses the .csv client-side and sends rows here. In-file de-duplication is
 * by name + company + email + event: an email is no longer a row's identity, and the
 * same person at two events is two facts rather than a duplicate.
 */
public with sharing class ContactImportController {
    public static final Integer MAX_ROWS = 500;
    public static final String LEAD_SOURCE = 'Event Import';

    // Classifications
    public static final String MATCHED_CONTACT = 'MATCHED_CONTACT';
    public static final String MATCHED_LEAD = 'MATCHED_LEAD';
    public static final String AMBIGUOUS = 'AMBIGUOUS';
    public static final String NEW_LEAD = 'NEW_LEAD';
    public static final String SKIPPED = 'SKIPPED';

    // Match_Basis__c picklist values
    private static final String BASIS_NAME = 'Name';
    private static final String BASIS_COMPANY = 'Name + Company';
    private static final String BASIS_EMAIL = 'Name + Company + Email';
    private static final String BASIS_CREATED = 'Created by import';

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
        @AuraEnabled
        public String event { get; set; }
    }

    public class PreviewResult {
        @AuraEnabled
        public ImportRow row { get; set; }
        // MATCHED_CONTACT | MATCHED_LEAD | AMBIGUOUS | NEW_LEAD | SKIPPED
        @AuraEnabled
        public String classification { get; set; }
        @AuraEnabled
        public String reason { get; set; }
        @AuraEnabled
        public Id contactId { get; set; }
        @AuraEnabled
        public Id leadId { get; set; }
        @AuraEnabled
        public String matchBasis { get; set; }
        /** Names of the people an ambiguous row could not be separated between. */
        @AuraEnabled
        public List<String> candidates { get; set; }
    }

    public class ApplyResult {
        @AuraEnabled
        public Integer tagsRecorded { get; set; }
        @AuraEnabled
        public Integer leadsCreated { get; set; }
    }

    @AuraEnabled
    public static List<PreviewResult> previewMatches(List<ImportRow> rows) {
        guard(rows, 'preview');
        return classify(rows);
    }

    @AuraEnabled
    public static ApplyResult applyChanges(List<ImportRow> rows, String sourceFile) {
        guard(rows, 'apply');
        // Server-side re-classification. The blast radius is small now, but "the client
        // tells the server which record to write against" is a shape worth never having.
        List<PreviewResult> results = classify(rows);

        // Leads first: their Ids have to exist before anything can be tagged against them.
        List<Lead> newLeads = new List<Lead>();
        List<PreviewResult> newLeadRows = new List<PreviewResult>();
        for (PreviewResult pr : results) {
            if (pr.classification == NEW_LEAD) {
                newLeads.add(
                    new Lead(
                        FirstName = pr.row.firstName,
                        LastName = pr.row.lastName,
                        Email = blankToNull(pr.row.email),
                        Title = pr.row.title,
                        MobilePhone = pr.row.mobile,
                        // Company is required on Lead and is free text, so the university
                        // or agency name lands here without an Account existing for it.
                        Company = String.isNotBlank(pr.row.company) ? pr.row.company.trim() : 'Unaffiliated',
                        LeadSource = LEAD_SOURCE
                    )
                );
                newLeadRows.add(pr);
            }
        }
        if (!newLeads.isEmpty()) {
            insert newLeads;
            for (Integer i = 0; i < newLeads.size(); i++) {
                newLeadRows[i].leadId = newLeads[i].Id;
                newLeadRows[i].matchBasis = BASIS_CREATED;
            }
        }

        // One history row per identified person, keyed so a re-run is a no-op.
        Map<String, Event_History__c> byKey = new Map<String, Event_History__c>();
        for (PreviewResult pr : results) {
            Id personId = pr.contactId != null ? pr.contactId : pr.leadId;
            if (personId == null || pr.classification == AMBIGUOUS || pr.classification == SKIPPED) {
                continue;
            }
            String key = historyKey(personId, pr.row.event);
            // Same person, same event, twice in one file: one row, not two.
            byKey.put(
                key,
                new Event_History__c(
                    Contact__c = pr.contactId,
                    Lead__c = pr.contactId == null ? pr.leadId : null,
                    Event_Name__c = pr.row.event.trim(),
                    Imported_On__c = Datetime.now(),
                    Source_File__c = sourceFile,
                    Match_Basis__c = pr.matchBasis,
                    Unique_Key__c = key
                )
            );
        }
        if (!byKey.isEmpty()) {
            upsert byKey.values() Unique_Key__c;
        }

        ApplyResult res = new ApplyResult();
        res.tagsRecorded = byKey.size();
        res.leadsCreated = newLeads.size();
        return res;
    }

    // ---------- matching ----------

    /**
     * A person the cascade can narrow, flattened out of Contact or Lead so one
     * implementation serves both passes.
     */
    private class Candidate {
        Id recordId;
        Boolean isLead;
        String firstName;
        String lastName;
        String email;
        String org;
        String displayName;
    }

    private class Outcome {
        Candidate hit;
        String basis;
        List<Candidate> tied;
    }

    private static List<PreviewResult> classify(List<ImportRow> rows) {
        Set<String> lastNames = new Set<String>();
        for (ImportRow r : rows) {
            if (String.isNotBlank(r.lastName)) {
                lastNames.add(r.lastName.trim());
            }
        }

        List<Candidate> contactPool = contactCandidates(lastNames);
        List<Candidate> leadPool = leadCandidates(lastNames);

        List<PreviewResult> results = new List<PreviewResult>();
        for (ImportRow r : rows) {
            PreviewResult pr = new PreviewResult();
            pr.row = r;
            pr.candidates = new List<String>();

            if (String.isBlank(r.lastName)) {
                pr.classification = SKIPPED;
                pr.reason = 'No last name — nothing to match on';
                results.add(pr);
                continue;
            }
            if (String.isBlank(r.event)) {
                pr.classification = SKIPPED;
                pr.reason = 'No event value — there is nothing to tag this person with';
                results.add(pr);
                continue;
            }

            // Contacts first: a customer Contact outranks a Lead for the same person.
            Outcome contactMatch = resolve(contactPool, r);
            if (contactMatch.hit != null) {
                pr.classification = MATCHED_CONTACT;
                pr.contactId = contactMatch.hit.recordId;
                pr.matchBasis = contactMatch.basis;
                results.add(pr);
                continue;
            }
            if (contactMatch.tied != null) {
                ambiguous(pr, contactMatch.tied, 'contacts');
                results.add(pr);
                continue;
            }

            Outcome leadMatch = resolve(leadPool, r);
            if (leadMatch.hit != null) {
                pr.classification = MATCHED_LEAD;
                pr.leadId = leadMatch.hit.recordId;
                pr.matchBasis = leadMatch.basis;
                results.add(pr);
                continue;
            }
            if (leadMatch.tied != null) {
                ambiguous(pr, leadMatch.tied, 'leads');
                results.add(pr);
                continue;
            }

            pr.classification = NEW_LEAD;
            pr.reason = 'Nobody in the org matches — will be created as a Lead';
            results.add(pr);
        }
        return results;
    }

    /**
     * The narrowing cascade: name, then company, then email, each step working on what
     * the last one left. A step that would empty the set is skipped — see the class
     * comment for why that is deliberate rather than sloppy.
     */
    private static Outcome resolve(List<Candidate> pool, ImportRow r) {
        Outcome out = new Outcome();

        List<Candidate> byName = new List<Candidate>();
        for (Candidate c : pool) {
            if (!eq(c.lastName, r.lastName)) {
                continue;
            }
            // A blank first name in the file narrows nothing; it must not exclude either.
            if (String.isNotBlank(r.firstName) && !eq(c.firstName, r.firstName)) {
                continue;
            }
            byName.add(c);
        }
        if (byName.isEmpty()) {
            return out; // no hit, no tie — caller falls through
        }
        if (byName.size() == 1) {
            out.hit = byName[0];
            out.basis = BASIS_NAME;
            return out;
        }

        List<Candidate> byCompany = narrowBy(byName, r.company, true);
        if (byCompany.size() == 1) {
            out.hit = byCompany[0];
            out.basis = BASIS_COMPANY;
            return out;
        }

        List<Candidate> byEmail = narrowBy(byCompany, r.email, false);
        if (byEmail.size() == 1) {
            out.hit = byEmail[0];
            out.basis = BASIS_EMAIL;
            return out;
        }

        out.tied = byEmail;
        return out;
    }

    /**
     * Narrows on one field. Returns the previous set untouched when the value is blank
     * (the criterion says nothing) or when nothing matches (the criterion is wrong, not
     * the person) — the two cases the cascade deliberately treats the same way.
     */
    private static List<Candidate> narrowBy(List<Candidate> candidates, String value, Boolean onOrg) {
        if (String.isBlank(value)) {
            return candidates;
        }
        List<Candidate> kept = new List<Candidate>();
        for (Candidate c : candidates) {
            if (eq(onOrg ? c.org : c.email, value)) {
                kept.add(c);
            }
        }
        return kept.isEmpty() ? candidates : kept;
    }

    private static void ambiguous(PreviewResult pr, List<Candidate> tied, String noun) {
        pr.classification = AMBIGUOUS;
        for (Candidate c : tied) {
            pr.candidates.add(c.displayName);
        }
        pr.reason = 'Matches ' + tied.size() + ' ' + noun + ' and could not be narrowed further — nothing was written';
    }

    private static List<Candidate> contactCandidates(Set<String> lastNames) {
        List<Candidate> out = new List<Candidate>();
        if (lastNames.isEmpty()) {
            return out;
        }
        // LastName is indexed; filtering the compound Name field across 500 values is
        // neither indexed nor reliably selective.
        for (Contact c : [
            SELECT Id, FirstName, LastName, Name, Email, Account.Name
            FROM Contact
            WHERE LastName IN :lastNames
        ]) {
            Candidate cand = new Candidate();
            cand.recordId = c.Id;
            cand.isLead = false;
            cand.firstName = c.FirstName;
            cand.lastName = c.LastName;
            cand.email = c.Email;
            cand.org = c.Account != null ? c.Account.Name : null;
            cand.displayName = c.Name + (cand.org == null ? '' : ' (' + cand.org + ')');
            out.add(cand);
        }
        return out;
    }

    private static List<Candidate> leadCandidates(Set<String> lastNames) {
        List<Candidate> out = new List<Candidate>();
        if (lastNames.isEmpty()) {
            return out;
        }
        // Converted leads are skipped: their Contact will have matched on the first pass.
        for (Lead l : [
            SELECT Id, FirstName, LastName, Name, Email, Company
            FROM Lead
            WHERE LastName IN :lastNames AND IsConverted = FALSE
        ]) {
            Candidate cand = new Candidate();
            cand.recordId = l.Id;
            cand.isLead = true;
            cand.firstName = l.FirstName;
            cand.lastName = l.LastName;
            cand.email = l.Email;
            cand.org = l.Company;
            cand.displayName = l.Name + ' (' + l.Company + ', lead)';
            out.add(cand);
        }
        return out;
    }

    // ---------- internals ----------

    private static void guard(List<ImportRow> rows, String verb) {
        if (rows == null || rows.isEmpty()) {
            throw new AuraHandledException('No rows to ' + verb + '.');
        }
        if (rows.size() > MAX_ROWS) {
            throw new AuraHandledException('File exceeds the ' + MAX_ROWS + '-row PoC limit. Please split the file.');
        }
    }

    /** Trimmed, case-insensitive equality; blank never equals blank. */
    private static Boolean eq(String a, String b) {
        if (String.isBlank(a) || String.isBlank(b)) {
            return false;
        }
        return a.trim().equalsIgnoreCase(b.trim());
    }

    @TestVisible
    private static String historyKey(Id personId, String eventName) {
        String normalised = eventName.trim().toLowerCase().replaceAll('\\s+', ' ');
        // The field holds 200; an Id is 18. Truncating a very long event name can in
        // principle collide two events — acceptable at PoC scale, noted rather than hidden.
        return String.valueOf(personId) + '-' + normalised.left(180);
    }

    private static String blankToNull(String s) {
        return String.isBlank(s) ? null : s.trim();
    }
}
