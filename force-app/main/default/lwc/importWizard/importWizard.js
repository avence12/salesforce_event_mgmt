import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import previewMatches from '@salesforce/apex/AttendeeImportController.previewMatches';
import applyChanges from '@salesforce/apex/AttendeeImportController.applyChanges';
import { downloadCsv, csvRow } from 'c/csvDownload';

// R10: the LWC-enforced total for one uploaded file. A file this large is never
// sent to Apex in one call — see BATCH_SIZE — so this is purely a client-side
// guardrail on how much the browser parses and holds in memory at once.
const MAX_ROWS = 8000;

// R10: rows per Apex call. previewMatches and applyChanges are each called once per
// BATCH_SIZE-row chunk of the parsed file, sequentially, so neither the request
// payload nor a single Apex transaction has to hold the whole file at once. 200 is
// a deliberately conservative starting point — the safe ceiling has not been
// measured against a real org's heap, CPU or LWC-to-Apex payload limits, so this
// errs low rather than finding that ceiling in production. Must stay comfortably
// under AttendeeImportController.MAX_BATCH_ROWS, the server-side per-call guard.
const BATCH_SIZE = 200;

// Header detection: normalized header cell → canonical field.
// `event` is gone with R5: an import records people, not attendance, so a file's
// Event column is simply an unrecognised header now and is ignored like any other.
const HEADER_MAP = {
    firstname: 'firstName',
    first: 'firstName',
    givenname: 'firstName',
    lastname: 'lastName',
    last: 'lastName',
    surname: 'lastName',
    familyname: 'lastName',
    email: 'email',
    emailaddress: 'email',
    mail: 'email',
    title: 'title',
    jobtitle: 'title',
    position: 'title',
    company: 'company',
    companyname: 'company',
    account: 'company',
    organization: 'company',
    organisation: 'company',
    mobile: 'mobile',
    mobilephone: 'mobile',
    phone: 'mobile',
    cell: 'mobile'
};

const APPLYABLE = new Set(['NEW_ATTENDEE', 'EXISTING_ATTENDEE']);

// Preview order: rows the user may want to fix first, then what will be applied.
// With a large file the ones that matter would otherwise be buried mid-wall.
const SORT_RANK = {
    SKIPPED: 0, // invalid input the user may want to fix and re-upload
    NEW_ATTENDEE: 1,
    EXISTING_ATTENDEE: 2
};

/** Splits `rows` into BATCH_SIZE-sized slices, preserving order. */
function chunkRows(rows, size) {
    const batches = [];
    for (let i = 0; i < rows.length; i += size) {
        batches.push(rows.slice(i, i + size));
    }
    return batches;
}

export default class ImportWizard extends LightningElement {
    @track step = 1;
    @track fileName = '';
    @track rowCount = 0;
    @track previewRows = [];
    @track stats = {
        newCount: 0,
        existingCount: 0,
        skippedCount: 0
    };
    @track applyResult = null;
    @track loading = false;
    @track error = '';
    // R10: "batch 3 of 40" so an 8000-row import chunked into sequential Apex calls
    // does not look hung. Blank whenever there is nothing batched to report.
    @track progressLabel = '';

    get isStep1() {
        return this.step === 1;
    }
    get isStep2() {
        return this.step === 2;
    }
    get isStep3() {
        return this.step === 3;
    }
    get step1Class() {
        return this.stepClass(1);
    }
    get step2Class() {
        return this.stepClass(2);
    }
    get step3Class() {
        return this.stepClass(3);
    }
    stepClass(n) {
        return (
            'slds-progress__item' +
            (this.step === n ? ' slds-is-active' : this.step > n ? ' slds-is-completed' : '')
        );
    }

    get selectedCount() {
        return this.previewRows.filter((r) => r.selected).length;
    }
    get applyLabel() {
        return `Import ${this.selectedCount} Attendee${this.selectedCount === 1 ? '' : 's'}`;
    }
    get applyDisabled() {
        return this.loading || this.selectedCount === 0;
    }
    get hasSkipped() {
        return this.stats.skippedCount > 0;
    }
    get hasApplyFailures() {
        return !!(this.applyResult && this.applyResult.attendeesFailed > 0);
    }

    async handleFileChange(event) {
        const file = event.target.files && event.target.files[0];
        if (!file) return;
        this.error = '';
        this.loading = true;
        this.fileName = file.name;
        try {
            const rows = await this.parseFile(file);
            if (rows.length === 0)
                throw new Error(
                    'No data rows found. Expected headers like: First Name, Last Name, Email, Company.'
                );
            if (rows.length > MAX_ROWS)
                throw new Error(
                    `File has ${rows.length} rows — the PoC limit is ${MAX_ROWS}. Please split the file.`
                );
            this.rowCount = rows.length;

            // R10: rows are already de-duplicated across the whole file by mapRows()
            // above, so it is safe to chunk here — no person can land in two
            // batches. Batches are called one at a time, not with Promise.all: parallel
            // calls would multiply concurrent-Apex-request pressure and make the
            // accumulated order non-deterministic.
            const batches = chunkRows(rows, BATCH_SIZE);
            const results = [];
            for (let i = 0; i < batches.length; i++) {
                this.progressLabel = this.batchLabel('Checking', i, batches.length);
                // eslint-disable-next-line no-await-in-loop -- sequential by design, see above
                const batchResults = await previewMatches({ rows: batches[i] });
                results.push(...batchResults);
            }
            this.buildPreview(results);
            this.step = 2;
        } catch (e) {
            this.error = this.messageOf(e);
        } finally {
            this.loading = false;
            this.progressLabel = '';
            event.target.value = null; // allow re-selecting the same file
        }
    }

    /** "Checking batch 3 of 40" — blank when there is only one batch, so a small file says nothing extra. */
    batchLabel(verb, index, total) {
        return total > 1 ? `${verb} batch ${index + 1} of ${total}…` : '';
    }

    parseFile(file) {
        return new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onerror = () => reject(new Error('Could not read the file.'));
            reader.onload = () => {
                let text;
                try {
                    // Decode the bytes ourselves with fatal:true rather than using
                    // readAsText, which substitutes U+FFFD for anything it cannot
                    // decode: a file saved in the local ANSI codepage (Excel's plain
                    // "CSV", not "CSV UTF-8") would otherwise store "Müller" as a
                    // replacement-character mess, silently and past the preview.
                    text = new TextDecoder('utf-8', { fatal: true }).decode(reader.result);
                } catch {
                    reject(
                        new Error(
                            'The file is not UTF-8 text, so non-English characters would be corrupted. ' +
                                'Re-save it in Excel with File → Save As → "CSV UTF-8 (Comma delimited)" and upload again.'
                        )
                    );
                    return;
                }
                try {
                    resolve(this.mapRows(this.parseCsv(text)));
                } catch (e) {
                    reject(e);
                }
            };
            reader.readAsArrayBuffer(file);
        });
    }

    /**
     * Minimal RFC 4180 parser: quoted fields, "" escapes, and CR / LF / CRLF rows.
     * The delimiter is sniffed rather than assumed — Excel in most EU locales writes
     * semicolons because the comma is the decimal separator.
     */
    parseCsv(text) {
        const src = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text; // strip UTF-8 BOM
        const delimiter = this.sniffDelimiter(src);
        const rows = [];
        let row = [];
        let field = '';
        let inQuotes = false;
        for (let i = 0; i < src.length; i++) {
            const c = src[i];
            if (inQuotes) {
                if (c === '"') {
                    if (src[i + 1] === '"') {
                        field += '"';
                        i++;
                    } else {
                        inQuotes = false;
                    }
                } else {
                    field += c;
                }
            } else if (c === '"') {
                inQuotes = true;
            } else if (c === delimiter) {
                row.push(field);
                field = '';
            } else if (c === '\r' || c === '\n') {
                if (c === '\r' && src[i + 1] === '\n') {
                    i++;
                } // CRLF is one terminator
                row.push(field);
                rows.push(row);
                row = [];
                field = '';
            } else {
                field += c;
            }
        }
        if (field !== '' || row.length > 0) {
            row.push(field);
            rows.push(row);
        }
        return rows.filter((r) => r.length > 1 || r[0] !== '');
    }

    /** Delimiter of the header line: comma (default), semicolon (EU Excel) or tab. */
    sniffDelimiter(src) {
        const header = src.split(/\r\n|\r|\n/, 1)[0] || '';
        let best = ',';
        let bestCount = 0;
        [',', ';', '\t'].forEach((candidate) => {
            let count = 0;
            let inQuotes = false;
            for (let i = 0; i < header.length; i++) {
                if (header[i] === '"') inQuotes = !inQuotes;
                else if (header[i] === candidate && !inQuotes) count++;
            }
            if (count > bestCount) {
                bestCount = count;
                best = candidate;
            }
        });
        return best;
    }

    mapRows(raw) {
        if (!raw || raw.length < 2) return [];
        const headers = raw[0].map(
            (h) =>
                HEADER_MAP[
                    String(h)
                        .toLowerCase()
                        .replace(/[^a-z]/g, '')
                ] || null
        );
        // Naming what was actually read beats "no data rows found" — the usual causes
        // are a delimiter we could not sniff or a file that is not an attendee list.
        if (!headers.some(Boolean)) {
            throw new Error(
                `No recognised column headers. The first row read as: ${raw[0].join(' | ')}. ` +
                    'Expected: First Name, Last Name, Email, Company (Title and Mobile are optional).'
            );
        }
        // In-file de-dup mirrors the server's Unique_Key__c exactly: name, company and
        // email are the person's identity, so collapsing here and collapsing there
        // cannot disagree about how many people the file contains.
        const seen = new Map(); // last occurrence wins
        const unkeyed = [];
        for (let i = 1; i < raw.length; i++) {
            const row = {
                firstName: '',
                lastName: '',
                email: '',
                title: '',
                company: '',
                mobile: ''
            };
            headers.forEach((field, col) => {
                if (field && raw[i][col] !== undefined && raw[i][col] !== null) {
                    row[field] = String(raw[i][col]).trim();
                }
            });
            if (!row.firstName && !row.lastName && !row.email) continue; // fully empty line
            const key = [row.lastName, row.firstName, row.company, row.email]
                .map((v) => v.toLowerCase().trim().replace(/\s+/g, ' '))
                .join('|');
            if (row.lastName) seen.set(key, row);
            else unkeyed.push(row); // kept so the server reports them as SKIPPED
        }
        return [...seen.values(), ...unkeyed];
    }

    buildPreview(results) {
        const stats = { newCount: 0, existingCount: 0, skippedCount: 0 };
        this.previewRows = results.map((r, idx) => {
            const cls = r.classification;
            if (cls === 'NEW_ATTENDEE') stats.newCount++;
            else if (cls === 'EXISTING_ATTENDEE') stats.existingCount++;
            else stats.skippedCount++;
            const name = [r.row.firstName, r.row.lastName].filter(Boolean).join(' ') || '(no name)';
            return {
                key: idx,
                row: r.row,
                name,
                email: r.row.email,
                company: r.row.company,
                classification: cls,
                typeLabel:
                    {
                        NEW_ATTENDEE: 'New',
                        EXISTING_ATTENDEE: 'Already known',
                        SKIPPED: 'Skipped'
                    }[cls] || cls,
                badgeClass: cls === 'SKIPPED' ? 'slds-badge slds-theme_warning' : 'slds-badge',
                changeText: r.reason || '',
                selectable: APPLYABLE.has(cls),
                selected: APPLYABLE.has(cls),
                disabled: !APPLYABLE.has(cls)
            };
        });
        // Stable sort: rank first, original file order within a rank. `key` stays the
        // original index, so row toggling is unaffected by the reordering.
        this.previewRows = this.previewRows
            .map((r, i) => ({ r, i }))
            .sort((a, b) => {
                const rank =
                    (SORT_RANK[a.r.classification] ?? 9) - (SORT_RANK[b.r.classification] ?? 9);
                return rank !== 0 ? rank : a.i - b.i;
            })
            .map((x) => x.r);
        this.stats = stats;
    }

    handleRowToggle(event) {
        const key = Number(event.target.dataset.key);
        const checked = event.target.checked;
        this.previewRows = this.previewRows.map((r) => {
            return r.key === key ? { ...r, selected: checked } : r;
        });
    }

    async handleApply() {
        this.loading = true;
        this.error = '';
        const rows = this.previewRows.filter((r) => r.selected).map((r) => r.row);
        const batches = chunkRows(rows, BATCH_SIZE);
        const combined = {
            attendeesCreated: 0,
            attendeesUpdated: 0,
            attendeesFailed: 0,
            failures: []
        };
        let batchesApplied = 0;
        try {
            // R10: one applyChanges call per batch, sequentially — same reasoning as
            // preview. Apply tolerates a bad row within a batch (Database.upsert with
            // allOrNone=false, server-side), but batches themselves are independent:
            // if a whole call throws partway through the file, the batches before it
            // already committed and cannot be rolled back. The catch below says so.
            for (let i = 0; i < batches.length; i++) {
                this.progressLabel = this.batchLabel('Importing', i, batches.length);
                // eslint-disable-next-line no-await-in-loop -- sequential by design, see above
                const batchResult = await applyChanges({
                    rows: batches[i],
                    sourceFile: this.fileName
                });
                combined.attendeesCreated += batchResult.attendeesCreated || 0;
                combined.attendeesUpdated += batchResult.attendeesUpdated || 0;
                combined.attendeesFailed += batchResult.attendeesFailed || 0;
                combined.failures.push(...(batchResult.failures || []));
                batchesApplied += 1;
            }
            this.applyResult = combined;
            this.step = 3;
        } catch (e) {
            this.error =
                batchesApplied > 0
                    ? `${this.messageOf(e)} (this was batch ${batchesApplied + 1} of ${batches.length} — ` +
                      `the ${batchesApplied} batch${batchesApplied === 1 ? '' : 'es'} before it were already ` +
                      `applied and were not rolled back; fix the file and re-upload it, which is safe because ` +
                      `the import refreshes the same attendees rather than duplicating them)`
                    : this.messageOf(e);
        } finally {
            this.loading = false;
            this.progressLabel = '';
        }
    }

    handleDownloadSkippedList() {
        // Every value here came out of the uploaded .csv, so it is quoted and
        // formula-guarded rather than trusted — see c/csvDownload.
        const rows = this.previewRows.filter((r) => r.classification === 'SKIPPED');
        const lines = ['Name,Email,Company,Why it was skipped'];
        rows.forEach((r) => lines.push(csvRow([r.name, r.email, r.row.company, r.changeText])));
        downloadCsv(lines.join('\r\n'), 'skipped_rows_manual_review.csv');
    }

    handleDownloadFailedList() {
        // Same guard as the skipped-row download and for the same reason: every
        // value here is an Apex echo of something an uploaded .csv contained.
        const failures = (this.applyResult && this.applyResult.failures) || [];
        const lines = ['Name,Email,Company,Why it failed'];
        failures.forEach((f) => {
            const name = [f.row.firstName, f.row.lastName].filter(Boolean).join(' ') || '(no name)';
            lines.push(csvRow([name, f.row.email, f.row.company, f.message]));
        });
        downloadCsv(lines.join('\r\n'), 'failed_rows_manual_review.csv');
    }

    handleBack() {
        this.step = 1;
        this.previewRows = [];
        this.error = '';
    }

    handleStartOver() {
        this.handleBack();
        this.applyResult = null;
        this.fileName = '';
        this.rowCount = 0;
    }

    messageOf(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Unexpected error';
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
