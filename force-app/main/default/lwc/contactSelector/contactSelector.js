import { LightningElement, api, track, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getSelectableContacts from '@salesforce/apex/InviteeSelectorController.getSelectableContacts';
import getAllInvitees from '@salesforce/apex/InviteeSelectorController.getAllInvitees';
import addInvitees from '@salesforce/apex/InviteeSelectorController.addInvitees';
import submitMyInvitees from '@salesforce/apex/InviteeSelectorController.submitMyInvitees';
import exportApproved from '@salesforce/apex/EventExportController.exportApproved';
import { downloadCsv } from 'c/csvDownload';

export default class ContactSelector extends LightningElement {
    @api recordId; // Marketing_Event__c

    @track searchTerm = '';
    @track accountFilter = '';
    @track selectedIds = new Set();
    @track loading = false;

    wiredSelectable;
    wiredInvitees;
    selectable = [];
    invitees = [];

    @wire(getSelectableContacts, { eventId: '$recordId' })
    handleSelectable(result) {
        this.wiredSelectable = result;
        if (result.data) this.selectable = result.data;
    }

    @wire(getAllInvitees, { eventId: '$recordId' })
    handleInvitees(result) {
        this.wiredInvitees = result;
        if (result.data) this.invitees = result.data;
    }

    // ---------- Add Contacts tab ----------

    get accountOptions() {
        const names = [...new Set(this.selectable.map((c) => c.accountName))].sort();
        return [{ label: 'All', value: '' }, ...names.map((n) => ({ label: n, value: n }))];
    }

    get filteredGroups() {
        const term = this.searchTerm.toLowerCase();
        const rows = this.selectable.filter((c) => {
            if (this.accountFilter && c.accountName !== this.accountFilter) return false;
            if (!term) return true;
            return (
                (c.name || '').toLowerCase().includes(term) ||
                (c.email || '').toLowerCase().includes(term) ||
                (c.title || '').toLowerCase().includes(term)
            );
        });
        const byAccount = new Map();
        rows.forEach((c) => {
            if (!byAccount.has(c.accountId)) {
                byAccount.set(c.accountId, { accountId: c.accountId, accountName: c.accountName, ownerName: c.accountOwnerName, contacts: [] });
            }
            byAccount.get(c.accountId).contacts.push({ ...c, selected: this.selectedIds.has(c.contactId) });
        });
        return [...byAccount.values()].map((g) => ({
            ...g,
            header: `${g.accountName} (Owner: ${g.ownerName}) — ${g.contacts.filter((c) => c.selected).length}/${g.contacts.length} selected`
        }));
    }

    get hasSelectable() { return this.selectable.length > 0; }
    get addLabel() { return `Add Selected (${this.selectedIds.size})`; }
    get addDisabled() { return this.loading || this.selectedIds.size === 0; }

    get myDraftCount() {
        return this.invitees.filter((i) => i.mine && i.status === 'Draft').length;
    }
    get submitLabel() { return `Submit My Contacts for Approval (${this.myDraftCount})`; }
    get submitDisabled() { return this.loading || this.myDraftCount === 0; }

    handleSearch(event) { this.searchTerm = event.target.value; }
    handleAccountFilter(event) { this.accountFilter = event.detail.value; }

    handleToggle(event) {
        const id = event.target.dataset.id;
        const next = new Set(this.selectedIds);
        if (event.target.checked) next.add(id);
        else next.delete(id);
        this.selectedIds = next;
    }

    async handleAdd() {
        this.loading = true;
        try {
            const n = await addInvitees({ eventId: this.recordId, contactIds: [...this.selectedIds] });
            this.toast('Added', `${n} contact(s) added as Draft.`, 'success');
            this.selectedIds = new Set();
            await Promise.all([refreshApex(this.wiredSelectable), refreshApex(this.wiredInvitees)]);
        } catch (e) {
            this.toast('Error', this.messageOf(e), 'error');
        } finally {
            this.loading = false;
        }
    }

    async handleSubmit() {
        this.loading = true;
        try {
            const res = await submitMyInvitees({ eventId: this.recordId });
            this.toast('Submitted', `${res.submitted} contact(s) sent for approval — ${res.ownersNotified} Account Owner(s) notified.`, 'success');
            await refreshApex(this.wiredInvitees);
        } catch (e) {
            this.toast('Error', this.messageOf(e), 'error');
        } finally {
            this.loading = false;
        }
    }

    // ---------- All Invitees tab ----------

    get inviteeRows() {
        return this.invitees.map((i, idx) => ({
            ...i,
            key: idx,
            addedByLabel: i.mine ? `${i.addedByName} (me)` : i.addedByName
        }));
    }
    get hasInvitees() { return this.invitees.length > 0; }

    get exportableCount() {
        return this.invitees.filter((i) => i.status === 'Approved' || i.status === 'Exported').length;
    }
    get showExport() { return this.exportableCount > 0; }

    async handleExport() {
        this.loading = true;
        try {
            const res = await exportApproved({ eventId: this.recordId });
            downloadCsv(res.csv, res.fileName);
            this.toast('Exported', `${res.rowCount} approved contact(s) exported.`, 'success');
            await refreshApex(this.wiredInvitees);
        } catch (e) {
            this.toast('Error', this.messageOf(e), 'error');
        } finally {
            this.loading = false;
        }
    }

    messageOf(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Unexpected error';
    }
    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
