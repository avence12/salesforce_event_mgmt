import { LightningElement, api, track, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getMyPendingByCompany from '@salesforce/apex/InviteeApprovalController.getMyPendingByCompany';
import decide from '@salesforce/apex/InviteeApprovalController.decide';
import getAddableAttendees from '@salesforce/apex/InviteeApprovalController.getAddableAttendees';
import addInvitees from '@salesforce/apex/InviteeApprovalController.addInvitees';

/**
 * ★R13 How many matching attendees the add panel puts on screen at once.
 *
 * The server will hand back up to 2,000. Rendering them would be the wrong shape for this
 * screen: an approver adding somebody has a person in mind and types their name, where an AM
 * building a guest list browses. A short list plus an honest "N more match" is a better answer
 * on a phone than a wall of rows, and it is the same 2,000-row truncation notice one level in.
 */
const MAX_VISIBLE_MATCHES = 25;

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
 *
 * ★R13 The panel at the bottom adds people. It is folded away until asked for, and it renders
 * at all only when the server says this user approves something on this event — an AM looking
 * at the same record page sees the empty state and no add controls. Adding submits immediately
 * and says where each person went, because "added" and "waiting on you" are different news and
 * a toast that ran them together would be the reason somebody never approved their own
 * addition.
 */
export default class ApprovalsByCompany extends LightningElement {
    @api recordId; // Marketing_Event__c

    @track selectedIds = new Set();
    @track comment = '';
    @track loading = false;

    wiredPending;
    groups = [];

    // ★R13 add panel
    @track addOpen = false;
    @track addSearch = '';
    @track addSelectedIds = new Set();
    @track canAdd = false;
    @track addTruncated = false;
    @track addCap = 0;
    wiredAddable;
    addable = [];

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

    @wire(getAddableAttendees, { eventId: '$recordId' })
    handleAddable(result) {
        this.wiredAddable = result;
        if (result.data) {
            this.canAdd = result.data.canAdd;
            this.addable = result.data.attendees || [];
            this.addTruncated = result.data.truncated;
            this.addCap = result.data.cap;
            // Somebody added elsewhere since the last load must not stay ticked here.
            const live = new Set(this.addable.map((a) => a.attendeeId));
            const kept = new Set();
            this.addSelectedIds.forEach((id) => {
                if (live.has(id)) kept.add(id);
            });
            this.addSelectedIds = kept;
        }
    }

    // ---------- derived view ----------

    get displayGroups() {
        return this.groups.map((g) => {
            const rows = g.invitees.map((i) => ({
                ...i,
                selected: this.selectedIds.has(i.inviteeId),
                hasRemark: !!i.remark,
                nameLabel: i.salutation ? `${i.salutation} ${i.name}` : i.name,
                // ★R9 "Level 2 of 3". Whether an approver is the last signature or one of
                // several changes what their decision means, and it is not something the
                // standard Approvals list can tell them either. Shown only when there is
                // more than one level: on a single-level chain it would be a badge that
                // always reads the same thing.
                levelLabel: i.level && i.levels ? `Level ${i.level} of ${i.levels}` : null,
                showLevel: !!(i.level && i.levels && i.levels > 1)
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
        // ★R13 Both: adding changes what is pending *and* what is left to add, and a picker
        // still offering somebody who is now an invitee is the next duplicate-add attempt.
        await Promise.all([refreshApex(this.wiredPending), refreshApex(this.wiredAddable)]);
    }

    // ---------- ★R13 adding people mid-review ----------

    get addPanelLabel() {
        return this.addOpen ? 'Close' : 'Add invitees from the attendee list';
    }
    get addPanelIcon() {
        return this.addOpen ? 'utility:chevronup' : 'utility:add';
    }

    /** Everything the search matches, before the display limit — the count the notes quote. */
    get matchedAttendees() {
        const needle = this.addSearch.trim().toLowerCase();
        if (!needle) return this.addable;
        return this.addable.filter(
            (a) =>
                (a.name || '').toLowerCase().includes(needle) ||
                (a.title || '').toLowerCase().includes(needle) ||
                (a.email || '').toLowerCase().includes(needle) ||
                (a.company || '').toLowerCase().includes(needle)
        );
    }

    get addRows() {
        return this.matchedAttendees.slice(0, MAX_VISIBLE_MATCHES).map((a) => ({
            ...a,
            selected: this.addSelectedIds.has(a.attendeeId)
        }));
    }
    get hasAddRows() {
        return this.addRows.length > 0;
    }

    get moreMatches() {
        return Math.max(this.matchedAttendees.length - MAX_VISIBLE_MATCHES, 0);
    }
    get hasMoreMatches() {
        return this.moreMatches > 0;
    }
    get moreMatchesNote() {
        return `${this.moreMatches} more attendee(s) match. Narrow the search to reach them.`;
    }
    get addTruncationNote() {
        return `Only the first ${this.addCap} attendees were loaded — more have been imported. Search by name, organisation or email to reach the rest.`;
    }

    /**
     * Ticks that the current search has scrolled out of view. Same rule as the AM's selector:
     * a count disagreeing with the rows on screen is worse than a sentence saying why.
     */
    get hiddenAddSelectedCount() {
        const visible = new Set(this.addRows.map((r) => r.attendeeId));
        let hidden = 0;
        this.addSelectedIds.forEach((id) => {
            if (!visible.has(id)) hidden++;
        });
        return hidden;
    }
    get hasHiddenAddSelected() {
        return this.hiddenAddSelectedCount > 0;
    }
    get hiddenAddSelectedNote() {
        const n = this.hiddenAddSelectedCount;
        return `${n} ticked attendee(s) are outside the current search and will still be added.`;
    }

    get addSubmitLabel() {
        return `Add and submit (${this.addSelectedIds.size})`;
    }
    get addSubmitDisabled() {
        return this.loading || this.addSelectedIds.size === 0;
    }

    handleToggleAddPanel() {
        this.addOpen = !this.addOpen;
    }
    handleAddSearch(event) {
        this.addSearch = event.target.value;
    }
    handleAddToggle(event) {
        const next = new Set(this.addSelectedIds);
        if (event.target.checked) next.add(event.target.dataset.attendee);
        else next.delete(event.target.dataset.attendee);
        this.addSelectedIds = next;
    }

    async handleAddSubmit() {
        const attendeeIds = [...this.addSelectedIds];
        if (!attendeeIds.length) return;
        this.loading = true;
        try {
            const res = await addInvitees({ eventId: this.recordId, attendeeIds });
            this.toast('Added', this.addOutcome(res), 'success');
            this.addSelectedIds = new Set();
            this.addSearch = '';
            await this.reload();
        } catch (e) {
            this.toast('Nothing was added', this.messageOf(e), 'error');
        } finally {
            this.loading = false;
        }
    }

    /**
     * Where each added person went. Every clause is omitted when its number is zero, because
     * the common case is one of them and a sentence listing three zeroes reads as a failure.
     */
    addOutcome(res) {
        const mine = res.waitingOnMe
            ? ` ${res.waitingOnMe} of them are waiting on you and are listed above.`
            : '';
        const others = res.approversNotified
            ? ` ${res.approversNotified} other approver(s) were notified.`
            : '';
        const chain =
            res.levels > 1
                ? ` The longest chain is ${res.levels} levels — each one decides in turn.`
                : '';
        const skipped = res.skipped
            ? ` ${res.skipped} were already on this event and were left alone.`
            : '';
        return `${res.added} attendee(s) added and submitted for approval.${mine}${others}${chain}${skipped}`;
    }

    messageOf(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Unexpected error';
    }
    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
