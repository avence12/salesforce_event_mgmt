import { LightningElement, track, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getApprovedSummary from '@salesforce/apex/EventExportController.getApprovedSummary';
import exportAllApproved from '@salesforce/apex/EventExportController.exportAllApproved';
import exportApproved from '@salesforce/apex/EventExportController.exportApproved';
import { downloadCsv } from 'c/csvDownload';

export default class ApprovedExport extends LightningElement {
    @track mineOnly = false;
    @track loading = false;

    wiredSummary;
    summary = [];

    @wire(getApprovedSummary, { mineOnly: '$mineOnly' })
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
    get downloadAllDisabled() { return this.loading || !this.hasRows; }

    get scopeNote() {
        return this.mineOnly
            ? 'Showing only invitees you added.'
            : 'Showing every approved invitee you have access to, across all events.';
    }

    handleScopeChange(event) {
        this.mineOnly = event.target.checked;
    }

    handleDownloadAll() {
        this.runExport(() => exportAllApproved({ mineOnly: this.mineOnly }));
    }

    handleDownloadEvent(event) {
        const eventId = event.target.dataset.id;
        this.runExport(() => exportApproved({ eventId }));
    }

    async runExport(call) {
        this.loading = true;
        try {
            const res = await call();
            downloadCsv(res.csv, res.fileName);
            this.toast(
                'Downloaded',
                `${res.rowCount} approved contact(s) from ${res.eventCount} event(s) → ${res.fileName}`,
                'success'
            );
            if (res.truncated) {
                this.toast(
                    'Partial export',
                    'The row cap was reached — download per event to get the rest.',
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
