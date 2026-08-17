/**
 * Screen 1 — Import External Attendee List.
 *
 * R5 reduced this to one job: put the people in an uploaded file into
 * Event_Attendee__c. It does not read Contact, does not read Lead, and creates
 * neither — nor an Account. An imported person is an attendee and nothing else,
 * which is what makes the import safe to run against a production org: the only
 * object it can touch is one this project owns outright.
 *
 * What that removed, deliberately, is the whole R4 matching cascade. There is no
 * name → company → email narrowing any more, and therefore no AMBIGUOUS outcome
 * and no Match_Basis__c: with nothing to match against, there is nothing to be
 * uncertain about. The cost is stated rather than hidden — an attendee who is also
 * a customer Contact is now two records in the org that nothing connects, and
 * reconciling them is a job this feature no longer attempts.
 *
 * De-duplication is what is left, and Unique_Key__c is the whole of it: normalised
 * last name + first name + company + email. Re-uploading a file updates the same
 * attendees instead of cloning them. Two people who differ only in an email the
 * file does not carry collapse into one; the same person whose email changed
 * between two files becomes two. Both are consequences of choosing an identity
 * from the columns a conference list actually has.
 *
 * The LWC parses the .csv client-side and sends rows here. The Event column R4
 * required is gone with Event_History__c — an import records people, and which
 * event they are invited to is decided later, on the event, by an AM.
 *
 * One consequence of routing every row into typed fields is worth naming, because
 * R4 never faced it: a spreadsheet's Email column contains "n/a", "-" and trailing
 * notes, and Email__c is a typed Email field that refuses them. Failing a large
 * upload over one such cell would be the wrong trade, and so would silently binning
 * the address. The row keeps the person, drops the unstorable address, and says so
 * in the preview — the same "loud about what it did not do" posture the ambiguous
 * rows had in R4.
 *
 * R10 raised the row cap from 500 to 8000 and, with it, changed how a whole upload
 * reaches this class. An 8000-row file is chunked client-side (see BATCH_SIZE
 * below) into sequential calls of at most a few hundred rows each; this class never
 * sees the whole file at once. Two consequences follow. First, `applyChanges` moved
 * from an all-or-nothing `upsert` to `Database.upsert(..., false)`: with several
 * independent batches in flight, one bad row failing the whole batch it happens to
 * be in — while nine batches before it already committed — would be a confusing
 * failure mode, so a bad row is now reported and skipped instead. Second, the
 * per-call guard below no longer checks against the 8000-row total, because after
 * chunking it can't: it checks against a much smaller per-call ceiling instead. See
 * MAX_BATCH_ROWS.
 */
public with sharing class AttendeeImportController {
    /**
     * Total rows the LWC accepts in one uploaded file, chunked into BATCH_SIZE-row
     * Apex calls. Kept here, mirroring the LWC's own MAX_ROWS, purely so the two
     * numbers cannot silently drift apart — this class does not enforce it directly,
     * because after chunking a single call never sees anywhere near it. See guard().
     */
    public static final Integer MAX_ROWS = 8000;

    /**
     * Rows per Apex call. The LWC chunks a parsed file into batches of this size and
     * calls previewMatches / applyChanges once per batch, sequentially. 200 is a
     * deliberately conservative starting point — the safe ceiling has not been
     * measured against a real org's heap and CPU limits, so this errs low rather
     * than finding that ceiling in production.
     */
    public static final Integer BATCH_SIZE = 200;

    /**
     * The real per-call guard. The client is not the security boundary: chunking is
     * a client-side convention the LWC follows, not something Apex can trust, so this
     * has to hold even against a caller that skips it entirely (a modified client, or
     * a direct Apex REST / Tooling API call). Set well above BATCH_SIZE so retuning
     * the LWC's chunk size doesn't need a server redeploy, and well below MAX_ROWS so
     * one call can't reproduce the heap/CPU risk chunking exists to avoid. Also
     * unmeasured against a real org — see BATCH_SIZE.
     */
    public static final Integer MAX_BATCH_ROWS = 1000;

    // Classifications
    public static final String NEW_ATTENDEE = 'NEW_ATTENDEE';
    public static final String EXISTING_ATTENDEE = 'EXISTING_ATTENDEE';
    public static final String SKIPPED = 'SKIPPED';

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
        // NEW_ATTENDEE | EXISTING_ATTENDEE | SKIPPED
        @AuraEnabled
        public String classification { get; set; }
        @AuraEnabled
        public String reason { get; set; }
        /** Set only for EXISTING_ATTENDEE, so the preview can link to the record it will refresh. */
        @AuraEnabled
        public Id attendeeId { get; set; }
    }

    public class ApplyResult {
        @AuraEnabled
        public Integer attendeesCreated { get; set; }
        @AuraEnabled
        public Integer attendeesUpdated { get; set; }
        /** R10: how many rows in this call failed the DML, out of what was attempted. */
        @AuraEnabled
        public Integer attendeesFailed { get; set; }
        @AuraEnabled
        public List<ApplyFailure> failures { get; set; }
    }

    /** R10: one row that Database.upsert rejected, kept with enough of the row to identify the person. */
    public class ApplyFailure {
        @AuraEnabled
        public ImportRow row { get; set; }
        @AuraEnabled
        public String message { get; set; }
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

        Datetime now = Datetime.now();
        Map<String, Integer> indexByKey = new Map<String, Integer>();
        List<Event_Attendee__c> records = new List<Event_Attendee__c>();
        List<ImportRow> recordRows = new List<ImportRow>();

        for (PreviewResult pr : results) {
            if (pr.classification == SKIPPED) {
                continue;
            }
            String key = attendeeKey(pr.row);
            Event_Attendee__c rec = new Event_Attendee__c(
                Name = displayName(pr.row),
                First_Name__c = clip(pr.row.firstName, 40),
                Last_Name__c = pr.row.lastName.trim().abbreviate(80),
                Email__c = storableEmail(pr.row.email),
                Title__c = clip(pr.row.title, 128),
                Company__c = clip(pr.row.company, 255),
                Mobile__c = clip(pr.row.mobile, 40),
                Source_File__c = clip(sourceFile, 255),
                Imported_On__c = now,
                Unique_Key__c = key
            );
            // Same person twice in one file: one record, last occurrence winning. The
            // key is the map key precisely so this cannot become two rows.
            if (indexByKey.containsKey(key)) {
                Integer idx = indexByKey.get(key);
                records[idx] = rec;
                recordRows[idx] = pr.row;
            } else {
                indexByKey.put(key, records.size());
                records.add(rec);
                recordRows.add(pr.row);
            }
        }

        ApplyResult res = new ApplyResult();
        res.attendeesCreated = 0;
        res.attendeesUpdated = 0;
        res.attendeesFailed = 0;
        res.failures = new List<ApplyFailure>();

        if (!records.isEmpty()) {
            // Upsert, not insert: a re-uploaded file refreshes the attendees it names
            // rather than duplicating them. Title, mobile and source file are the fields
            // that move — the newest file wins, because this object exists to hold what
            // the files say. Company and email cannot change here: they are part of the
            // identity, so a row carrying a different one is a different attendee.
            //
            // R10: allOrNone = false. With an 8000-row import chunked into many
            // sequential calls, one row this batch cannot store (a value the platform
            // itself refuses) must not discard the rest of the batch — and it cannot
            // roll back the batches that already committed either way. What that costs
            // is real: a mid-import failure can leave the file only partly applied.
            // What makes that tolerable is Unique_Key__c: re-uploading the same file
            // after fixing the failing rows is an upsert, so it refreshes what is
            // already there rather than duplicating it. There is no rollback here —
            // the remedy is fix-and-re-upload, not undo.
            List<Database.UpsertResult> saveResults = Database.upsert(records, Event_Attendee__c.Unique_Key__c, false);
            for (Integer i = 0; i < saveResults.size(); i++) {
                Database.UpsertResult sr = saveResults[i];
                if (sr.isSuccess()) {
                    if (sr.isCreated()) {
                        res.attendeesCreated++;
                    } else {
                        res.attendeesUpdated++;
                    }
                } else {
                    res.attendeesFailed++;
                    ApplyFailure f = new ApplyFailure();
                    f.row = recordRows[i];
                    f.message = sr.getErrors().isEmpty() ? 'Unknown error' : sr.getErrors()[0].getMessage();
                    res.failures.add(f);
                }
            }
        }

        return res;
    }

    // ---------- classification ----------

    /**
     * Two outcomes and a refusal. Everything with a last name becomes an attendee;
     * the only question is whether the org already has that attendee, which is a
     * lookup on Unique_Key__c rather than any kind of judgement call.
     */
    private static List<PreviewResult> classify(List<ImportRow> rows) {
        Set<String> keys = new Set<String>();
        for (ImportRow r : rows) {
            if (String.isNotBlank(r.lastName)) {
                keys.add(attendeeKey(r));
            }
        }

        Map<String, Id> knownByKey = new Map<String, Id>();
        if (!keys.isEmpty()) {
            for (Event_Attendee__c a : [
                SELECT Id, Unique_Key__c
                FROM Event_Attendee__c
                WHERE Unique_Key__c IN :keys
            ]) {
                knownByKey.put(a.Unique_Key__c.toLowerCase(), a.Id);
            }
        }

        List<PreviewResult> results = new List<PreviewResult>();
        for (ImportRow r : rows) {
            PreviewResult pr = new PreviewResult();
            pr.row = r;

            if (String.isBlank(r.lastName)) {
                pr.classification = SKIPPED;
                pr.reason = 'No last name — an attendee with no name is unrecognisable later';
                results.add(pr);
                continue;
            }

            String key = attendeeKey(r);
            if (knownByKey.containsKey(key)) {
                pr.classification = EXISTING_ATTENDEE;
                pr.attendeeId = knownByKey.get(key);
                pr.reason = 'Already an attendee — title, mobile and source file will be refreshed';
            } else {
                pr.classification = NEW_ATTENDEE;
                pr.reason = 'Will be created as an event attendee';
            }
            // Said here rather than swallowed at write time: the person is still
            // imported, so this is a note on the row, not a reason to drop it.
            if (String.isNotBlank(r.email) && storableEmail(r.email) == null) {
                pr.reason += ' (the Email column is not an address, so it was not stored)';
            }
            results.add(pr);
        }
        return results;
    }

    // ---------- internals ----------

    private static void guard(List<ImportRow> rows, String verb) {
        if (rows == null || rows.isEmpty()) {
            throw new AuraHandledException('No rows to ' + verb + '.');
        }
        // R10: this is a per-call ceiling, not the 8000-row file cap — see
        // MAX_BATCH_ROWS. The LWC chunks a file into BATCH_SIZE-row calls well under
        // this; a call anywhere near it did not come from the LWC behaving normally.
        if (rows.size() > MAX_BATCH_ROWS) {
            throw new AuraHandledException(
                'This call exceeds the ' +
                    MAX_BATCH_ROWS +
                    '-row per-request limit. The import wizard should never send a batch this large — please re-upload the file.'
            );
        }
    }

    /**
     * The attendee's identity, and the only de-duplication in R5.
     *
     * Each part is truncated so the assembled key fits the field's 255 characters
     * (80 + 40 + 60 + 70 + 3 separators = 253). Truncating company and email can in
     * principle collide two people with very long, near-identical values — accepted
     * at PoC scale, recorded rather than hidden, same as the R4 event-name key it
     * replaces.
     */
    @TestVisible
    private static String attendeeKey(ImportRow r) {
        return normalise(r.lastName).left(80) +
            '|' +
            normalise(r.firstName).left(40) +
            '|' +
            normalise(r.company).left(60) +
            '|' +
            normalise(r.email).left(70);
    }

    /** Lower-cased, trimmed, with runs of whitespace collapsed — "Acme  Corp" is "Acme Corp". */
    private static String normalise(String s) {
        return String.isBlank(s) ? '' : s.trim().toLowerCase().replaceAll('\\s+', ' ');
    }

    /** The Name field: what a human reads on the record and in every related list. */
    private static String displayName(ImportRow r) {
        String first = String.isBlank(r.firstName) ? '' : r.firstName.trim();
        String last = r.lastName.trim();
        return (String.isBlank(first) ? last : first + ' ' + last).abbreviate(80);
    }

    /** Trimmed and cut to what the field can hold; blank becomes null, not an empty string. */
    private static String clip(String s, Integer max) {
        return String.isBlank(s) ? null : s.trim().abbreviate(max);
    }

    /**
     * An address Email__c will actually accept, or null.
     *
     * Deliberately a shape check and not RFC 5322 — the job is to keep a
     * spreadsheet's "n/a", "see below" and stray notes from failing an upsert of
     * a whole batch of people, not to adjudicate exotic-but-legal addresses.
     * Anything that looks like local@domain.tld and fits the field is kept as it
     * came.
     */
    private static String storableEmail(String s) {
        if (String.isBlank(s)) {
            return null;
        }
        String trimmed = s.trim();
        if (trimmed.length() > 80) {
            return null;
        }
        return Pattern.matches('[^@\\s]+@[^@\\s.]+\\.[^@\\s]+', trimmed) ? trimmed : null;
    }
}
