import { LightningElement, api, track, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getSelectableAttendees from '@salesforce/apex/InviteeSelectorController.getSelectableAttendees';
import getAllInvitees from '@salesforce/apex/InviteeSelectorController.getAllInvitees';
import addAttendees from '@salesforce/apex/InviteeSelectorController.addAttendees';
import submitMyInvitees from '@salesforce/apex/InviteeSelectorController.submitMyInvitees';

/**
 * Replaces c/contactSelector. R5 collapsed the Add Contacts and Add Leads tabs into
 * one list of Event Attendees: with a single kind of invitee there is nothing left
 * for two tabs to tell apart, and the duplicated filter/search/selection state that
 * came with them goes too.
 */
export default class AttendeeSelector extends LightningElement {
    @api recordId; // Marketing_Event__c

    @track searchTerm = '';
    @track companyFilter = '';
    @track selectedIds = new Set();
    @track loading = false;

    wiredSelectable;
    wiredInvitees;
    selectable = [];
    invitees = [];
    @track truncated = false;
    @track cap = 0;

    @wire(getSelectableAttendees, { eventId: '$recordId' })
    handleSelectable(result) {
        this.wiredSelectable = result;
        if (result.data) {
            this.selectable = result.data.attendees;
            this.truncated = result.data.truncated;
            this.cap = result.data.cap;
        }
    }

    @wire(getAllInvitees, { eventId: '$recordId' })
    handleInvitees(result) {
        this.wiredInvitees = result;
        if (result.data) this.invitees = result.data;
    }

    // ---------- Add Attendees tab ----------

    get companyOptions() {
        const names = [...new Set(this.selectable.map((r) => r.company))].filter(Boolean).sort();
        return [{ label: 'All', value: '' }, ...names.map((n) => ({ label: n, value: n }))];
    }

    get filteredGroups() {
        const needle = this.searchTerm.toLowerCase();
        const matched = this.selectable.filter((r) => {
            if (this.companyFilter && r.company !== this.companyFilter) return false;
            if (!needle) return true;
            return (
                (r.name || '').toLowerCase().includes(needle) ||
                (r.email || '').toLowerCase().includes(needle) ||
                (r.title || '').toLowerCase().includes(needle)
            );
        });
        const byGroup = new Map();
        matched.forEach((r) => {
            const key = r.company || '';
            if (!byGroup.has(key)) {
                byGroup.set(key, { groupKey: key, company: r.company, attendees: [] });
            }
            byGroup.get(key).attendees.push({
                ...r,
                rowId: r.attendeeId,
                selected: this.selectedIds.has(r.attendeeId)
            });
        });
        return [...byGroup.values()].map((g) => ({
            ...g,
            header: `${g.company || '(no company)'} — ${
                g.attendees.filter((a) => a.selected).length
            }/${g.attendees.length} selected`
        }));
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
     * Selections deliberately survive a filter change — picking a few from one
     * organisation, then a few from another, then adding once is a real workflow.
     * What is not acceptable is the count silently disagreeing with the rows on
     * screen, so say so.
     */
    get hiddenSelectedCount() {
        const visible = new Set();
        this.filteredGroups.forEach((g) => g.attendees.forEach((a) => visible.add(a.attendeeId)));
        let hidden = 0;
        this.selectedIds.forEach((id) => {
            if (!visible.has(id)) hidden++;
        });
        return hidden;
    }
    get hasHiddenSelected() {
        return this.hiddenSelectedCount > 0;
    }
    get hiddenSelectedNote() {
        const n = this.hiddenSelectedCount;
        return `${n} selected attendee${n === 1 ? ' is' : 's are'} outside the current filter and will still be added.`;
    }

    get truncationNote() {
        return `Showing the first ${this.cap} attendees — more have been imported. Narrow the list with the organisation filter or search to reach the rest.`;
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
    handleCompanyFilter(event) {
        this.companyFilter = event.detail.value;
    }

    handleToggle(event) {
        const next = new Set(this.selectedIds);
        if (event.target.checked) next.add(event.target.dataset.id);
        else next.delete(event.target.dataset.id);
        this.selectedIds = next;
    }

    async handleAdd() {
        this.loading = true;
        try {
            const n = await addAttendees({
                eventId: this.recordId,
                attendeeIds: [...this.selectedIds]
            });
            this.toast('Added', `${n} attendee(s) added as Draft.`, 'success');
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
