/**
 * Export Approved List (CSV). Query includes BOTH Approved and Exported rows so
 * re-export always returns the full approved list; first export flips
 * Approved → Exported (Exported_Count__c roll-up keeps the event page honest).
 */
public with sharing class EventExportController {

    public class ExportResult {
        @AuraEnabled public String csv { get; set; }
        @AuraEnabled public String fileName { get; set; }
        @AuraEnabled public Integer rowCount { get; set; }
    }

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
        ];
        if (rows.isEmpty()) {
            throw new AuraHandledException('No approved invitees to export yet.');
        }

        List<String> lines = new List<String>{
            'Name,Title,Account,Email,Approved By,Decided At'
        };
        List<Event_Invitee__c> toFlip = new List<Event_Invitee__c>();
        for (Event_Invitee__c inv : rows) {
            lines.add(String.join(new List<String>{
                csvCell(inv.Contact__r.Name),
                csvCell(inv.Contact__r.Title),
                csvCell(inv.Account__r != null ? inv.Account__r.Name : ''),
                csvCell(inv.Contact__r.Email),
                csvCell(inv.Account_Owner__r != null ? inv.Account_Owner__r.Name : ''),
                csvCell(inv.Decided_At__c != null ? inv.Decided_At__c.format('yyyy-MM-dd HH:mm', 'GMT') + ' GMT' : '')
            }, ','));
            if (inv.Status__c == 'Approved') {
                toFlip.add(new Event_Invitee__c(Id = inv.Id, Status__c = 'Exported'));
            }
        }
        if (!toFlip.isEmpty()) { update toFlip; }

        ExportResult res = new ExportResult();
        res.csv = String.join(lines, '\n');
        res.fileName = evt.Name.replaceAll('[^a-zA-Z0-9 _-]', '').replace(' ', '_') + '_approved_contacts.csv';
        res.rowCount = rows.size();
        return res;
    }

    private static String csvCell(String value) {
        if (value == null) { return ''; }
        if (value.contains(',') || value.contains('"') || value.contains('\n')) {
            return '"' + value.replace('"', '""') + '"';
        }
        return value;
    }
}
