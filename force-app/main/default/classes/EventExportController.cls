/**
 * Export approved invitees as CSV — either one event (`exportApproved`) or every
 * event the running user can see (`exportAllApproved`).
 *
 * Both queries include BOTH Approved and Exported rows so re-export always returns
 * the full approved list; first export flips Approved → Exported (Exported_Count__c
 * roll-up keeps the event page honest).
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

    public class ExportResult {
        @AuraEnabled public String csv { get; set; }
        @AuraEnabled public String fileName { get; set; }
        @AuraEnabled public Integer rowCount { get; set; }
        @AuraEnabled public Integer eventCount { get; set; }
        /** True when the row cap cut the export short — the UI warns instead of silently under-delivering. */
        @AuraEnabled public Boolean truncated { get; set; }
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
     * `mineOnly` restricts to invitees the running user added (their own batch).
     */
    @AuraEnabled(cacheable=true)
    public static List<ApprovedSummary> getApprovedSummary(Boolean mineOnly) {
        Id me = UserInfo.getUserId();
        List<AggregateResult> grouped = (mineOnly == true)
            ? [
                SELECT Marketing_Event__c evtId, Status__c st, COUNT(Id) cnt
                FROM Event_Invitee__c
                WHERE Status__c IN ('Approved', 'Exported') AND Added_By__c = :me
                GROUP BY Marketing_Event__c, Status__c
              ]
            : [
                SELECT Marketing_Event__c evtId, Status__c st, COUNT(Id) cnt
                FROM Event_Invitee__c
                WHERE Status__c IN ('Approved', 'Exported')
                GROUP BY Marketing_Event__c, Status__c
              ];

        Map<Id, ApprovedSummary> byEvent = new Map<Id, ApprovedSummary>();
        for (AggregateResult ar : grouped) {
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

    /** Approved list for a single event (Event page button). */
    @AuraEnabled
    public static ExportResult exportApproved(Id eventId) {
        Marketing_Event__c evt = [SELECT Id, Name FROM Marketing_Event__c WHERE Id = :eventId];

        List<Event_Invitee__c> rows = [
            SELECT Id, Status__c, Decided_At__c,
                   Contact__r.Name, Contact__r.Title, Contact__r.Email,
                   Account__r.Name, Account_Owner__r.Name
            FROM Event_Invitee__c
            WHERE Marketing_Event__c = :eventId
              AND Status__c IN ('Approved', 'Exported')
            ORDER BY Account__r.Name, Contact__r.Name
            LIMIT :rowLimit
        ];
        if (rows.isEmpty()) {
            throw new AuraHandledException('No approved invitees to export yet.');
        }

        ExportResult res = build(rows, false);
        res.fileName = slug(evt.Name) + '_approved_contacts.csv';
        res.eventCount = 1;
        return res;
    }

    /**
     * Every approved invitee across every event the user can see, one file.
     * `mineOnly` restricts to invitees the running user added.
     */
    @AuraEnabled
    public static ExportResult exportAllApproved(Boolean mineOnly) {
        Id me = UserInfo.getUserId();
        List<Event_Invitee__c> rows = (mineOnly == true)
            ? [
                SELECT Id, Status__c, Decided_At__c, Marketing_Event__c,
                       Marketing_Event__r.Name, Marketing_Event__r.Event_Date__c,
                       Contact__r.Name, Contact__r.Title, Contact__r.Email,
                       Account__r.Name, Account_Owner__r.Name
                FROM Event_Invitee__c
                WHERE Status__c IN ('Approved', 'Exported') AND Added_By__c = :me
                ORDER BY Marketing_Event__r.Event_Date__c NULLS LAST, Marketing_Event__r.Name,
                         Account__r.Name, Contact__r.Name
                LIMIT :rowLimit
              ]
            : [
                SELECT Id, Status__c, Decided_At__c, Marketing_Event__c,
                       Marketing_Event__r.Name, Marketing_Event__r.Event_Date__c,
                       Contact__r.Name, Contact__r.Title, Contact__r.Email,
                       Account__r.Name, Account_Owner__r.Name
                FROM Event_Invitee__c
                WHERE Status__c IN ('Approved', 'Exported')
                ORDER BY Marketing_Event__r.Event_Date__c NULLS LAST, Marketing_Event__r.Name,
                         Account__r.Name, Contact__r.Name
                LIMIT :rowLimit
              ];
        if (rows.isEmpty()) {
            throw new AuraHandledException(
                (mineOnly == true)
                    ? 'No approved invitees of yours to export yet.'
                    : 'No approved invitees to export yet.');
        }

        Set<Id> events = new Set<Id>();
        for (Event_Invitee__c inv : rows) { events.add(inv.Marketing_Event__c); }

        ExportResult res = build(rows, true);
        res.fileName = 'all_approved_contacts_' + Datetime.now().format('yyyyMMdd', 'GMT') + '.csv';
        res.eventCount = events.size();
        return res;
    }

    /**
     * Shared CSV writer. Also flips the Approved rows in `rows` to Exported, so a
     * cross-event download marks everything it actually delivered.
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

    private static String slug(String name) {
        return name.replaceAll('[^a-zA-Z0-9 _-]', '').replace(' ', '_');
    }

    private static String csvCell(String value) {
        if (value == null) { return ''; }
        if (value.contains(',') || value.contains('"') || value.contains('\n') || value.contains('\r')) {
            return '"' + value.replace('"', '""') + '"';
        }
        return value;
    }
}
