import { LightningElement, api, track, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getSelectableContacts from '@salesforce/apex/InviteeSelectorController.getSelectableContacts';
import getSelectableLeads from '@salesforce/apex/InviteeSelectorController.getSelectableLeads';
import getAllInvitees from '@salesforce/apex/InviteeSelectorController.getAllInvitees';
import addInvitees from '@salesforce/apex/InviteeSelectorController.addInvitees';
import addLeadInvitees from '@salesforce/apex/InviteeSelectorController.addLeadInvitees';
import submitMyInvitees from '@salesforce/apex/InviteeSelectorController.submitMyInvitees';

export default class ContactSelector extends LightningElement {
    @api recordId; // Marketing_Event__c

    @track searchTerm = '';
    @track accountFilter = '';
    @track selectedIds = new Set();
    @track leadSearchTerm = '';
    @track leadCompanyFilter = '';
    @track selectedLeadIds = new Set();
    @track loading = false;

    wiredSelectable;
    wiredLeads;
    wiredInvitees;
    selectable = [];
    leads = [];
    invitees = [];
    @track truncated = false;
    @track cap = 0;
    @track leadsTruncated = false;

    @wire(getSelectableContacts, { eventId: '$recordId' })
    handleSelectable(result) {
        this.wiredSelectable = result;
        if (result.data) {
            this.selectable = result.data.contacts;
            this.truncated = result.data.truncated;
            this.cap = result.data.cap;
        }
    }

    @wire(getSelectableLeads, { eventId: '$recordId' })
    handleLeads(result) {
        this.wiredLeads = result;
        if (result.data) {
            this.leads = result.data.contacts;
            this.leadsTruncated = result.data.truncated;
            this.cap = result.data.cap;
        }
    }

    @wire(getAllInvitees, { eventId: '$recordId' })
    handleInvitees(result) {
        this.wiredInvitees = result;
        if (result.data) this.invitees = result.data;
    }

    // ---------- Add Contacts tab ----------

    get accountOptions() {
        return this.groupOptions(this.selectable, 'All');
    }

    get filteredGroups() {
        return this.groupRows(
            this.selectable,
            this.accountFilter,
            this.searchTerm,
            this.selectedIds,
            (c) => c.contactId,
            (g) => `${g.accountName} (Owner: ${g.ownerName})`
        );
    }

    get hasSelectable() {
        return this.selectable.length > 0;
    }
    get addLabel() {
        return `Add Selected (${this.selectedIds.size})`;
    }
    get addDisabled() {
        return this.loading || this.selectedIds.size === 0;
    }

    /**
     * Selections deliberately survive a filter change — picking a few from account A,
     * then a few from account B, then adding once is a real workflow. What is not
     * acceptable is the count silently disagreeing with the rows on screen, so say so.
     */
    get hiddenSelectedCount() {
        return this.countHidden(this.filteredGroups, this.selectedIds, (c) => c.contactId);
    }
    get hasHiddenSelected() {
        return this.hiddenSelectedCount > 0;
    }
    get hiddenSelectedNote() {
        const n = this.hiddenSelectedCount;
        return `${n} selected contact${n === 1 ? ' is' : 's are'} outside the current filter and will still be added.`;
    }

    get truncationNote() {
        return `Showing the first ${this.cap} contacts — more exist under your accounts. Narrow the list with the account filter or search to reach the rest.`;
    }

    // ---------- Add Leads tab ----------

    get leadCompanyOptions() {
        return this.groupOptions(this.leads, 'All');
    }

    get filteredLeadGroups() {
        return this.groupRows(
            this.leads,
            this.leadCompanyFilter,
            this.leadSearchTerm,
            this.selectedLeadIds,
            (l) => l.leadId,
            // Grouping is by the Lead's Company text, so the header names no owner:
            // every lead here is one this user owns.
            (g) => g.accountName || '(no company)'
        );
    }

    get hasSelectableLeads() {
        return this.leads.length > 0;
    }
    get addLeadsLabel() {
        return `Add Selected Leads (${this.selectedLeadIds.size})`;
    }
    get addLeadsDisabled() {
        return this.loading || this.selectedLeadIds.size === 0;
    }
    get hiddenSelectedLeadCount() {
        return this.countHidden(this.filteredLeadGroups, this.selectedLeadIds, (l) => l.leadId);
    }
    get hasHiddenSelectedLeads() {
        return this.hiddenSelectedLeadCount > 0;
    }
    get hiddenSelectedLeadsNote() {
        const n = this.hiddenSelectedLeadCount;
        return `${n} selected lead${n === 1 ? ' is' : 's are'} outside the current filter and will still be added.`;
    }
    get leadTruncationNote() {
        return `Showing the first ${this.cap} leads — you own more. Narrow the list with the company filter or search to reach the rest.`;
    }

    // ---------- shared list shaping ----------

    groupOptions(rows, allLabel) {
        const names = [...new Set(rows.map((r) => r.accountName))].filter(Boolean).sort();
        return [{ label: allLabel, value: '' }, ...names.map((n) => ({ label: n, value: n }))];
    }

    groupRows(rows, groupFilter, term, selectedIds, idOf, headerOf) {
        const needle = term.toLowerCase();
        const matched = rows.filter((r) => {
            if (groupFilter && r.accountName !== groupFilter) return false;
            if (!needle) return true;
            return (
                (r.name || '').toLowerCase().includes(needle) ||
                (r.email || '').toLowerCase().includes(needle) ||
                (r.title || '').toLowerCase().includes(needle)
            );
        });
        const byGroup = new Map();
        matched.forEach((r) => {
            const key = r.accountName || '';
            if (!byGroup.has(key)) {
                byGroup.set(key, {
                    groupKey: key,
                    accountName: r.accountName,
                    ownerName: r.accountOwnerName,
                    contacts: []
                });
            }
            byGroup.get(key).contacts.push({
                ...r,
                rowId: idOf(r),
                selected: selectedIds.has(idOf(r))
            });
        });
        return [...byGroup.values()].map((g) => ({
            ...g,
            header: `${headerOf(g)} — ${g.contacts.filter((c) => c.selected).length}/${g.contacts.length} selected`
        }));
    }

    countHidden(groups, selectedIds, idOf) {
        const visible = new Set();
        groups.forEach((g) => g.contacts.forEach((c) => visible.add(idOf(c))));
        let hidden = 0;
        selectedIds.forEach((id) => {
            if (!visible.has(id)) hidden++;
        });
        return hidden;
    }

    // ---------- submit ----------

    get myDraftCount() {
        return this.invitees.filter((i) => i.mine && i.status === 'Draft').length;
    }
    get submitLabel() {
        return `Submit My Invitees for Approval (${this.myDraftCount})`;
    }
    get submitDisabled() {
        return this.loading || this.myDraftCount === 0;
    }

    handleSearch(event) {
        this.searchTerm = event.target.value;
    }
    handleAccountFilter(event) {
        this.accountFilter = event.detail.value;
    }
    handleLeadSearch(event) {
        this.leadSearchTerm = event.target.value;
    }
    handleLeadCompanyFilter(event) {
        this.leadCompanyFilter = event.detail.value;
    }

    handleToggle(event) {
        this.selectedIds = this.toggled(this.selectedIds, event);
    }
    handleLeadToggle(event) {
        this.selectedLeadIds = this.toggled(this.selectedLeadIds, event);
    }
    toggled(current, event) {
        const next = new Set(current);
        if (event.target.checked) next.add(event.target.dataset.id);
        else next.delete(event.target.dataset.id);
        return next;
    }

    async handleAdd() {
        this.loading = true;
        try {
            const n = await addInvitees({
                eventId: this.recordId,
                contactIds: [...this.selectedIds]
            });
            this.toast('Added', `${n} contact(s) added as Draft.`, 'success');
            this.selectedIds = new Set();
            await Promise.all([refreshApex(this.wiredSelectable), refreshApex(this.wiredInvitees)]);
        } catch (e) {
            this.toast('Error', this.messageOf(e), 'error');
        } finally {
            this.loading = false;
        }
    }

    async handleAddLeads() {
        this.loading = true;
        try {
            const n = await addLeadInvitees({
                eventId: this.recordId,
                leadIds: [...this.selectedLeadIds]
            });
            this.toast('Added', `${n} lead(s) added as Draft.`, 'success');
            this.selectedLeadIds = new Set();
            await Promise.all([refreshApex(this.wiredLeads), refreshApex(this.wiredInvitees)]);
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
            this.toast(
                'Submitted',
                `${res.submitted} invitee(s) sent for approval — ${res.approversNotified} approver(s) notified.`,
                'success'
            );
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
    get hasInvitees() {
        return this.invitees.length > 0;
    }

    messageOf(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Unexpected error';
    }
    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
