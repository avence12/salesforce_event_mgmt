import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import previewMatches from '@salesforce/apex/ContactImportController.previewMatches';
import applyChanges from '@salesforce/apex/ContactImportController.applyChanges';
import { downloadCsv, csvRow } from 'c/csvDownload';

const MAX_ROWS = 500;

// Header detection: normalized header cell → canonical field
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

const APPLYABLE = new Set(['NEW_CONTACT', 'NEW_LEAD', 'UPDATE', 'UPDATE_LEAD']);

// Preview order: rows needing a human decision first, then what will be applied,
// then the rows there is nothing to say about. With a 500-row file the two that
// matter would otherwise be buried somewhere in the middle of the wall.
const SORT_RANK = {
    COMPANY_CHANGE: 0, // manual review — the whole reason to read this table
    SKIPPED: 1, // invalid input the user may want to fix and re-upload
    UPDATE: 2,
    UPDATE_LEAD: 3,
    NEW_CONTACT: 4,
    NEW_LEAD: 5,
    UNCHANGED: 6
};

export default class ImportWizard extends LightningElement {
    @track step = 1;
    @track fileName = '';
    @track rowCount = 0;
    @track previewRows = [];
    @track stats = {
        newCount: 0,
        updateCount: 0,
        unchangedCount: 0,
        companyChangeCount: 0,
        skippedCount: 0
    };
    @track applyResult = null;
    @track loading = false;
    @track error = '';

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
        return `Apply ${this.selectedCount} Change${this.selectedCount === 1 ? '' : 's'}`;
    }
    get applyDisabled() {
        return this.loading || this.selectedCount === 0;
    }
    get hasCompanyChanges() {
        return this.stats.companyChangeCount > 0;
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
                    'No data rows found. Expected headers like: First Name, Last Name, Email, Title, Company, Mobile.'
                );
            if (rows.length > MAX_ROWS)
                throw new Error(
                    `File has ${rows.length} rows — the PoC limit is ${MAX_ROWS}. Please split the file.`
                );
            this.rowCount = rows.length;

            const results = await previewMatches({ rows });
            this.buildPreview(results);
            this.step = 2;
        } catch (e) {
            this.error = this.messageOf(e);
        } finally {
            this.loading = false;
            event.target.value = null; // allow re-selecting the same file
        }
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
        // are a delimiter we could not sniff or a file that is not the contact list.
        if (!headers.some(Boolean)) {
            throw new Error(
                `No recognised column headers. The first row read as: ${raw[0].join(' | ')}. ` +
                    'Expected: First Name, Last Name, Email, Title, Company, Mobile.'
            );
        }
        const byEmail = new Map(); // in-file de-dup by email — last occurrence wins
        const noEmail = [];
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
            const key = row.email.toLowerCase();
            if (key) byEmail.set(key, row);
            else noEmail.push(row); // kept so the server reports them as SKIPPED
        }
        return [...byEmail.values(), ...noEmail];
    }

    buildPreview(results) {
        const stats = {
            newCount: 0,
            newLeadCount: 0,
            updateCount: 0,
            unchangedCount: 0,
            companyChangeCount: 0,
            skippedCount: 0
        };
        this.previewRows = results.map((r, idx) => {
            const cls = r.classification;
            if (cls === 'NEW_CONTACT') stats.newCount++;
            else if (cls === 'NEW_LEAD') stats.newLeadCount++;
            else if (cls === 'UPDATE' || cls === 'UPDATE_LEAD') stats.updateCount++;
            else if (cls === 'UNCHANGED') stats.unchangedCount++;
            else if (cls === 'COMPANY_CHANGE') stats.companyChangeCount++;
            else stats.skippedCount++;
            const name = [r.row.firstName, r.row.lastName].filter(Boolean).join(' ') || '(no name)';
            return {
                key: idx,
                row: r.row,
                name,
                email: r.row.email,
                classification: cls,
                typeLabel:
                    {
                        NEW_CONTACT: 'New Contact',
                        NEW_LEAD: 'New Lead',
                        UPDATE: 'Update',
                        UPDATE_LEAD: 'Update Lead',
                        UNCHANGED: 'Unchanged',
                        COMPANY_CHANGE: 'Manual',
                        SKIPPED: 'Skipped'
                    }[cls] || cls,
                badgeClass:
                    cls === 'SKIPPED' || cls === 'COMPANY_CHANGE'
                        ? 'slds-badge slds-theme_warning'
                        : 'slds-badge',
                changeText:
                    (r.changes && r.changes.length ? r.changes.join('; ') : '') ||
                    r.reason ||
                    (cls === 'NEW_CONTACT' ? '— (not found)' : ''),
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
        try {
            const rows = this.previewRows.filter((r) => r.selected).map((r) => r.row);
            this.applyResult = await applyChanges({ rows });
            this.step = 3;
        } catch (e) {
            this.error = this.messageOf(e);
        } finally {
            this.loading = false;
        }
    }

    handleDownloadManualList() {
        // Every value here came out of the uploaded .csv, so it is quoted and
        // formula-guarded rather than trusted — see c/csvDownload.
        const rows = this.previewRows.filter((r) => r.classification === 'COMPANY_CHANGE');
        const lines = ['Name,Email,Current → New Company'];
        rows.forEach((r) => lines.push(csvRow([r.name, r.email, r.changeText])));
        downloadCsv(lines.join('\r\n'), 'company_change_manual_review.csv');
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
