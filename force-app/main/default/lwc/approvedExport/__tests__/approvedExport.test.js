import { createElement } from 'lwc';
import ApprovedExport from 'c/approvedExport';
import { registerApexTestWireAdapter } from '@salesforce/sfdx-lwc-jest';
import getApprovedSummary from '@salesforce/apex/EventExportController.getApprovedSummary';
import exportAllApproved from '@salesforce/apex/EventExportController.exportAllApproved';
import exportApproved from '@salesforce/apex/EventExportController.exportApproved';
import { downloadCsv } from 'c/csvDownload';

jest.mock(
    '@salesforce/apex/EventExportController.exportAllApproved',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock('@salesforce/apex/EventExportController.exportApproved', () => ({ default: jest.fn() }), {
    virtual: true
});
jest.mock('c/csvDownload', () => ({
    downloadCsv: jest.fn(),
    csvRow: jest.fn(),
    csvCell: jest.fn()
}));

const summaryAdapter = registerApexTestWireAdapter(getApprovedSummary);

const flush = async (times = 4) => {
    for (let i = 0; i < times; i++) {
        await new Promise((resolve) => setTimeout(resolve, 0));
    }
};

const SUMMARY = [
    {
        eventId: 'a01000000000001',
        eventName: 'FinTech Summit',
        eventDate: '2026-03-04',
        approvedCount: 3,
        exportedCount: 1,
        totalCount: 4
    },
    {
        eventId: 'a01000000000002',
        eventName: 'Retail Forum',
        eventDate: null,
        approvedCount: 2,
        exportedCount: 0,
        totalCount: 2
    }
];

const EXPORT_RESULT = {
    csv: 'Name,Email\r\nJane,j@x.com',
    fileName: 'approved.csv',
    rowCount: 6,
    eventCount: 2,
    windowLabel: '2026-01-01 → 2026-03-31',
    truncated: false
};

function mount() {
    const element = createElement('c-approved-export', { is: ApprovedExport });
    document.body.appendChild(element);
    return element;
}

const buttons = (element) => [...element.shadowRoot.querySelectorAll('lightning-button')];
const buttonByLabel = (element, label) => buttons(element).find((b) => b.label === label);
const downloadAll = (element) =>
    buttons(element).find((b) => String(b.label).startsWith('Download All'));
// The lightning-input stub carries `type` as a property, not an attribute, so
// these are found by their label instead.
const inputByLabel = (element, label) =>
    [...element.shadowRoot.querySelectorAll('lightning-input')].find((i) => i.label === label);

/** Fires a change on `input` the way the real control would. */
async function change(input, patch) {
    Object.assign(input, patch);
    const event = new CustomEvent('change');
    Object.defineProperty(event, 'target', { value: input, configurable: true });
    input.dispatchEvent(event);
    await flush(1);
}

/** Sets a date field and lets the re-render settle. */
async function setDate(element, which, value) {
    const label = which === 'from' ? 'Approved from' : 'Approved to';
    await change(inputByLabel(element, label), { value });
}

describe('c-approved-export', () => {
    let element;
    let toasts;

    beforeEach(() => {
        exportAllApproved.mockResolvedValue(EXPORT_RESULT);
        exportApproved.mockResolvedValue(EXPORT_RESULT);
        element = mount();
        toasts = [];
        element.addEventListener('lightning__showtoast', (e) => toasts.push(e.detail));
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    describe('summary table', () => {
        it('renders one row per event', async () => {
            summaryAdapter.emit(SUMMARY);
            await flush(1);
            expect(element.shadowRoot.querySelectorAll('tbody tr')).toHaveLength(2);
        });

        it('links each event to its record page', async () => {
            summaryAdapter.emit(SUMMARY);
            await flush(1);
            const link = element.shadowRoot.querySelector('tbody tr a');
            expect(link.href).toContain('/lightning/r/Marketing_Event__c/a01000000000001/view');
        });

        it('shows a dash for an event with no date', async () => {
            summaryAdapter.emit(SUMMARY);
            await flush(1);
            const cells = element.shadowRoot.querySelectorAll('tbody tr:nth-child(2) td');
            expect(cells[1].textContent.trim()).toBe('—');
        });

        it('totals the approved counts in the footer', async () => {
            summaryAdapter.emit(SUMMARY);
            await flush(1);
            const footer = element.shadowRoot.querySelectorAll('tfoot td');
            expect(footer[0].textContent).toContain('2 event(s)');
            expect(footer[1].textContent.trim()).toBe('5'); // 3 + 2 not yet downloaded
            expect(footer[3].textContent.trim()).toBe('6'); // 4 + 2 total
        });

        it('labels the download-all button with the total', async () => {
            summaryAdapter.emit(SUMMARY);
            await flush(1);
            expect(downloadAll(element).label).toBe('Download All Approved (6)');
        });

        it('explains the empty state differently when a range is set', async () => {
            summaryAdapter.emit([]);
            await flush(1);
            expect(element.shadowRoot.textContent).toContain('Nothing approved yet');

            await setDate(element, 'from', '2026-01-01');
            expect(element.shadowRoot.textContent).toContain(
                'Nothing was approved in this date range'
            );
        });

        it('surfaces a wire error as a toast', async () => {
            // The adapter wraps its argument as the error `body`.
            summaryAdapter.error({ message: 'no access' });
            await flush(1);
            expect(toasts.at(-1)).toMatchObject({ variant: 'error', message: 'no access' });
        });

        it('disables download-all when there is nothing to download', async () => {
            summaryAdapter.emit([]);
            await flush(1);
            expect(downloadAll(element).disabled).toBe(true);
        });
    });

    describe('date range validation', () => {
        beforeEach(async () => {
            summaryAdapter.emit(SUMMARY);
            await flush(1);
        });

        it('accepts a range where from precedes to', async () => {
            await setDate(element, 'from', '2026-01-01');
            await setDate(element, 'to', '2026-03-31');
            expect(element.shadowRoot.textContent).not.toContain('must not be after');
            expect(downloadAll(element).disabled).toBe(false);
        });

        it('accepts a single-day range', async () => {
            await setDate(element, 'from', '2026-01-01');
            await setDate(element, 'to', '2026-01-01');
            expect(downloadAll(element).disabled).toBe(false);
        });

        it('rejects an inverted range with a visible message', async () => {
            await setDate(element, 'from', '2026-03-31');
            await setDate(element, 'to', '2026-01-01');
            expect(element.shadowRoot.textContent).toContain(
                'The "from" date must not be after the "to" date.'
            );
        });

        it('disables download-all while the range is inverted', async () => {
            await setDate(element, 'from', '2026-03-31');
            await setDate(element, 'to', '2026-01-01');
            expect(downloadAll(element).disabled).toBe(true);
        });

        it('does not push an inverted range to the wire', async () => {
            // A half-typed range must not fire a query or blank the table. The
            // first date alone is a valid open-ended range and does push; the
            // second one inverts it and must be held back.
            await setDate(element, 'from', '2026-03-31');
            const afterValidEdit = summaryAdapter.getLastConfig();
            await setDate(element, 'to', '2026-01-01');
            expect(summaryAdapter.getLastConfig()).toEqual(afterValidEdit);
            expect(summaryAdapter.getLastConfig().toDate).toBeNull();
        });

        it('pushes a valid range to the wire', async () => {
            await setDate(element, 'from', '2026-01-01');
            expect(summaryAdapter.getLastConfig()).toMatchObject({ fromDate: '2026-01-01' });
        });

        it('treats an open-ended range as valid', async () => {
            await setDate(element, 'to', '2026-03-31');
            expect(downloadAll(element).disabled).toBe(false);
            expect(summaryAdapter.getLastConfig()).toMatchObject({ toDate: '2026-03-31' });
        });

        it('clearing a date empties it rather than storing an empty string', async () => {
            await setDate(element, 'from', '2026-01-01');
            await setDate(element, 'from', '');
            expect(summaryAdapter.getLastConfig().fromDate).toBeNull();
        });

        it('clearing the to date empties it too', async () => {
            await setDate(element, 'to', '2026-03-31');
            await setDate(element, 'to', '');
            expect(summaryAdapter.getLastConfig().toDate).toBeNull();
        });

        it('enables the clear button only once a date is set', async () => {
            expect(buttonByLabel(element, 'Clear dates').disabled).toBe(true);
            await setDate(element, 'from', '2026-01-01');
            expect(buttonByLabel(element, 'Clear dates').disabled).toBe(false);
        });

        it('clearing resets both ends and the wire config', async () => {
            await setDate(element, 'from', '2026-01-01');
            await setDate(element, 'to', '2026-03-31');
            buttonByLabel(element, 'Clear dates').dispatchEvent(new CustomEvent('click'));
            await flush(1);
            expect(summaryAdapter.getLastConfig()).toMatchObject({
                fromDate: null,
                toDate: null
            });
        });

        it('clearing recovers from an inverted range', async () => {
            await setDate(element, 'from', '2026-03-31');
            await setDate(element, 'to', '2026-01-01');
            buttonByLabel(element, 'Clear dates').dispatchEvent(new CustomEvent('click'));
            await flush(1);
            expect(element.shadowRoot.textContent).not.toContain('must not be after');
            expect(downloadAll(element).disabled).toBe(false);
        });
    });

    describe('scope note', () => {
        beforeEach(async () => {
            summaryAdapter.emit(SUMMARY);
            await flush(1);
        });

        it('describes the unlimited, everyone scope by default', () => {
            expect(element.shadowRoot.textContent).toContain(
                'Showing every approved invitee you have access to, across all events, with no date limit.'
            );
        });

        it('switches to the mine-only wording', async () => {
            await change(inputByLabel(element, 'Only invitees I added'), { checked: true });
            expect(element.shadowRoot.textContent).toContain('Showing only invitees you added');
            expect(summaryAdapter.getLastConfig()).toMatchObject({ mineOnly: true });
        });

        it('names both ends of a closed range', async () => {
            await setDate(element, 'from', '2026-01-01');
            await setDate(element, 'to', '2026-03-31');
            expect(element.shadowRoot.textContent).toContain(
                'approved between 2026-01-01 and 2026-03-31'
            );
        });

        it('says "the beginning" for an open start', async () => {
            await setDate(element, 'to', '2026-03-31');
            expect(element.shadowRoot.textContent).toContain(
                'approved between the beginning and 2026-03-31'
            );
        });

        it('says "now" for an open end', async () => {
            await setDate(element, 'from', '2026-01-01');
            expect(element.shadowRoot.textContent).toContain('approved between 2026-01-01 and now');
        });

        it('names the user timezone in the note', () => {
            // The column inside the file stays GMT, so the note has to say which
            // timezone the filter itself used.
            expect(element.shadowRoot.textContent).toMatch(/read in your timezone — \S+/);
        });
    });

    describe('downloading', () => {
        beforeEach(async () => {
            summaryAdapter.emit(SUMMARY);
            await flush(1);
        });

        it('passes the current scope and range to the all-events export', async () => {
            await setDate(element, 'from', '2026-01-01');
            await setDate(element, 'to', '2026-03-31');
            downloadAll(element).dispatchEvent(new CustomEvent('click'));
            await flush();
            expect(exportAllApproved).toHaveBeenCalledWith({
                mineOnly: false,
                fromDate: '2026-01-01',
                toDate: '2026-03-31'
            });
        });

        it('hands the returned csv and file name to the downloader', async () => {
            downloadAll(element).dispatchEvent(new CustomEvent('click'));
            await flush();
            expect(downloadCsv).toHaveBeenCalledWith(EXPORT_RESULT.csv, EXPORT_RESULT.fileName);
        });

        it('reports the row and event counts in a toast', async () => {
            downloadAll(element).dispatchEvent(new CustomEvent('click'));
            await flush();
            expect(toasts.at(-1)).toMatchObject({ variant: 'success' });
            expect(toasts.at(-1).message).toContain('6 approved contact(s) from 2 event(s)');
        });

        it('appends the server window label to the toast', async () => {
            downloadAll(element).dispatchEvent(new CustomEvent('click'));
            await flush();
            expect(toasts.at(-1).message).toContain('2026-01-01 → 2026-03-31');
        });

        it('omits the separator when the server sent no window label', async () => {
            exportAllApproved.mockResolvedValue({ ...EXPORT_RESULT, windowLabel: null });
            downloadAll(element).dispatchEvent(new CustomEvent('click'));
            await flush();
            expect(toasts.at(-1).message).not.toContain('·');
        });

        it('warns separately when the export was truncated', async () => {
            exportAllApproved.mockResolvedValue({ ...EXPORT_RESULT, truncated: true });
            downloadAll(element).dispatchEvent(new CustomEvent('click'));
            await flush();
            expect(toasts.map((t) => t.variant)).toContain('warning');
            expect(toasts.at(-1).message).toContain('row cap was reached');
        });

        it('does not warn when the export was complete', async () => {
            downloadAll(element).dispatchEvent(new CustomEvent('click'));
            await flush();
            expect(toasts.map((t) => t.variant)).not.toContain('warning');
        });

        it('exports a single event with its id and the active range', async () => {
            await setDate(element, 'from', '2026-01-01');
            const perEvent = buttons(element).filter((b) => b.label === 'Download');
            // data-id comes from the template, so this also asserts the row is
            // wired to the right event.
            expect(perEvent[1].dataset.id).toBe('a01000000000002');
            const event = new CustomEvent('click');
            Object.defineProperty(event, 'target', { value: perEvent[1], configurable: true });
            perEvent[1].dispatchEvent(event);
            await flush();
            expect(exportApproved).toHaveBeenCalledWith({
                eventId: 'a01000000000002',
                fromDate: '2026-01-01',
                toDate: null
            });
        });

        it('surfaces an export failure as an error toast', async () => {
            exportAllApproved.mockRejectedValue({ body: { message: 'row limit' } });
            downloadAll(element).dispatchEvent(new CustomEvent('click'));
            await flush();
            expect(toasts.at(-1)).toMatchObject({ variant: 'error', message: 'row limit' });
            expect(downloadCsv).not.toHaveBeenCalled();
        });

        it('falls back to a generic message for an opaque failure', async () => {
            exportAllApproved.mockRejectedValue({});
            downloadAll(element).dispatchEvent(new CustomEvent('click'));
            await flush();
            expect(toasts.at(-1).message).toBe('Unexpected error');
        });

        it('re-enables the button after a failure', async () => {
            exportAllApproved.mockRejectedValue(new Error('boom'));
            downloadAll(element).dispatchEvent(new CustomEvent('click'));
            await flush();
            expect(downloadAll(element).disabled).toBe(false);
        });

        it('refuses to export while the range is inverted', async () => {
            await setDate(element, 'from', '2026-03-31');
            await setDate(element, 'to', '2026-01-01');
            downloadAll(element).dispatchEvent(new CustomEvent('click'));
            await flush();
            expect(exportAllApproved).not.toHaveBeenCalled();
            expect(toasts.at(-1)).toMatchObject({ variant: 'error' });
        });
    });
});
