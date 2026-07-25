import { LightningElement, track, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import TIME_ZONE from '@salesforce/i18n/timeZone';
import getApprovedSummary from '@salesforce/apex/EventExportController.getApprovedSummary';
import exportAllApproved from '@salesforce/apex/EventExportController.exportAllApproved';
import exportApproved from '@salesforce/apex/EventExportController.exportApproved';
import { downloadCsv } from 'c/csvDownload';

export default class ApprovedExport extends LightningElement {
    @track mineOnly = false;
    @track loading = false;

    // Calendar dates as the user picked them (yyyy-MM-dd); Apex reads them in the
    // user's timezone and compares against Decided_At__c, which is stored in GMT.
    @track fromDate = null;
    @track toDate = null;

    wiredSummary;
    summary = [];

    // Only pushed to the wire once the pair is valid, so a half-typed range
    // doesn't fire a query or blank the table.
    appliedFrom = null;
    appliedTo = null;

    @wire(getApprovedSummary, { mineOnly: '$mineOnly', fromDate: '$appliedFrom', toDate: '$appliedTo' })
    handleSummary(result) {
        this.wiredSummary = result;
        if (result.data) this.summary = result.data;
        if (result.error) this.toast('Error', this.messageOf(result.error), 'error');
    }

    get rows() {
        return this.summary.map((s) => ({
            ...s,
            eventUrl: `/lightning/r/Marketing_Event__c/${s.eventId}/view`,
            eventDateLabel: s.eventDate || '—'
        }));
    }

    get hasRows() { return this.summary.length > 0; }
    get eventCount() { return this.summary.length; }
    get totalCount() { return this.summary.reduce((n, s) => n + s.totalCount, 0); }
    get newCount() { return this.summary.reduce((n, s) => n + s.approvedCount, 0); }

    get downloadAllLabel() { return `Download All Approved (${this.totalCount})`; }
    get downloadAllDisabled() { return this.loading || !this.hasRows || this.rangeInvalid; }

    get rangeInvalid() {
        return !!(this.fromDate && this.toDate && this.fromDate > this.toDate);
    }
    get rangeError() {
        return this.rangeInvalid ? 'The "from" date must not be after the "to" date.' : '';
    }
    get hasRange() { return !!(this.fromDate || this.toDate); }
    get clearDisabled() { return this.loading || !this.hasRange; }

    get timeZoneNote() {
        return `Dates are your approval dates (Decided At), read in your timezone — ${TIME_ZONE}. ` +
            'Both ends are inclusive. The Decided At column inside the file stays in GMT, ' +
            'so timestamps near midnight can look like the neighbouring day.';
    }

    get scopeNote() {
        const scope = this.mineOnly
            ? 'Showing only invitees you added'
            : 'Showing every approved invitee you have access to, across all events';
        if (!this.hasRange) return `${scope}, with no date limit.`;
        const from = this.fromDate || 'the beginning';
        const to = this.toDate || 'now';
        return `${scope}, approved between ${from} and ${to}.`;
    }

    handleScopeChange(event) {
        this.mineOnly = event.target.checked;
    }

    handleFromChange(event) {
        this.fromDate = event.target.value || null;
        this.applyRange();
    }

    handleToChange(event) {
        this.toDate = event.target.value || null;
        this.applyRange();
    }

    handleClearRange() {
        this.fromDate = null;
        this.toDate = null;
        this.applyRange();
    }

    applyRange() {
        if (this.rangeInvalid) return;
        this.appliedFrom = this.fromDate;
        this.appliedTo = this.toDate;
    }

    handleDownloadAll() {
        this.runExport(() =>
            exportAllApproved({ mineOnly: this.mineOnly, fromDate: this.fromDate, toDate: this.toDate })
        );
    }

    handleDownloadEvent(event) {
        const eventId = event.target.dataset.id;
        this.runExport(() =>
            exportApproved({ eventId, fromDate: this.fromDate, toDate: this.toDate })
        );
    }

    async runExport(call) {
        if (this.rangeInvalid) {
            this.toast('Check the dates', this.rangeError, 'error');
            return;
        }
        this.loading = true;
        try {
            const res = await call();
            downloadCsv(res.csv, res.fileName);
            const windowNote = res.windowLabel ? ` · ${res.windowLabel}` : '';
            this.toast(
                'Downloaded',
                `${res.rowCount} approved contact(s) from ${res.eventCount} event(s) → ${res.fileName}${windowNote}`,
                'success'
            );
            if (res.truncated) {
                this.toast(
                    'Partial export',
                    'The row cap was reached — narrow the date range or download per event to get the rest.',
                    'warning'
                );
            }
            await refreshApex(this.wiredSummary);
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
