import { LightningElement, api, track, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getMyPendingByCompany from '@salesforce/apex/InviteeApprovalController.getMyPendingByCompany';
import decide from '@salesforce/apex/InviteeApprovalController.decide';

/**
 * ★R8 Screen 4b — the approver's side of the Marketing Event page.
 *
 * One tick on a company row selects everybody from that company; one button decides them.
 * That is the requirement, and the two steps are deliberate rather than one: the tick is
 * what the business asked for, and keeping the decision on its own button means a bulk
 * approval is always something the approver pressed, never something a stray tap did.
 *
 * Nothing starts selected for the same reason. Pre-ticking every row would make "approve
 * everyone" the path of least resistance, which is the opposite of what an approval is for.
 */
export default class ApprovalsByCompany extends LightningElement {
    @api recordId; // Marketing_Event__c

    @track selectedIds = new Set();
    @track comment = '';
    @track loading = false;

    wiredPending;
    groups = [];

    @wire(getMyPendingByCompany, { eventId: '$recordId' })
    handlePending(result) {
        this.wiredPending = result;
        if (result.data) {
            this.groups = result.data;
            // Anything decided elsewhere since the last load must not stay selected — a
            // stale id would come back as a "skipped" row nobody asked about.
            const live = new Set();
            result.data.forEach((g) => g.invitees.forEach((i) => live.add(i.inviteeId)));
            const kept = new Set();
            this.selectedIds.forEach((id) => {
                if (live.has(id)) kept.add(id);
            });
            this.selectedIds = kept;
        }
    }

    // ---------- derived view ----------

    get displayGroups() {
        return this.groups.map((g) => {
            const rows = g.invitees.map((i) => ({
                ...i,
                selected: this.selectedIds.has(i.inviteeId),
                hasRemark: !!i.remark,
                nameLabel: i.salutation ? `${i.salutation} ${i.name}` : i.name
            }));
            const selectedCount = rows.filter((r) => r.selected).length;
            return {
                ...g,
                rows,
                selectedCount,
                allSelected: selectedCount === rows.length && rows.length > 0,
                // Drives the group checkbox's indeterminate state — "some of this company",
                // which is what per-person veto looks like from the company row.
                partlySelected: selectedCount > 0 && selectedCount < rows.length,
                countLabel: `${rows.length} pending`,
                approveLabel: selectedCount ? `Approve ${selectedCount}` : 'Approve',
                rejectLabel: selectedCount ? `Reject ${selectedCount}` : 'Reject',
                actionsDisabled: this.loading || selectedCount === 0,
                custCdLabel: g.custCd || 'No customer code'
            };
        });
    }

    get pendingCount() {
        return this.groups.reduce((n, g) => n + g.invitees.length, 0);
    }
    get hasPending() {
        return this.pendingCount > 0;
    }
    get headerLabel() {
        const n = this.pendingCount;
        return `${n} invitee${n === 1 ? '' : 's'} awaiting your approval`;
    }
    get selectedTotal() {
        return this.selectedIds.size;
    }
    get bulkDisabled() {
        return this.loading || this.selectedIds.size === 0;
    }
    get approveAllLabel() {
        return `Approve selected (${this.selectedIds.size})`;
    }
    get rejectAllLabel() {
        return `Reject selected (${this.selectedIds.size})`;
    }

    renderedCallback() {
        // indeterminate is a DOM property, not an attribute, so the template cannot set it.
        this.template.querySelectorAll('[data-group-box]').forEach((box) => {
            const group = this.displayGroups.find((g) => g.groupKey === box.dataset.groupBox);
            if (group) box.indeterminate = group.partlySelected;
        });
    }

    // ---------- selection ----------

    handleRowToggle(event) {
        const next = new Set(this.selectedIds);
        if (event.target.checked) next.add(event.target.dataset.id);
        else next.delete(event.target.dataset.id);
        this.selectedIds = next;
    }

    handleGroupToggle(event) {
        const key = event.target.dataset.groupBox;
        const group = this.groups.find((g) => g.groupKey === key);
        if (!group) return;
        const next = new Set(this.selectedIds);
        group.invitees.forEach((i) => {
            if (event.target.checked) next.add(i.inviteeId);
            else next.delete(i.inviteeId);
        });
        this.selectedIds = next;
    }

    handleComment(event) {
        this.comment = event.target.value;
    }

    // ---------- decisions ----------

    handleGroupApprove(event) {
        this.run(this.idsInGroup(event.target.dataset.group), true);
    }
    handleGroupReject(event) {
        this.run(this.idsInGroup(event.target.dataset.group), false);
    }
    handleApproveSelected() {
        this.run([...this.selectedIds], true);
    }
    handleRejectSelected() {
        this.run([...this.selectedIds], false);
    }
    handleRefresh() {
        this.reload();
    }

    idsInGroup(key) {
        const group = this.groups.find((g) => g.groupKey === key);
        if (!group) return [];
        return group.invitees.map((i) => i.inviteeId).filter((id) => this.selectedIds.has(id));
    }

    async run(inviteeIds, approve) {
        if (!inviteeIds.length) return;
        this.loading = true;
        try {
            const res = await decide({
                eventId: this.recordId,
                inviteeIds,
                approve,
                comment: this.comment
            });
            // The skipped count is surfaced rather than swallowed: a row that stopped being
            // this user's between load and click is a thing they should hear about once.
            const skipped = res.skipped
                ? ` ${res.skipped} were no longer waiting on you and were left alone.`
                : '';
            this.toast(
                approve ? 'Approved' : 'Rejected',
                `${res.decided} invitee(s) ${approve ? 'approved' : 'rejected'}.${skipped}`,
                'success'
            );
            this.selectedIds = new Set();
            this.comment = '';
            await this.reload();
        } catch (e) {
            this.toast('Nothing was changed', this.messageOf(e), 'error');
        } finally {
            this.loading = false;
        }
    }

    async reload() {
        await refreshApex(this.wiredPending);
    }

    messageOf(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Unexpected error';
    }
    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
