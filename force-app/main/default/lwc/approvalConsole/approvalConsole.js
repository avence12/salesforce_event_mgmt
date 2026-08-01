import { LightningElement, api, track, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getPendingForMe from '@salesforce/apex/ApprovalConsoleController.getPendingForMe';
import decide from '@salesforce/apex/ApprovalConsoleController.decide';

export default class ApprovalConsole extends LightningElement {
    @api recordId; // Marketing_Event__c

    @track selectedIds = new Set();
    @track loading = false;

    wiredPending;
    pending = [];

    @wire(getPendingForMe, { eventId: '$recordId' })
    handlePending(result) {
        this.wiredPending = result;
        if (result.data) {
            this.pending = result.data;
            // Select all by default — the console's whole point is two-tap bulk approval.
            this.selectedIds = new Set(result.data.map((p) => p.inviteeId));
        }
    }

    get hasPending() {
        return this.pending.length > 0;
    }
    get totalCount() {
        return this.pending.length;
    }
    get selectedCount() {
        return this.selectedIds.size;
    }
    get allSelected() {
        return this.pending.length > 0 && this.selectedIds.size === this.pending.length;
    }
    get selectAllLabel() {
        return `Select All (${this.totalCount})`;
    }
    get approveLabel() {
        return `Approve (${this.selectedCount})`;
    }
    get rejectLabel() {
        return `Reject (${this.selectedCount})`;
    }
    get actionsDisabled() {
        return this.loading || this.selectedCount === 0;
    }

    get groups() {
        const byAccount = new Map();
        this.pending.forEach((p) => {
            if (!byAccount.has(p.accountId)) {
                byAccount.set(p.accountId, {
                    accountId: p.accountId,
                    accountName: p.accountName,
                    rows: []
                });
            }
            byAccount.get(p.accountId).rows.push({
                ...p,
                selected: this.selectedIds.has(p.inviteeId),
                nameTitle: p.contactTitle ? `${p.contactName} · ${p.contactTitle}` : p.contactName
            });
        });
        return [...byAccount.values()];
    }

    handleSelectAll(event) {
        this.selectedIds = event.target.checked
            ? new Set(this.pending.map((p) => p.inviteeId))
            : new Set();
    }

    handleToggle(event) {
        const id = event.target.dataset.id;
        const next = new Set(this.selectedIds);
        if (event.target.checked) next.add(id);
        else next.delete(id);
        this.selectedIds = next;
    }

    handleApprove() {
        this.decideSelected(true);
    }
    handleReject() {
        this.decideSelected(false);
    }

    async decideSelected(approve) {
        this.loading = true;
        try {
            const res = await decide({
                eventId: this.recordId,
                inviteeIds: [...this.selectedIds],
                approve
            });
            const verb = approve ? 'approved' : 'rejected';
            const suffix =
                res.amsNotified > 0
                    ? ` ${res.amsNotified} AM(s) notified — their batch is fully reviewed.`
                    : '';
            this.toast('Done', `${res.decided} invitee(s) ${verb}.${suffix}`, 'success');
            await refreshApex(this.wiredPending);
        } catch (e) {
            this.toast(
                'Error',
                (e && e.body && e.body.message) || (e && e.message) || 'Unexpected error',
                'error'
            );
        } finally {
            this.loading = false;
        }
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
