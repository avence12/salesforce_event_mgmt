/**
 * Screen 3 — Invitee Selector on the Event record page (AM side).
 *
 * Two sources, because an Account is a transacting customer by definition and a
 * technical conference invites people who are not at one:
 *   - Contacts under "my accounts" = accounts the AM owns OR is on the Account Team of.
 *   - Leads the AM owns — professors, researchers, speakers, press. A Contact with no
 *     Account would be a *private contact*, visible to nobody but its owner, which the
 *     shared-event model cannot use.
 *
 * Already-invited people are hidden; Rejected ones reappear and re-adding resets the
 * existing row to Draft. Submission hands off to the standard Approval Process — this
 * class resolves who approves, the process owns the status from there.
 */
public with sharing class InviteeSelectorController {
    public class SelectableContact {
        @AuraEnabled
        public Id contactId { get; set; }
        @AuraEnabled
        public Id leadId { get; set; }
        @AuraEnabled
        public String name { get; set; }
        @AuraEnabled
        public String title { get; set; }
        @AuraEnabled
        public String email { get; set; }
        @AuraEnabled
        public Id accountId { get; set; }
        @AuraEnabled
        public String accountName { get; set; }
        @AuraEnabled
        public String accountOwnerName { get; set; }
    }

    /** Wrapper so a truncated list can say so — a silently short list reads as "that's everyone". */
    public class SelectableResult {
        @AuraEnabled
        public List<SelectableContact> contacts { get; set; }
        @AuraEnabled
        public Boolean truncated { get; set; }
        @AuraEnabled
        public Integer cap { get; set; }
    }

    public class InviteeRow {
        @AuraEnabled
        public Id inviteeId { get; set; }
        @AuraEnabled
        public String contactName { get; set; }
        @AuraEnabled
        public String contactTitle { get; set; }
        @AuraEnabled
        public String accountName { get; set; }
        @AuraEnabled
        public String inviteeType { get; set; }
        @AuraEnabled
        public String status { get; set; }
        @AuraEnabled
        public String addedByName { get; set; }
        @AuraEnabled
        public Boolean mine { get; set; }
    }

    public class SubmitResult {
        @AuraEnabled
        public Integer submitted { get; set; }
        @AuraEnabled
        public Integer approversNotified { get; set; }
    }

    /** Most contacts the selector will hand back in one call. */
    public static final Integer CONTACT_CAP = 2000;

    @AuraEnabled(cacheable=true)
    public static SelectableResult getSelectableContacts(Id eventId) {
        SelectableResult res = new SelectableResult();
        res.contacts = new List<SelectableContact>();
        res.truncated = false;
        res.cap = CONTACT_CAP;

        Set<Id> myAccountIds = getMyAccountIds();
        if (myAccountIds.isEmpty()) {
            return res;
        }

        Set<Id> blockedContactIds = blockedIds(eventId, false);

        // One row past the cap: if it comes back, there are more than we are showing.
        Integer probe = CONTACT_CAP + 1;
        List<Contact> found = [
            SELECT Id, Name, Title, Email, AccountId, Account.Name, Account.Owner.Name
            FROM Contact
            WHERE AccountId IN :myAccountIds AND Id NOT IN :blockedContactIds
            ORDER BY Account.Name, Name
            LIMIT :probe
        ];
        if (found.size() > CONTACT_CAP) {
            res.truncated = true;
            found.remove(CONTACT_CAP); // drop the probe row
        }

        for (Contact c : found) {
            SelectableContact sc = new SelectableContact();
            sc.contactId = c.Id;
            sc.name = c.Name;
            sc.title = c.Title;
            sc.email = c.Email;
            sc.accountId = c.AccountId;
            sc.accountName = c.Account.Name;
            sc.accountOwnerName = c.Account.Owner.Name;
            res.contacts.add(sc);
        }
        return res;
    }

    /**
     * Leads the AM owns and has not already invited. Ownership is the only scope
     * available: Lead has no team object, so the Account Team half of the Contacts
     * rule has no counterpart here. Converted Leads are excluded — their Contact is
     * the thing to invite, and it will already be on the Contacts tab.
     */
    @AuraEnabled(cacheable=true)
    public static SelectableResult getSelectableLeads(Id eventId) {
        SelectableResult res = new SelectableResult();
        res.contacts = new List<SelectableContact>();
        res.truncated = false;
        res.cap = CONTACT_CAP;

        Set<Id> blockedLeadIds = blockedIds(eventId, true);

        Integer probe = CONTACT_CAP + 1;
        List<Lead> found = [
            SELECT Id, Name, Title, Email, Company, Owner.Name
            FROM Lead
            WHERE OwnerId = :UserInfo.getUserId() AND IsConverted = FALSE AND Id NOT IN :blockedLeadIds
            ORDER BY Company, Name
            LIMIT :probe
        ];
        if (found.size() > CONTACT_CAP) {
            res.truncated = true;
            found.remove(CONTACT_CAP);
        }

        for (Lead l : found) {
            SelectableContact sc = new SelectableContact();
            sc.leadId = l.Id;
            sc.name = l.Name;
            sc.title = l.Title;
            sc.email = l.Email;
            // Grouping key is the Company *text*: two spellings of one university group
            // separately, which is accepted for the PoC — there is no record to key on.
            sc.accountName = l.Company;
            sc.accountOwnerName = l.Owner.Name;
            res.contacts.add(sc);
        }
        return res;
    }

    @AuraEnabled
    public static Integer addInvitees(Id eventId, List<Id> contactIds) {
        if (contactIds == null || contactIds.isEmpty()) {
            throw new AuraHandledException('No contacts selected.');
        }

        Map<Id, Contact> contacts = new Map<Id, Contact>([SELECT Id, AccountId FROM Contact WHERE Id IN :contactIds]);

        // Existing rows for these contacts on this event (any status).
        Map<Id, Event_Invitee__c> existingByContact = new Map<Id, Event_Invitee__c>();
        for (Event_Invitee__c inv : [
            SELECT Id, Contact__c, Status__c
            FROM Event_Invitee__c
            WHERE Marketing_Event__c = :eventId AND Contact__c IN :contactIds
        ]) {
            existingByContact.put(inv.Contact__c, inv);
        }

        List<Event_Invitee__c> toInsert = new List<Event_Invitee__c>();
        List<Event_Invitee__c> toReset = new List<Event_Invitee__c>();

        for (Id contactId : contactIds) {
            Contact c = contacts.get(contactId);
            if (c == null) {
                continue;
            }
            Event_Invitee__c existing = existingByContact.get(contactId);
            if (existing == null) {
                toInsert.add(
                    new Event_Invitee__c(
                        Marketing_Event__c = eventId,
                        Contact__c = contactId,
                        Status__c = 'Draft',
                        Added_By__c = UserInfo.getUserId(),
                        Account__c = c.AccountId, // snapshot at add time
                        Unique_Key__c = String.valueOf(eventId) + '-' + String.valueOf(contactId)
                    )
                );
            } else if (existing.Status__c == 'Rejected') {
                // Re-add resets the existing row — Unique_Key__c forbids a second row.
                resetToDraft(existing, c.AccountId);
                toReset.add(existing);
            }
            // Any other status: already invited — silently skipped (UI hides these anyway).
        }

        if (!toInsert.isEmpty()) {
            insert toInsert;
        }
        if (!toReset.isEmpty()) {
            update toReset;
        }
        return toInsert.size() + toReset.size();
    }

    @AuraEnabled
    public static Integer addLeadInvitees(Id eventId, List<Id> leadIds) {
        if (leadIds == null || leadIds.isEmpty()) {
            throw new AuraHandledException('No leads selected.');
        }

        Map<Id, Event_Invitee__c> existingByLead = new Map<Id, Event_Invitee__c>();
        for (Event_Invitee__c inv : [
            SELECT Id, Lead__c, Status__c
            FROM Event_Invitee__c
            WHERE Marketing_Event__c = :eventId AND Lead__c IN :leadIds
        ]) {
            existingByLead.put(inv.Lead__c, inv);
        }

        List<Event_Invitee__c> toInsert = new List<Event_Invitee__c>();
        List<Event_Invitee__c> toReset = new List<Event_Invitee__c>();

        for (Id leadId : leadIds) {
            Event_Invitee__c existing = existingByLead.get(leadId);
            if (existing == null) {
                toInsert.add(
                    new Event_Invitee__c(
                        Marketing_Event__c = eventId,
                        Lead__c = leadId,
                        Status__c = 'Draft',
                        Added_By__c = UserInfo.getUserId(),
                        // Account__c stays null by design — a Lead has no customer Account,
                        // and Invitee_Org__c falls through to the Lead's Company text.
                        Unique_Key__c = String.valueOf(eventId) + '-' + String.valueOf(leadId)
                    )
                );
            } else if (existing.Status__c == 'Rejected') {
                resetToDraft(existing, null);
                toReset.add(existing);
            }
        }

        if (!toInsert.isEmpty()) {
            insert toInsert;
        }
        if (!toReset.isEmpty()) {
            update toReset;
        }
        return toInsert.size() + toReset.size();
    }

    /**
     * Submits this AM's Draft rows to the standard Approval Process.
     *
     * The status is deliberately NOT written here — the approval process's initial
     * submission action owns it. What this method owns is the one thing an approval
     * process cannot work out for itself: who approves. That is resolved once, frozen
     * into Approver__c, and never recomputed, so a later ownership change cannot
     * reroute an item somebody is already looking at.
     */
    @AuraEnabled
    public static SubmitResult submitMyInvitees(Id eventId) {
        List<Event_Invitee__c> mine = [
            SELECT Id, Account__c, Contact__c, Lead__c
            FROM Event_Invitee__c
            WHERE Marketing_Event__c = :eventId AND Added_By__c = :UserInfo.getUserId() AND Status__c = 'Draft'
        ];
        if (mine.isEmpty()) {
            throw new AuraHandledException('You have no draft invitees to submit.');
        }

        Id submitterId = UserInfo.getUserId();
        Map<Id, Id> ownerByAccount = new Map<Id, Id>();
        Map<Id, Id> ownerByLead = new Map<Id, Id>();
        Set<Id> accountIds = new Set<Id>();
        Set<Id> leadIds = new Set<Id>();
        for (Event_Invitee__c inv : mine) {
            if (inv.Account__c != null) {
                accountIds.add(inv.Account__c);
            }
            if (inv.Lead__c != null) {
                leadIds.add(inv.Lead__c);
            }
        }
        for (Account a : [SELECT Id, OwnerId FROM Account WHERE Id IN :accountIds]) {
            ownerByAccount.put(a.Id, a.OwnerId);
        }
        for (Lead l : [SELECT Id, OwnerId FROM Lead WHERE Id IN :leadIds]) {
            ownerByLead.put(l.Id, l.OwnerId);
        }
        Id managerId = [SELECT ManagerId FROM User WHERE Id = :submitterId].ManagerId;

        Map<Id, Integer> countByApprover = new Map<Id, Integer>();
        List<String> unroutable = new List<String>();
        Datetime now = Datetime.now();

        for (Event_Invitee__c inv : mine) {
            Id accountOwnerId = inv.Account__c == null ? null : ownerByAccount.get(inv.Account__c);
            Id approverId = resolveApprover(inv, accountOwnerId, ownerByLead, managerId, submitterId);
            if (approverId == null) {
                unroutable.add(inv.Id);
                continue;
            }
            inv.Submitted_At__c = now;
            inv.Account_Owner__c = accountOwnerId; // audit snapshot; null for Lead invitees
            inv.Approver__c = approverId;
            Integer n = countByApprover.containsKey(approverId) ? countByApprover.get(approverId) : 0;
            countByApprover.put(approverId, n + 1);
        }

        // All-or-nothing: a partial submit would leave the AM staring at a Draft count
        // that no longer matches what they just sent, with no clue which rows moved.
        if (!unroutable.isEmpty()) {
            throw new AuraHandledException(
                'No approver could be determined for ' +
                    unroutable.size() +
                    ' of ' +
                    mine.size() +
                    ' invitee(s). Set a Manager on your user record, or have someone else own the lead. Nothing was submitted.'
            );
        }

        update mine;

        List<Approval.ProcessSubmitRequest> requests = new List<Approval.ProcessSubmitRequest>();
        for (Event_Invitee__c inv : mine) {
            Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
            req.setObjectId(inv.Id);
            req.setProcessDefinitionNameOrId('Invitee_Approval');
            req.setSkipEntryCriteria(false);
            req.setSubmitterId(submitterId);
            requests.add(req);
        }
        // allOrNone = true: a half-submitted batch is worse than a failed one.
        Approval.process(requests, true);

        Marketing_Event__c evt = [SELECT Id, Name FROM Marketing_Event__c WHERE Id = :eventId];
        EventNotificationService.notifyApproversOfSubmission(evt, countByApprover, submitterId);

        SubmitResult res = new SubmitResult();
        res.submitted = mine.size();
        res.approversNotified = countByApprover.size();
        return res;
    }

    /**
     * The approver ladder. Order matters and rule 2's exclusion is the subtle one:
     * an AM usually owns the leads they added, so "the Lead Owner approves" would
     * quietly mean "the submitter approves their own submission" — the control this
     * whole workflow exists to provide, removed for exactly the invitees nobody has
     * vetted yet. Falling through to the manager is also what the original requirement
     * asked for; Account Owner was always a stand-in for "the AM's manager".
     */
    private static Id resolveApprover(
        Event_Invitee__c inv,
        Id accountOwnerId,
        Map<Id, Id> ownerByLead,
        Id managerId,
        Id submitterId
    ) {
        if (inv.Contact__c != null && accountOwnerId != null) {
            return accountOwnerId;
        }
        if (inv.Lead__c != null) {
            Id leadOwnerId = ownerByLead.get(inv.Lead__c);
            if (leadOwnerId != null && leadOwnerId != submitterId) {
                return leadOwnerId;
            }
        }
        return managerId; // may be null — caller refuses the submit rather than orphaning the row
    }

    /**
     * Reads the Invitee_* formula fields rather than either lookup, so one flat query
     * renders Contact and Lead rows with no branching — the same reason the Screen 5
     * reports can cover both in one report.
     */
    @AuraEnabled(cacheable=true)
    public static List<InviteeRow> getAllInvitees(Id eventId) {
        List<InviteeRow> out = new List<InviteeRow>();
        for (Event_Invitee__c inv : [
            SELECT
                Id,
                Invitee_Name__c,
                Invitee_Title__c,
                Invitee_Org__c,
                Invitee_Type__c,
                Status__c,
                Added_By__r.Name,
                Added_By__c
            FROM Event_Invitee__c
            WHERE Marketing_Event__c = :eventId
            ORDER BY Invitee_Org__c, Invitee_Name__c
            LIMIT 2000
        ]) {
            InviteeRow r = new InviteeRow();
            r.inviteeId = inv.Id;
            r.contactName = inv.Invitee_Name__c;
            r.contactTitle = inv.Invitee_Title__c;
            r.accountName = inv.Invitee_Org__c;
            r.inviteeType = inv.Invitee_Type__c;
            r.status = inv.Status__c;
            r.addedByName = inv.Added_By__r != null ? inv.Added_By__r.Name : null;
            r.mine = inv.Added_By__c == UserInfo.getUserId();
            out.add(r);
        }
        return out;
    }

    // ---------- internals ----------

    /** Contacts (or leads) already on the event, unless their row is Rejected — those reappear. */
    private static Set<Id> blockedIds(Id eventId, Boolean forLeads) {
        Set<Id> ids = new Set<Id>();
        for (Event_Invitee__c inv : [
            SELECT Contact__c, Lead__c
            FROM Event_Invitee__c
            WHERE Marketing_Event__c = :eventId AND Status__c != 'Rejected'
        ]) {
            Id id = forLeads ? inv.Lead__c : inv.Contact__c;
            if (id != null) {
                ids.add(id);
            }
        }
        return ids;
    }

    /**
     * Clears every trace of the previous approval round. Approver__c must go with the
     * rest: leaving a stale approver on a Draft row would let the next submit silently
     * skip the ladder and reuse whoever decided last time.
     */
    private static void resetToDraft(Event_Invitee__c inv, Id accountId) {
        inv.Status__c = 'Draft';
        inv.Added_By__c = UserInfo.getUserId();
        inv.Account__c = accountId;
        inv.Account_Owner__c = null;
        inv.Approver__c = null;
        inv.Submitted_At__c = null;
        inv.Decided_At__c = null;
    }

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
