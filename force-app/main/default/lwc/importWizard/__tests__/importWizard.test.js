import { createElement } from 'lwc';
import ImportWizard from 'c/importWizard';
import previewMatches from '@salesforce/apex/ContactImportController.previewMatches';
import applyChanges from '@salesforce/apex/ContactImportController.applyChanges';
import { downloadCsv } from 'c/csvDownload';

jest.mock(
    '@salesforce/apex/ContactImportController.previewMatches',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock('@salesforce/apex/ContactImportController.applyChanges', () => ({ default: jest.fn() }), {
    virtual: true
});

// downloadCsv touches the DOM and the object-URL registry; csvRow stays real so
// the manual-review file is asserted with the production quoting rules.
jest.mock('c/csvDownload', () => {
    const actual = jest.requireActual('c/csvDownload');
    return { ...actual, downloadCsv: jest.fn() };
});

/**
 * These specs drive the component through its real entry point — a file landing
 * on the input — rather than reaching for internal methods. The parser is the
 * risk centre of the import (its inputs are real-world spreadsheet exports: EU
 * Excel semicolons, CRLF, BOMs, quoted commas, ANSI encodings), and what it
 * produced is observable as the `rows` argument handed to the Apex call.
 */

/** Waits out the FileReader and the awaits chained after it. */
const flush = async (times = 8) => {
    for (let i = 0; i < times; i++) {
        await new Promise((resolve) => setTimeout(resolve, 0));
    }
};

function mountWizard() {
    const element = createElement('c-import-wizard', { is: ImportWizard });
    document.body.appendChild(element);
    return element;
}

/** Feeds `content` (string → UTF-8, or raw bytes) to the file input. */
async function upload(element, content, fileName = 'contacts.csv') {
    const bytes = typeof content === 'string' ? new TextEncoder().encode(content) : content;
    const file = new File([bytes], fileName, { type: 'text/csv' });
    const input = element.shadowRoot.querySelector('lightning-input');
    Object.defineProperty(input, 'files', { value: [file], configurable: true });

    // handleFileChange is async and still touches event.target after its awaits.
    // jsdom clears an event's target once dispatch returns, where a real browser
    // keeps it, so pin it to survive the await.
    const changeEvent = new CustomEvent('change');
    Object.defineProperty(changeEvent, 'target', { value: input, configurable: true });
    input.dispatchEvent(changeEvent);
    await flush();
}

/** The `rows` array the component sent to previewMatches on the last upload. */
const sentRows = () => previewMatches.mock.calls.at(-1)[0].rows;

const text = (element, selector) => {
    const node = element.shadowRoot.querySelector(selector);
    return node ? node.textContent.trim() : null;
};

const HEADER = 'First Name,Last Name,Email,Title,Company,Mobile,Event';

/** Minimal previewMatches response echoing each row back as a matched contact. */
const echoPreview = (rows) =>
    rows.map((row) => ({
        row,
        classification: 'MATCHED_CONTACT',
        matchBasis: 'Name',
        candidates: [],
        reason: ''
    }));

describe('c-import-wizard', () => {
    let element;

    beforeEach(() => {
        previewMatches.mockImplementation(({ rows }) => Promise.resolve(echoPreview(rows)));
        applyChanges.mockResolvedValue({ tagsRecorded: 0, leadsCreated: 0 });
        element = mountWizard();
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    describe('delimiter sniffing', () => {
        it('reads a comma-separated file', async () => {
            await upload(element, `${HEADER}\nJane,Doe,j@x.com,CTO,Acme,0912`);
            expect(sentRows()[0]).toMatchObject({ firstName: 'Jane', email: 'j@x.com' });
        });

        it('reads the semicolons EU Excel writes', async () => {
            await upload(
                element,
                'First Name;Last Name;Email;Title;Company;Mobile\nJane;Doe;j@x.com;CTO;Acme;0912'
            );
            expect(sentRows()[0]).toMatchObject({ firstName: 'Jane', company: 'Acme' });
        });

        it('reads a tab-separated file', async () => {
            await upload(element, 'First Name\tLast Name\tEmail\nJane\tDoe\tj@x.com');
            expect(sentRows()[0]).toMatchObject({ firstName: 'Jane', lastName: 'Doe' });
        });

        it('sniffs from the header only, ignoring delimiter-heavy data', async () => {
            await upload(element, `First Name,Email\n"a;b;c;d",j@x.com`);
            expect(sentRows()[0].firstName).toBe('a;b;c;d');
        });

        it('ignores a delimiter inside a quoted header cell', async () => {
            await upload(element, `"Last, First";Email\nDoe;j@x.com`);
            expect(sentRows()[0]).toMatchObject({ email: 'j@x.com' });
        });
    });

    describe('RFC 4180 parsing', () => {
        it('keeps a comma inside a quoted field', async () => {
            await upload(element, `First Name,Email\n"Doe, Jane",j@x.com`);
            expect(sentRows()[0].firstName).toBe('Doe, Jane');
        });

        it('unescapes a doubled quote', async () => {
            await upload(element, `First Name,Email\n"He said ""hi""",j@x.com`);
            expect(sentRows()[0].firstName).toBe('He said "hi"');
        });

        it('keeps a newline inside a quoted field', async () => {
            await upload(element, `First Name,Email\n"line1\nline2",j@x.com`);
            expect(sentRows()[0].firstName).toBe('line1\nline2');
        });

        it('treats CRLF as a single row terminator', async () => {
            await upload(element, `${HEADER}\r\nJane,Doe,j@x.com,,,\r\nJohn,Roe,r@x.com,,,`);
            expect(sentRows()).toHaveLength(2);
        });

        it('handles bare CR terminators', async () => {
            await upload(element, `First Name,Email\rJane,j@x.com\rJohn,r@x.com`);
            expect(sentRows()).toHaveLength(2);
        });

        it('strips a leading UTF-8 BOM so the first header still matches', async () => {
            // Left in place the first header reads as "\uFEFFfirstname", matches
            // nothing, and the file looks headerless.
            await upload(element, `\uFEFF${HEADER}\nJane,Doe,j@x.com,,,`);
            expect(sentRows()[0].firstName).toBe('Jane');
        });

        it('ignores a trailing newline rather than emitting a blank row', async () => {
            await upload(element, `${HEADER}\nJane,Doe,j@x.com,,,\n`);
            expect(sentRows()).toHaveLength(1);
        });

        it('drops blank lines between records', async () => {
            await upload(element, `${HEADER}\nJane,Doe,j@x.com,,,\n\nJohn,Roe,r@x.com,,,`);
            expect(sentRows()).toHaveLength(2);
        });

        it('preserves empty fields between delimiters', async () => {
            await upload(element, `${HEADER}\nJane,Doe,j@x.com,,Acme,`);
            expect(sentRows()[0]).toMatchObject({ title: '', company: 'Acme', mobile: '' });
        });

        it('tolerates a short row missing trailing columns', async () => {
            await upload(element, `${HEADER}\nJane,Doe,j@x.com`);
            expect(sentRows()[0]).toMatchObject({ company: '', mobile: '' });
        });
    });

    describe('header mapping', () => {
        it.each([
            ['Given Name', 'firstName'],
            ['First', 'firstName'],
            ['Surname', 'lastName'],
            ['Family Name', 'lastName'],
            ['Last', 'lastName'],
            ['E-mail Address', 'email'],
            ['Mail', 'email'],
            ['Job Title', 'title'],
            ['Position', 'title'],
            ['Organisation', 'company'],
            ['Organization', 'company'],
            ['Account', 'company'],
            ['Mobile Phone', 'mobile'],
            ['Cell', 'mobile'],
            ['Phone', 'mobile']
        ])('recognises the %s alias', async (header, field) => {
            // Needs a second identifying column so the row survives the
            // "fully empty line" filter — chosen so it never maps to the same
            // canonical field as the alias under test.
            const anchor = field === 'email' ? ['Last Name', 'Doe'] : ['Email', 'a@x.com'];
            await upload(element, `${header},${anchor[0]}\nvalue,${anchor[1]}`);
            expect(sentRows()[0][field]).toBe('value');
        });

        it('normalises case, spaces and punctuation in headers', async () => {
            await upload(element, `  FIRST_NAME  ,e-mail\nJane,j@x.com`);
            expect(sentRows()[0].firstName).toBe('Jane');
        });

        it('ignores an unrecognised column instead of failing the file', async () => {
            await upload(element, `Email,Loyalty Points\nj@x.com,900`);
            expect(sentRows()[0].email).toBe('j@x.com');
            expect(sentRows()[0]).not.toHaveProperty('Loyalty Points');
        });

        it('trims surrounding whitespace from values', async () => {
            await upload(element, `First Name,Email\n  Jane  , j@x.com `);
            expect(sentRows()[0]).toMatchObject({ firstName: 'Jane', email: 'j@x.com' });
        });
    });

    describe('row de-duplication', () => {
        // The key is the whole person plus the event: an email is no longer a row's
        // identity, and the same person at two events is two facts, not a duplicate.
        it('collapses rows identical in person and event, last occurrence winning', async () => {
            await upload(
                element,
                `${HEADER}\nJane,Doe,j@x.com,,Acme,,Summit\nJane,Doe,j@x.com,,Acme,,Summit`
            );
            expect(sentRows()).toHaveLength(1);
        });

        it('keeps the same person at two different events', async () => {
            await upload(
                element,
                `${HEADER}\nJane,Doe,j@x.com,,Acme,,Summit\nJane,Doe,j@x.com,,Acme,,DevCon`
            );
            expect(sentRows()).toHaveLength(2);
            expect(sentRows().map((r) => r.event)).toEqual(['Summit', 'DevCon']);
        });

        it('keeps two different people who share an email', async () => {
            await upload(
                element,
                `${HEADER}\nJane,Doe,shared@x.com,,Acme,,Summit\nJohn,Roe,shared@x.com,,Acme,,Summit`
            );
            expect(sentRows()).toHaveLength(2);
        });

        it('keeps rows with no event so the server can report them as skipped', async () => {
            await upload(element, `${HEADER}\nA,One,a@x.com,,,,\nB,Two,b@x.com,,,,`);
            expect(sentRows()).toHaveLength(2);
        });

        it('orders keyed rows ahead of the unkeyed ones', async () => {
            await upload(
                element,
                `${HEADER}\nNoEvent,One,a@x.com,,,,\nHas,Event,b@x.com,,,,Summit`
            );
            expect(sentRows().map((r) => r.firstName)).toEqual(['Has', 'NoEvent']);
        });

        it('skips a fully empty data line', async () => {
            await upload(element, `${HEADER}\n,,,,,,\nJane,Doe,j@x.com,,,,Summit`);
            expect(sentRows()).toHaveLength(1);
        });
    });

    describe('rejected files', () => {
        const errorText = () => text(element, '[role="alert"]');

        it('rejects a file that is not UTF-8 with a re-save instruction', async () => {
            // Excel's plain "CSV" writes the local ANSI codepage; decoding it as
            // UTF-8 would silently turn "Müller" into replacement characters.
            const latin1 = new Uint8Array([
                ...new TextEncoder().encode('First Name,Email\nM'),
                0xfc, // 'ü' in Latin-1 — invalid as standalone UTF-8
                ...new TextEncoder().encode('ller,j@x.com')
            ]);
            await upload(element, latin1);
            expect(errorText()).toMatch(/CSV UTF-8/);
            expect(previewMatches).not.toHaveBeenCalled();
        });

        it('names the row it actually read when no header matches', async () => {
            await upload(element, 'col1,col2\na,b');
            expect(errorText()).toMatch(/col1 \| col2/);
            expect(previewMatches).not.toHaveBeenCalled();
        });

        it('rejects a header-only file as having no data rows', async () => {
            await upload(element, HEADER);
            expect(errorText()).toMatch(/No data rows/);
        });

        it('rejects a file over the 500-row PoC cap and says the count', async () => {
            const rows = Array.from(
                { length: 501 },
                (_unused, i) => `A${i},B${i},u${i}@x.com,,,`
            ).join('\n');
            await upload(element, `${HEADER}\n${rows}`);
            expect(errorText()).toMatch(/501 rows/);
            expect(previewMatches).not.toHaveBeenCalled();
        });

        it('accepts a file exactly at the cap', async () => {
            const rows = Array.from(
                { length: 500 },
                (_unused, i) => `A${i},B${i},u${i}@x.com,,,`
            ).join('\n');
            await upload(element, `${HEADER}\n${rows}`);
            expect(previewMatches).toHaveBeenCalled();
            expect(errorText()).toBeNull();
        });

        it('surfaces an Apex failure as the error message', async () => {
            previewMatches.mockRejectedValue({ body: { message: 'apex said no' } });
            await upload(element, `${HEADER}\nJane,Doe,j@x.com,,,`);
            expect(errorText()).toBe('apex said no');
        });

        it('stays on step 1 when the file is rejected', async () => {
            await upload(element, 'col1,col2\na,b');
            expect(element.shadowRoot.querySelector('lightning-input')).not.toBeNull();
        });
    });

    describe('preview step', () => {
        const classify = (classifications) => {
            previewMatches.mockImplementation(({ rows }) =>
                Promise.resolve(
                    rows.map((row, i) => ({
                        row,
                        classification: classifications[i],
                        matchBasis: '',
                        candidates: [],
                        reason: ''
                    }))
                )
            );
        };

        const fiveRows =
            `${HEADER}\nA,1,a@x.com,,,,Summit\nB,2,b@x.com,,,,Summit\nC,3,c@x.com,,,,Summit` +
            `\nD,4,d@x.com,,,,Summit\nE,5,e@x.com,,,,Summit`;

        const statValues = () =>
            [...element.shadowRoot.querySelectorAll('.stat b')].map((n) => n.textContent);

        // Tiles, in order: matched contacts, matched leads, new leads, ambiguous, skipped.
        it('counts each classification into its own tile', async () => {
            classify(['MATCHED_CONTACT', 'MATCHED_LEAD', 'NEW_LEAD', 'AMBIGUOUS', 'SKIPPED']);
            await upload(element, fiveRows);
            expect(statValues()).toEqual(['1', '1', '1', '1', '1']);
        });

        it('counts an unknown classification as skipped rather than dropping it', async () => {
            classify(['SOMETHING_NEW']);
            await upload(element, `${HEADER}\nA,1,a@x.com,,,,Summit`);
            expect(statValues()[4]).toBe('1');
        });

        it('renders one table row per preview row', async () => {
            classify(['MATCHED_CONTACT', 'MATCHED_LEAD', 'NEW_LEAD', 'AMBIGUOUS', 'SKIPPED']);
            await upload(element, fiveRows);
            expect(element.shadowRoot.querySelectorAll('tbody tr')).toHaveLength(5);
        });

        describe('preview ordering', () => {
            const typeColumn = () =>
                [...element.shadowRoot.querySelectorAll('tbody tr')].map((r) =>
                    r.querySelector('td:last-child').textContent.trim()
                );

            it('puts the rows needing a decision above the rest', async () => {
                // Server order deliberately buries the two that matter.
                classify(['MATCHED_LEAD', 'MATCHED_CONTACT', 'SKIPPED', 'NEW_LEAD', 'AMBIGUOUS']);
                await upload(element, fiveRows);
                expect(typeColumn()).toEqual([
                    'Ambiguous',
                    'Skipped',
                    'Matched',
                    'Matched Lead',
                    'New Lead'
                ]);
            });

            it('keeps file order within one classification', async () => {
                classify(['MATCHED_CONTACT', 'AMBIGUOUS', 'MATCHED_CONTACT']);
                await upload(
                    element,
                    `${HEADER}\nA,1,a@x.com,,,,S\nB,2,b@x.com,,,,S\nC,3,c@x.com,,,,S`
                );
                const names = [...element.shadowRoot.querySelectorAll('tbody tr')].map((r) =>
                    r.querySelector('td:nth-child(2)').textContent.trim()
                );
                expect(names).toEqual(['B 2', 'A 1', 'C 3']);
            });

            it('still applies the row the user unticks after the reorder', async () => {
                // Sorting must not desynchronise a row from its checkbox.
                classify(['SKIPPED', 'MATCHED_LEAD', 'AMBIGUOUS', 'MATCHED_CONTACT']);
                await upload(
                    element,
                    `${HEADER}\nA,1,a@x.com,,,,S\nB,2,b@x.com,,,,S\nC,3,c@x.com,,,,S\nD,4,d@x.com,,,,S`
                );
                const boxes = [...element.shadowRoot.querySelectorAll('tbody input')];
                const updateBox = boxes[3]; // order: Ambiguous, Skipped, Matched, Matched Lead
                updateBox.checked = false;
                updateBox.dispatchEvent(new CustomEvent('change'));
                await flush(1);
                const applyLabel = [...element.shadowRoot.querySelectorAll('lightning-button')]
                    .map((b) => String(b.label))
                    .find((l) => l.startsWith('Apply'));
                expect(applyLabel).toBe('Apply 1 Change');
            });
        });

        it.each([
            ['MATCHED_CONTACT', true],
            ['MATCHED_LEAD', true],
            ['NEW_LEAD', true],
            ['AMBIGUOUS', false],
            ['SKIPPED', false]
        ])('pre-selects %s rows: %s', async (classification, selected) => {
            classify([classification]);
            await upload(element, `${HEADER}\nA,1,a@x.com,,,,Summit`);
            const box = element.shadowRoot.querySelector('tbody input[type="checkbox"]');
            expect(box.checked).toBe(selected);
            expect(box.disabled).toBe(!selected);
        });

        it('shows a placeholder when a row has no name', async () => {
            classify(['SKIPPED']);
            await upload(element, `Email\na@x.com`);
            expect(text(element, 'tbody tr td:nth-child(2)')).toBe('(no name)');
        });

        it('joins first and last name for display', async () => {
            classify(['MATCHED_CONTACT']);
            await upload(element, `${HEADER}\nJane,Doe,j@x.com,,,,Summit`);
            expect(text(element, 'tbody tr td:nth-child(2)')).toBe('Jane Doe');
        });

        it('warns visually on rows that need a human', async () => {
            classify(['AMBIGUOUS', 'MATCHED_CONTACT']);
            await upload(element, `${HEADER}\nA,1,a@x.com,,,,S\nB,2,b@x.com,,,,S`);
            const badges = element.shadowRoot.querySelectorAll('tbody tr td:nth-child(5) span');
            expect(badges[0].className).toContain('warning');
            expect(badges[1].className).not.toContain('warning');
        });

        it('names the candidates it could not separate, above anything else', async () => {
            previewMatches.mockResolvedValue([
                {
                    row: { firstName: 'A', lastName: '1', email: 'a@x.com' },
                    classification: 'AMBIGUOUS',
                    matchBasis: '',
                    candidates: ['Jane Doe (Acme)', 'Jane Doe (Globex)'],
                    reason: 'ignored when candidates are known'
                }
            ]);
            await upload(element, `${HEADER}\nA,1,a@x.com,,,,Summit`);
            expect(text(element, 'tbody tr td:nth-child(4)')).toBe(
                'Could not separate: Jane Doe (Acme) | Jane Doe (Globex)'
            );
        });

        it('says how a match was reached, so a name-only match does not look certain', async () => {
            previewMatches.mockResolvedValue([
                {
                    row: { firstName: 'A', lastName: '1', email: 'a@x.com' },
                    classification: 'MATCHED_CONTACT',
                    matchBasis: 'Name',
                    candidates: [],
                    reason: ''
                }
            ]);
            await upload(element, `${HEADER}\nA,1,a@x.com,,,,Summit`);
            expect(text(element, 'tbody tr td:nth-child(4)')).toBe('Matched on Name');
        });

        it('falls back to the reason when there is neither', async () => {
            previewMatches.mockResolvedValue([
                {
                    row: { firstName: 'A', lastName: '1', email: '' },
                    classification: 'SKIPPED',
                    matchBasis: '',
                    candidates: [],
                    reason: 'No event value'
                }
            ]);
            await upload(element, `${HEADER}\nA,1,,,,,`);
            expect(text(element, 'tbody tr td:nth-child(4)')).toBe('No event value');
        });

        it('labels the apply button with the selected count, pluralised', async () => {
            classify(['MATCHED_CONTACT', 'MATCHED_LEAD', 'SKIPPED']);
            await upload(
                element,
                `${HEADER}\nA,1,a@x.com,,,,S\nB,2,b@x.com,,,,S\nC,3,c@x.com,,,,S`
            );
            const buttons = [...element.shadowRoot.querySelectorAll('lightning-button')];
            expect(buttons.some((b) => b.label === 'Apply 2 Changes')).toBe(true);
        });

        it('singularises the apply label for one change', async () => {
            classify(['MATCHED_CONTACT', 'SKIPPED']);
            await upload(element, `${HEADER}\nA,1,a@x.com,,,,S\nB,2,b@x.com,,,,S`);
            const buttons = [...element.shadowRoot.querySelectorAll('lightning-button')];
            expect(buttons.some((b) => b.label === 'Apply 1 Change')).toBe(true);
        });

        it('disables apply when nothing is selectable', async () => {
            classify(['SKIPPED']);
            await upload(element, `${HEADER}\nA,1,a@x.com,,,,Summit`);
            const apply = [...element.shadowRoot.querySelectorAll('lightning-button')].find((b) =>
                String(b.label).startsWith('Apply')
            );
            expect(apply.disabled).toBe(true);
        });

        it('offers the manual-review download only when something is ambiguous', async () => {
            classify(['MATCHED_CONTACT']);
            await upload(element, `${HEADER}\nA,1,a@x.com,,,,Summit`);
            const labels = [...element.shadowRoot.querySelectorAll('lightning-button')].map(
                (b) => b.label
            );
            expect(labels).not.toContain('Download Manual-Review List');
        });

        it('offers the manual-review download when a row is ambiguous', async () => {
            classify(['AMBIGUOUS']);
            await upload(element, `${HEADER}\nA,1,a@x.com,,,,Summit`);
            const labels = [...element.shadowRoot.querySelectorAll('lightning-button')].map(
                (b) => b.label
            );
            expect(labels).toContain('Download Manual-Review List');
        });

        it('deselecting a row lowers the apply count', async () => {
            classify(['MATCHED_CONTACT', 'MATCHED_LEAD']);
            await upload(element, `${HEADER}\nA,1,a@x.com,,,,S\nB,2,b@x.com,,,,S`);
            const box = element.shadowRoot.querySelector('tbody input[type="checkbox"]');
            box.checked = false;
            box.dispatchEvent(new CustomEvent('change'));
            await flush(1);
            const labels = [...element.shadowRoot.querySelectorAll('lightning-button')].map(
                (b) => b.label
            );
            expect(labels).toContain('Apply 1 Change');
        });
    });

    describe('apply step', () => {
        it('sends only the selected rows to Apex', async () => {
            previewMatches.mockImplementation(({ rows }) =>
                Promise.resolve(
                    rows.map((row, i) => ({
                        row,
                        classification: i === 0 ? 'MATCHED_CONTACT' : 'SKIPPED',
                        matchBasis: '',
                        candidates: [],
                        reason: ''
                    }))
                )
            );
            await upload(element, `${HEADER}\nA,1,a@x.com,,,,S\nB,2,b@x.com,,,,S`);
            const apply = [...element.shadowRoot.querySelectorAll('lightning-button')].find((b) =>
                String(b.label).startsWith('Apply')
            );
            apply.dispatchEvent(new CustomEvent('click'));
            await flush();
            expect(applyChanges).toHaveBeenCalledTimes(1);
            expect(applyChanges.mock.calls[0][0].rows).toHaveLength(1);
            expect(applyChanges.mock.calls[0][0].rows[0].email).toBe('a@x.com');
            // The file name travels with the rows so a questionable tag can be traced back.
            expect(applyChanges.mock.calls[0][0].sourceFile).toBe('contacts.csv');
        });

        it('shows the tag and lead counts on success', async () => {
            applyChanges.mockResolvedValue({ tagsRecorded: 3, leadsCreated: 2 });
            await upload(element, `${HEADER}\nA,1,a@x.com,,,,Summit`);
            const apply = [...element.shadowRoot.querySelectorAll('lightning-button')].find((b) =>
                String(b.label).startsWith('Apply')
            );
            apply.dispatchEvent(new CustomEvent('click'));
            await flush();
            expect(element.shadowRoot.textContent).toContain('Import complete');
            expect(element.shadowRoot.textContent).toContain('3');
        });

        it('surfaces an apply failure without advancing the step', async () => {
            applyChanges.mockRejectedValue({ body: { message: 'row locked' } });
            await upload(element, `${HEADER}\nA,1,a@x.com,,,,Summit`);
            const apply = [...element.shadowRoot.querySelectorAll('lightning-button')].find((b) =>
                String(b.label).startsWith('Apply')
            );
            apply.dispatchEvent(new CustomEvent('click'));
            await flush();
            expect(text(element, '[role="alert"]')).toBe('row locked');
            expect(element.shadowRoot.textContent).not.toContain('Import complete');
        });
    });

    describe('manual-review download', () => {
        const clickManualDownload = () =>
            [...element.shadowRoot.querySelectorAll('lightning-button')]
                .find((b) => b.label === 'Download Manual-Review List')
                .dispatchEvent(new CustomEvent('click'));

        const ambiguousOnly = (candidates = ['Jane Doe (Acme)', 'Jane Doe (Globex)']) => {
            previewMatches.mockImplementation(({ rows }) =>
                Promise.resolve(
                    rows.map((row) => ({
                        row,
                        classification: 'AMBIGUOUS',
                        matchBasis: '',
                        candidates,
                        reason: ''
                    }))
                )
            );
        };

        it('writes a header row and one line per ambiguous row', async () => {
            ambiguousOnly();
            await upload(element, `${HEADER}\nJane,Doe,j@x.com,,Acme,,Summit`);
            clickManualDownload();
            const [csv, fileName] = downloadCsv.mock.calls[0];
            expect(csv.split('\r\n')).toEqual([
                'Name,Email,Company,Event,Could not separate',
                'Jane Doe,j@x.com,Acme,Summit,Jane Doe (Acme) | Jane Doe (Globex)'
            ]);
            expect(fileName).toBe('ambiguous_matches_manual_review.csv');
        });

        it('excludes rows that were not ambiguous', async () => {
            previewMatches.mockImplementation(({ rows }) =>
                Promise.resolve(
                    rows.map((row, i) => ({
                        row,
                        classification: i === 0 ? 'AMBIGUOUS' : 'MATCHED_CONTACT',
                        matchBasis: i === 0 ? '' : 'Name',
                        candidates: i === 0 ? ['One', 'Two'] : [],
                        reason: ''
                    }))
                )
            );
            await upload(element, `${HEADER}\nJane,Doe,j@x.com,,,,S\nJohn,Roe,r@x.com,,,,S`);
            clickManualDownload();
            const [csv] = downloadCsv.mock.calls[0];
            expect(csv.split('\r\n')).toHaveLength(2);
            expect(csv).not.toContain('r@x.com');
        });

        it('neutralises a formula smuggled in through the uploaded name', async () => {
            // Every value here came out of an untrusted .csv, so the file it
            // writes back out must not be executable when Excel opens it.
            ambiguousOnly();
            await upload(element, `${HEADER}\n"=HYPERLINK(""http://evil"")",Doe,j@x.com,,,,S`);
            clickManualDownload();
            const [csv] = downloadCsv.mock.calls[0];
            expect(csv).toContain('"\'=HYPERLINK(""http://evil"") Doe"');
            expect(csv).not.toMatch(/,=HYPERLINK/);
        });

        describe('after the import has been applied', () => {
            // The results step used to only *mention* the manual-review list and
            // point back at a step with no way to return to it: miss the download
            // once and the list was gone for good.
            /** One ambiguous row plus one applyable row, so Apply is live. */
            const mixedPreview = () =>
                previewMatches.mockImplementation(({ rows }) =>
                    Promise.resolve(
                        rows.map((row, i) => ({
                            row,
                            classification: i === 0 ? 'AMBIGUOUS' : 'MATCHED_CONTACT',
                            matchBasis: i === 0 ? '' : 'Name',
                            candidates: i === 0 ? ['Jane Doe (Acme)', 'Jane Doe (Globex)'] : [],
                            reason: ''
                        }))
                    )
                );

            const reachResultsStep = async () => {
                mixedPreview();
                applyChanges.mockResolvedValue({ tagsRecorded: 1, leadsCreated: 0 });
                await upload(
                    element,
                    `${HEADER}\nJane,Doe,j@x.com,,Acme,,Summit\nJohn,Roe,r@x.com,,,,Summit`
                );
                const apply = [...element.shadowRoot.querySelectorAll('lightning-button')].find(
                    (b) => String(b.label).startsWith('Apply')
                );
                expect(apply.disabled).toBe(false); // otherwise the click below is a no-op
                apply.dispatchEvent(new CustomEvent('click'));
                await flush();
                expect(element.shadowRoot.textContent).toContain('Import complete');
            };

            it('still offers the download once the import is done', async () => {
                await reachResultsStep();
                clickManualDownload();
                const [csv] = downloadCsv.mock.calls[0];
                expect(csv).toContain('Jane Doe,j@x.com,Acme,Summit,Jane Doe (Acme)');
            });

            it('says how many rows were left behind, and that leaving discards them', async () => {
                await reachResultsStep();
                const results = element.shadowRoot.textContent;
                expect(results).toContain('1');
                expect(results).toContain('could not be told');
                expect(results).toContain('Starting another import discards it');
            });
        });
    });

    describe('navigation', () => {
        it('starts on the upload step', () => {
            expect(element.shadowRoot.querySelector('lightning-input')).not.toBeNull();
        });

        it('marks the current step active in the progress bar', () => {
            const items = element.shadowRoot.querySelectorAll('.slds-progress__list li');
            expect(items[0].className).toContain('slds-is-active');
            expect(items[2].className).toBe('slds-progress__item');
        });

        it('marks a passed step completed', async () => {
            await upload(element, `${HEADER}\nA,1,a@x.com,,,`);
            const items = element.shadowRoot.querySelectorAll('.slds-progress__list li');
            expect(items[0].className).toContain('slds-is-completed');
            expect(items[1].className).toContain('slds-is-active');
        });

        it('going back returns to the upload step and clears the preview', async () => {
            await upload(element, `${HEADER}\nA,1,a@x.com,,,`);
            const back = [...element.shadowRoot.querySelectorAll('lightning-button')].find(
                (b) => b.label === 'Back'
            );
            back.dispatchEvent(new CustomEvent('click'));
            await flush(1);
            expect(element.shadowRoot.querySelector('lightning-input')).not.toBeNull();
            expect(element.shadowRoot.querySelectorAll('tbody tr')).toHaveLength(0);
        });

        it('re-selecting the same file works because the input is reset', async () => {
            // Without `event.target.value = null` the browser fires no second
            // change event and the retry silently does nothing.
            const input = element.shadowRoot.querySelector('lightning-input');
            await upload(element, `${HEADER}\nA,1,a@x.com,,,`);
            expect(input.value).toBeNull();
        });

        it('starting over clears the file name, the result and the preview', async () => {
            applyChanges.mockResolvedValue({ created: 1, updated: 0 });
            await upload(element, `${HEADER}\nA,1,a@x.com,,,`, 'attendees.csv');
            [...element.shadowRoot.querySelectorAll('lightning-button')]
                .find((b) => String(b.label).startsWith('Apply'))
                .dispatchEvent(new CustomEvent('click'));
            await flush();

            [...element.shadowRoot.querySelectorAll('lightning-button')]
                .find((b) => b.label === 'Import Another File')
                .dispatchEvent(new CustomEvent('click'));
            await flush(1);

            expect(element.shadowRoot.querySelector('lightning-input')).not.toBeNull();
            expect(element.shadowRoot.textContent).not.toContain('Import complete');
            expect(element.shadowRoot.textContent).not.toContain('attendees.csv');
        });
    });
});
