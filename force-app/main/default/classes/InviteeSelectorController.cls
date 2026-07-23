/**
 * Screen 3 — Contact Selector on the Event record page (AM side).
 * "My accounts" = accounts the AM owns OR where the AM is on the Account Team.
 * Contacts already invited (Draft/Pending/Approved/Exported, by anyone) are hidden;
 * Rejected contacts reappear and re-adding resets the existing row to Draft.
 */
public with sharing class InviteeSelectorController {

    public class SelectableContact {
        @AuraEnabled public Id contactId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String title { get; set; }
        @AuraEnabled public String email { get; set; }
        @AuraEnabled public Id accountId { get; set; }
        @AuraEnabled public String accountName { get; set; }
        @AuraEnabled public String accountOwnerName { get; set; }
    }

    public class InviteeRow {
        @AuraEnabled public Id inviteeId { get; set; }
        @AuraEnabled public String contactName { get; set; }
        @AuraEnabled public String contactTitle { get; set; }
        @AuraEnabled public String accountName { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public String addedByName { get; set; }
        @AuraEnabled public Boolean mine { get; set; }
    }

    public class SubmitResult {
        @AuraEnabled public Integer submitted { get; set; }
        @AuraEnabled public Integer ownersNotified { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static List<SelectableContact> getSelectableContacts(Id eventId) {
        Set<Id> myAccountIds = getMyAccountIds();
        if (myAccountIds.isEmpty()) { return new List<SelectableContact>(); }

        // Hide contacts already on the event unless their row is Rejected.
        Set<Id> blockedContactIds = new Set<Id>();
        for (Event_Invitee__c inv : [
            SELECT Contact__c FROM Event_Invitee__c
            WHERE Marketing_Event__c = :eventId AND Status__c != 'Rejected'
        ]) {
            blockedContactIds.add(inv.Contact__c);
        }

        List<SelectableContact> out = new List<SelectableContact>();
        for (Contact c : [
            SELECT Id, Name, Title, Email, AccountId, Account.Name, Account.Owner.Name
            FROM Contact
            WHERE AccountId IN :myAccountIds AND Id NOT IN :blockedContactIds
            ORDER BY Account.Name, Name
            LIMIT 2000
        ]) {
            SelectableContact sc = new SelectableContact();
            sc.contactId = c.Id;
            sc.name = c.Name;
            sc.title = c.Title;
            sc.email = c.Email;
            sc.accountId = c.AccountId;
            sc.accountName = c.Account.Name;
            sc.accountOwnerName = c.Account.Owner.Name;
            out.add(sc);
        }
        return out;
    }

    @AuraEnabled
    public static Integer addInvitees(Id eventId, List<Id> contactIds) {
        if (contactIds == null || contactIds.isEmpty()) {
            throw new AuraHandledException('No contacts selected.');
        }

        Map<Id, Contact> contacts = new Map<Id, Contact>([
            SELECT Id, AccountId FROM Contact WHERE Id IN :contactIds
        ]);

        // Existing rows for these contacts on this event (any status).
        Map<Id, Event_Invitee__c> existingByContact = new Map<Id, Event_Invitee__c>();
        for (Event_Invitee__c inv : [
            SELECT Id, Contact__c, Status__c FROM Event_Invitee__c
            WHERE Marketing_Event__c = :eventId AND Contact__c IN :contactIds
        ]) {
            existingByContact.put(inv.Contact__c, inv);
        }

        List<Event_Invitee__c> toInsert = new List<Event_Invitee__c>();
        List<Event_Invitee__c> toReset = new List<Event_Invitee__c>();

        for (Id contactId : contactIds) {
            Contact c = contacts.get(contactId);
            if (c == null) { continue; }
            Event_Invitee__c existing = existingByContact.get(contactId);
            if (existing == null) {
                toInsert.add(new Event_Invitee__c(
                    Marketing_Event__c = eventId,
                    Contact__c = contactId,
                    Status__c = 'Draft',
                    Added_By__c = UserInfo.getUserId(),
                    Account__c = c.AccountId, // snapshot at add time
                    Unique_Key__c = String.valueOf(eventId) + '-' + String.valueOf(contactId)
                ));
            } else if (existing.Status__c == 'Rejected') {
                // Re-add resets the existing row — Unique_Key__c forbids a second row.
                existing.Status__c = 'Draft';
                existing.Added_By__c = UserInfo.getUserId();
                existing.Account__c = c.AccountId;
                existing.Account_Owner__c = null;
                existing.Submitted_At__c = null;
                existing.Decided_At__c = null;
                toReset.add(existing);
            }
            // Any other status: already invited — silently skipped (UI hides these anyway).
        }

        if (!toInsert.isEmpty()) { insert toInsert; }
        if (!toReset.isEmpty()) { update toReset; }
        return toInsert.size() + toReset.size();
    }

    @AuraEnabled
    public static SubmitResult submitMyInvitees(Id eventId) {
        List<Event_Invitee__c> mine = [
            SELECT Id, Account__c
            FROM Event_Invitee__c
            WHERE Marketing_Event__c = :eventId
              AND Added_By__c = :UserInfo.getUserId()
              AND Status__c = 'Draft'
        ];
        if (mine.isEmpty()) {
            throw new AuraHandledException('You have no draft invitees to submit.');
        }

        // Snapshot the Account Owner at submit time.
        Set<Id> accountIds = new Set<Id>();
        for (Event_Invitee__c inv : mine) {
            if (inv.Account__c != null) { accountIds.add(inv.Account__c); }
        }
        Map<Id, Account> owners = new Map<Id, Account>([
            SELECT Id, OwnerId FROM Account WHERE Id IN :accountIds
        ]);

        Map<Id, Integer> countByOwner = new Map<Id, Integer>();
        Datetime now = Datetime.now();
        for (Event_Invitee__c inv : mine) {
            Id ownerId = inv.Account__c != null && owners.containsKey(inv.Account__c)
                ? owners.get(inv.Account__c).OwnerId
                : null;
            inv.Status__c = 'Pending Approval';
            inv.Submitted_At__c = now;
            inv.Account_Owner__c = ownerId;
            if (ownerId != null) {
                Integer n = countByOwner.containsKey(ownerId) ? countByOwner.get(ownerId) : 0;
                countByOwner.put(ownerId, n + 1);
            }
        }
        update mine;

        Marketing_Event__c evt = [SELECT Id, Name FROM Marketing_Event__c WHERE Id = :eventId];
        EventNotificationService.notifyOwnersOfSubmission(evt, countByOwner, UserInfo.getUserId());

        SubmitResult res = new SubmitResult();
        res.submitted = mine.size();
        res.ownersNotified = countByOwner.size();
        return res;
    }

    @AuraEnabled(cacheable=true)
    public static List<InviteeRow> getAllInvitees(Id eventId) {
        List<InviteeRow> out = new List<InviteeRow>();
        for (Event_Invitee__c inv : [
            SELECT Id, Contact__r.Name, Contact__r.Title, Account__r.Name,
                   Status__c, Added_By__r.Name, Added_By__c
            FROM Event_Invitee__c
            WHERE Marketing_Event__c = :eventId
            ORDER BY Account__r.Name, Contact__r.Name
            LIMIT 2000
        ]) {
            InviteeRow r = new InviteeRow();
            r.inviteeId = inv.Id;
            r.contactName = inv.Contact__r.Name;
            r.contactTitle = inv.Contact__r.Title;
            r.accountName = inv.Account__r != null ? inv.Account__r.Name : null;
            r.status = inv.Status__c;
            r.addedByName = inv.Added_By__r != null ? inv.Added_By__r.Name : null;
            r.mine = inv.Added_By__c == UserInfo.getUserId();
            out.add(r);
        }
        return out;
    }

    // ---------- internals ----------

    private static Set<Id> getMyAccountIds() {
        Set<Id> ids = new Set<Id>();
        for (Account a : [SELECT Id FROM Account WHERE OwnerId = :UserInfo.getUserId()]) {
            ids.add(a.Id);
        }
        for (AccountTeamMember m : [SELECT AccountId FROM AccountTeamMember WHERE UserId = :UserInfo.getUserId()]) {
            ids.add(m.AccountId);
        }
        return ids;
    }
}
