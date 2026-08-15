/**
 * ★R8 Screen 4b — Approvals by Company, on the Marketing Event record page.
 *
 * The requirement is "one tick approves every invitee from the same company", with the
 * per-invitee record model untouched. The standard Approval Requests list cannot serve it:
 * its rows are ProcessInstanceWorkitem records, so it can neither display nor group by a
 * field on the target record, and the company is not visible there to select on. This class
 * is the smallest thing that closes that gap — read the running user's pending work grouped
 * by company, and act on a set of it.
 *
 * It is worth being explicit that this is a partial reversal of R3, which deleted a
 * hand-built approval console on the grounds that it reimplemented a platform feature. The
 * difference, and the reason this is not the same mistake: the platform still owns the
 * approval — the process definition, the routing, the status field updates, the record lock
 * and the ProcessInstance audit trail are all standard, and this class calls
 * Approval.process rather than writing Status__c itself. What it adds is a way to *choose*
 * the work items, which is the one thing the standard UI cannot do by company.
 *
 * Two rules it inherits from the rest of the codebase rather than inventing:
 *
 *   - **The client's list of ids is never trusted.** Every decision is re-scoped
 *     server-side to work items actually assigned to the running user on this event.
 *     A caller that sends somebody else's pending row gets it dropped, not processed.
 *   - **All-or-nothing per action, with the skipped rows reported.** A half-applied
 *     "Approve all 12" is worse than a refused one, and a silently short count reads as
 *     success.
 */
public with sharing class InviteeApprovalController {
    /** One company's worth of pending work for the running user. */
    public class CompanyGroup {
        @AuraEnabled
        public String groupKey { get; set; }
        @AuraEnabled
        public String company { get; set; }
        @AuraEnabled
        public String custCd { get; set; }
        /** False for a guest who belongs to no customer — a real state, not a data error. */
        @AuraEnabled
        public Boolean hasCustomer { get; set; }
        @AuraEnabled
        public List<PendingInvitee> invitees { get; set; }
    }

    public class PendingInvitee {
        @AuraEnabled
        public Id inviteeId { get; set; }
        @AuraEnabled
        public String name { get; set; }
        @AuraEnabled
        public String title { get; set; }
        @AuraEnabled
        public String salutation { get; set; }
        @AuraEnabled
        public Boolean vip { get; set; }
        @AuraEnabled
        public String remark { get; set; }
        @AuraEnabled
        public String addedByName { get; set; }
    }

    public class DecisionResult {
        @AuraEnabled
        public Integer decided { get; set; }
        /**
         * Rows the caller asked for that had no work item assigned to this user — already
         * decided by somebody else, recalled, or never theirs. Reported rather than hidden:
         * "Approved 9 of 12" is a fact the approver needs, and a bare 9 is not.
         */
        @AuraEnabled
        public Integer skipped { get; set; }
    }

    /**
     * Most invitees one decision may cover. Approval.process is DML, so a single enormous
     * group would take the transaction down with it; refusing at a stated number is kinder
     * than a governor limit surfacing as an unexplained failure. Raise it only after
     * measuring in a real org — see DEPLOYMENT.md.
     */
    public static final Integer MAX_PER_DECISION = 200;

    /** Rows to read for one event. Far above any realistic pending count for one approver. */
    private static final Integer PENDING_CAP = 2000;

    /**
     * The running user's pending invitees on this event, grouped by the company they were
     * invited as.
     *
     * Grouping is by Account where there is one and by the snapshotted company text
     * otherwise — deliberately not one "no customer" bucket for every unlinked guest. A
     * single bucket would put a professor from one university and a journalist from an
     * unrelated paper behind the same "Approve all" button, which is precisely the sort of
     * accidental bulk approval this screen exists to make deliberate.
     */
    @AuraEnabled(cacheable=true)
    public static List<CompanyGroup> getMyPendingByCompany(Id eventId) {
        Map<String, CompanyGroup> byKey = new Map<String, CompanyGroup>();

        for (Event_Invitee__c inv : [
            SELECT
                Id,
                Invitee_Name__c,
                Invitee_Title__c,
                Invitee_Salutation__c,
                Invitee_Org__c,
                Account__c,
                Cust_Cd__c,
                VIP__c,
                Remark__c,
                Added_By__r.Name
            FROM Event_Invitee__c
            WHERE
                Marketing_Event__c = :eventId
                AND Status__c = 'Pending Approval'
                AND Approver__c = :UserInfo.getUserId()
            ORDER BY Invitee_Org__c NULLS LAST, Invitee_Name__c
            LIMIT :PENDING_CAP
        ]) {
            String key = inv.Account__c != null
                ? String.valueOf(inv.Account__c)
                : 'text:' + (String.isBlank(inv.Invitee_Org__c) ? '' : inv.Invitee_Org__c);

            CompanyGroup g = byKey.get(key);
            if (g == null) {
                g = new CompanyGroup();
                g.groupKey = key;
                g.company = String.isBlank(inv.Invitee_Org__c) ? '(No organisation)' : inv.Invitee_Org__c;
                g.custCd = inv.Cust_Cd__c;
                g.hasCustomer = inv.Account__c != null;
                g.invitees = new List<PendingInvitee>();
                byKey.put(key, g);
            }

            PendingInvitee p = new PendingInvitee();
            p.inviteeId = inv.Id;
            p.name = inv.Invitee_Name__c;
            p.title = inv.Invitee_Title__c;
            p.salutation = inv.Invitee_Salutation__c;
            p.vip = inv.VIP__c;
            p.remark = inv.Remark__c;
            p.addedByName = inv.Added_By__r != null ? inv.Added_By__r.Name : null;
            g.invitees.add(p);
        }

        return byKey.values();
    }

    /**
     * Approves or rejects a set of invitees through the standard Approval Process.
     *
     * The status is not written here, deliberately — the process's final approval and final
     * rejection actions own Status__c and Decided_At__c, exactly as they do when an approver
     * clicks Approve in the standard UI. This method decides *which* work items to act on
     * and hands them to the platform.
     */
    @AuraEnabled
    public static DecisionResult decide(Id eventId, List<Id> inviteeIds, Boolean approve, String comment) {
        if (inviteeIds == null || inviteeIds.isEmpty()) {
            throw new AuraHandledException('Nothing selected.');
        }
        if (inviteeIds.size() > MAX_PER_DECISION) {
            throw new AuraHandledException(
                'Too many invitees in one action: ' +
                    inviteeIds.size() +
                    ' selected, ' +
                    MAX_PER_DECISION +
                    ' is the maximum. Approve one company at a time. Nothing was decided.'
            );
        }

        Set<Id> requested = new Set<Id>(inviteeIds);

        // Re-scoped server-side, and both halves of this matter. The event bound narrows the
        // ids to rows on the page the user is actually looking at; ActorId narrows them to
        // work items assigned to them. Neither is inferable from the client's request.
        Set<Id> mine = new Set<Id>();
        for (Event_Invitee__c inv : [
            SELECT Id
            FROM Event_Invitee__c
            WHERE
                Marketing_Event__c = :eventId
                AND Id IN :requested
                AND Status__c = 'Pending Approval'
                AND Approver__c = :UserInfo.getUserId()
        ]) {
            mine.add(inv.Id);
        }

        List<Approval.ProcessWorkitemRequest> requests = new List<Approval.ProcessWorkitemRequest>();
        for (ProcessInstanceWorkitem item : [
            SELECT Id, ProcessInstance.TargetObjectId
            FROM ProcessInstanceWorkitem
            WHERE ProcessInstance.TargetObjectId IN :mine AND ActorId = :UserInfo.getUserId()
        ]) {
            Approval.ProcessWorkitemRequest req = new Approval.ProcessWorkitemRequest();
            req.setWorkitemId(item.Id);
            req.setAction(approve ? 'Approve' : 'Reject');
            if (String.isNotBlank(comment)) {
                req.setComments(comment);
            }
            requests.add(req);
        }

        DecisionResult res = new DecisionResult();
        res.decided = requests.size();
        res.skipped = requested.size() - requests.size();

        if (requests.isEmpty()) {
            throw new AuraHandledException(
                'None of the selected invitees are waiting on you any more — they may have been ' +
                'decided already or recalled. Refresh to see the current list. Nothing was changed.'
            );
        }

        // allOrNone = true, matching submitMyInvitees: a partly applied bulk decision leaves
        // the approver with no way to tell which half went through.
        Approval.process(requests, true);
        return res;
    }
}
