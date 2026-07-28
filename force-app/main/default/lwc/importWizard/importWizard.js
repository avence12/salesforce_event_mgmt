import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import previewMatches from '@salesforce/apex/ContactImportController.previewMatches';
import applyChanges from '@salesforce/apex/ContactImportController.applyChanges';
import { downloadCsv, csvRow } from 'c/csvDownload';

const MAX_ROWS = 500;

// Header detection: normalized header cell → canonical field
const HEADER_MAP = {
    firstname: 'firstName', first: 'firstName', givenname: 'firstName',
    lastname: 'lastName', last: 'lastName', surname: 'lastName', familyname: 'lastName',
    email: 'email', emailaddress: 'email', mail: 'email',
    title: 'title', jobtitle: 'title', position: 'title',
    company: 'company', companyname: 'company', account: 'company', organization: 'company', organisation: 'company',
    mobile: 'mobile', mobilephone: 'mobile', phone: 'mobile', cell: 'mobile'
};

const APPLYABLE = new Set(['NEW_CONTACT', 'UPDATE']);

export default class ImportWizard extends LightningElement {
    @track step = 1;
    @track fileName = '';
    @track rowCount = 0;
    @track previewRows = [];
    @track stats = { newCount: 0, updateCount: 0, unchangedCount: 0, companyChangeCount: 0, skippedCount: 0 };
    @track applyResult = null;
    @track loading = false;
    @track error = '';

    get isStep1() { return this.step === 1; }
    get isStep2() { return this.step === 2; }
    get isStep3() { return this.step === 3; }
    get step1Class() { return this.stepClass(1); }
    get step2Class() { return this.stepClass(2); }
    get step3Class() { return this.stepClass(3); }
    stepClass(n) {
        return 'slds-progress__item' + (this.step === n ? ' slds-is-active' : (this.step > n ? ' slds-is-completed' : ''));
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
            if (rows.length === 0) throw new Error('No data rows found. Expected headers like: First Name, Last Name, Email, Title, Company, Mobile.');
            if (rows.length > MAX_ROWS) throw new Error(`File has ${rows.length} rows — the PoC limit is ${MAX_ROWS}. Please split the file.`);
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
                try {
                    const raw = this.parseCsv(String(reader.result));
                    resolve(this.mapRows(raw));
                } catch (e) {
                    reject(new Error('Not a readable .csv file: ' + e.message));
                }
            };
            reader.readAsText(file, 'UTF-8');
        });
    }

    // Minimal RFC 4180 parser: quoted fields, "" escapes, and CRLF/LF rows.
    parseCsv(text) {
        const src = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text; // strip UTF-8 BOM
        const rows = [];
        let row = [];
        let field = '';
        let inQuotes = false;
        for (let i = 0; i < src.length; i++) {
            const c = src[i];
            if (inQuotes) {
                if (c === '"') {
                    if (src[i + 1] === '"') { field += '"'; i++; }
                    else { inQuotes = false; }
                } else {
                    field += c;
                }
            } else if (c === '"') {
                inQuotes = true;
            } else if (c === ',') {
                row.push(field);
                field = '';
            } else if (c === '\r') {
                // skip — the following \n (if any) ends the row
            } else if (c === '\n') {
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

    mapRows(raw) {
        if (!raw || raw.length < 2) return [];
        const headers = raw[0].map((h) => HEADER_MAP[String(h).toLowerCase().replace(/[^a-z]/g, '')] || null);
        const byEmail = new Map(); // in-file de-dup by email — last occurrence wins
        const noEmail = [];
        for (let i = 1; i < raw.length; i++) {
            const row = { firstName: '', lastName: '', email: '', title: '', company: '', mobile: '' };
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
        const stats = { newCount: 0, updateCount: 0, unchangedCount: 0, companyChangeCount: 0, skippedCount: 0 };
        this.previewRows = results.map((r, idx) => {
            const cls = r.classification;
            if (cls === 'NEW_CONTACT') stats.newCount++;
            else if (cls === 'UPDATE') stats.updateCount++;
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
                typeLabel: { NEW_CONTACT: 'New', UPDATE: 'Update', UNCHANGED: 'Unchanged', COMPANY_CHANGE: 'Manual', SKIPPED: 'Skipped' }[cls] || cls,
                badgeClass: cls === 'SKIPPED' || cls === 'COMPANY_CHANGE' ? 'slds-badge slds-theme_warning' : 'slds-badge',
                changeText: (r.changes && r.changes.length ? r.changes.join('; ') : '') || r.reason || (cls === 'NEW_CONTACT' ? '— (not found)' : ''),
                selectable: APPLYABLE.has(cls),
                selected: APPLYABLE.has(cls),
                disabled: !APPLYABLE.has(cls)
            };
        });
        this.stats = stats;
    }

    handleRowToggle(event) {
        const key = Number(event.target.dataset.key);
        this.previewRows = this.previewRows.map((r) =>
            r.key === key ? { ...r, selected: event.target.checked } : r
        );
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
