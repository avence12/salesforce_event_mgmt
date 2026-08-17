import { createElement } from 'lwc';
import ImportWizard from 'c/importWizard';
import previewMatches from '@salesforce/apex/AttendeeImportController.previewMatches';
import applyChanges from '@salesforce/apex/AttendeeImportController.applyChanges';
import { downloadCsv } from 'c/csvDownload';

jest.mock(
    '@salesforce/apex/AttendeeImportController.previewMatches',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/AttendeeImportController.applyChanges',
    () => ({ default: jest.fn() }),
    {
        virtual: true
    }
);

// downloadCsv touches the DOM and the object-URL registry; csvRow stays real so
// the skipped-row file is asserted with the production quoting rules.
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
async function upload(element, content, fileName = 'attendees.csv') {
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

const HEADER = 'First Name,Last Name,Email,Title,Company,Mobile';

/** Minimal previewMatches response echoing each row back as a new attendee. */
const echoPreview = (rows) =>
    rows.map((row) => ({
        row,
        classification: 'NEW_ATTENDEE',
        reason: 'Will be created as an event attendee',
        attendeeId: null
    }));

describe('c-import-wizard', () => {
    let element;

    beforeEach(() => {
        previewMatches.mockImplementation(({ rows }) => Promise.resolve(echoPreview(rows)));
        applyChanges.mockResolvedValue({ attendeesCreated: 0, attendeesUpdated: 0 });
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
            await upload(element, `First Name,Last Name\n"a;b;c;d",Doe`);
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
            await upload(element, `First Name,Last Name\rJane,Doe\rJohn,Roe`);
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

        // R5 dropped attendance, so a file written for R4 still imports — its Event
        // column is simply an unrecognised header now, not a reason to reject the file.
        it('ignores a left-over Event column from an R4-era file', async () => {
            await upload(element, `First Name,Last Name,Event\nJane,Doe,FinTech Summit 2026`);
            expect(sentRows()[0]).toMatchObject({ firstName: 'Jane', lastName: 'Doe' });
            expect(sentRows()[0]).not.toHaveProperty('event');
        });

        it('trims surrounding whitespace from values', async () => {
            await upload(element, `First Name,Email\n  Jane  , j@x.com `);
            expect(sentRows()[0]).toMatchObject({ firstName: 'Jane', email: 'j@x.com' });
        });
    });

    describe('row de-duplication', () => {
        // The key mirrors the server's Unique_Key__c: name, company and email are
        // the person's identity, so the two cannot disagree about how many people
        // the file contains.
        it('collapses rows identical in name, company and email, last occurrence winning', async () => {
            await upload(
                element,
                `${HEADER}\nJane,Doe,j@x.com,CTO,Acme,\nJane,Doe,j@x.com,CFO,Acme,`
            );
            expect(sentRows()).toHaveLength(1);
            expect(sentRows()[0].title).toBe('CFO');
        });

        it('normalises case and doubled spaces the same way the server does', async () => {
            await upload(
                element,
                `${HEADER}\nJane,Doe,j@x.com,,Acme Corp,\nJANE, doe ,J@X.COM,,acme  corp,`
            );
            expect(sentRows()).toHaveLength(1);
        });

        it('keeps two different people who share an email', async () => {
            await upload(
                element,
                `${HEADER}\nJane,Doe,shared@x.com,,Acme,\nJohn,Roe,shared@x.com,,Acme,`
            );
            expect(sentRows()).toHaveLength(2);
        });

        it('keeps the same person listed under two companies', async () => {
            await upload(element, `${HEADER}\nJane,Doe,j@x.com,,Acme,\nJane,Doe,j@x.com,,Globex,`);
            expect(sentRows()).toHaveLength(2);
        });

        it('keeps rows with no last name so the server can report them as skipped', async () => {
            await upload(element, `${HEADER}\nA,,a@x.com,,,\nB,,b@x.com,,,`);
            expect(sentRows()).toHaveLength(2);
        });

        it('orders keyed rows ahead of the unkeyed ones', async () => {
            await upload(element, `${HEADER}\nNoLast,,a@x.com,,,\nHas,Last,b@x.com,,,`);
            expect(sentRows().map((r) => r.firstName)).toEqual(['Has', 'NoLast']);
        });

        it('skips a fully empty data line', async () => {
            await upload(element, `${HEADER}\n,,,,,\nJane,Doe,j@x.com,,,`);
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

        it('rejects a file over the 8000-row PoC cap and says the count', async () => {
            const rows = Array.from(
                { length: 8001 },
                (_unused, i) => `A${i},B${i},u${i}@x.com,,,`
            ).join('\n');
            await upload(element, `${HEADER}\n${rows}`);
            expect(errorText()).toMatch(/8001 rows/);
            expect(previewMatches).not.toHaveBeenCalled();
        });

        it('accepts a file exactly at the cap', async () => {
            // 8000 rows means 8000 rendered <tr> elements in jsdom, which is
            // genuinely slow rather than hung — hence the longer timeout.
            const rows = Array.from(
                { length: 8000 },
                (_unused, i) => `A${i},B${i},u${i}@x.com,,,`
            ).join('\n');
            await upload(element, `${HEADER}\n${rows}`);
            expect(previewMatches).toHaveBeenCalled();
            expect(errorText()).toBeNull();
        }, 20000);

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

    describe('R10 chunked batches', () => {
        // Mirrors importWizard.js's BATCH_SIZE. Not the same constant — the module
        // doesn't export it — so a change to one has to be made to the other by hand,
        // same as AttendeeImportController.BATCH_SIZE on the Apex side (design.md → ★R10).
        const BATCH_SIZE = 100;

        const bigFile = (n) =>
            `${HEADER}\n` +
            Array.from({ length: n }, (_unused, i) => `First${i},Last${i},u${i}@x.com,,Acme,`).join(
                '\n'
            );

        const clickApply = () => {
            const apply = [...element.shadowRoot.querySelectorAll('lightning-button')].find((b) =>
                String(b.label).startsWith('Import')
            );
            apply.dispatchEvent(new CustomEvent('click'));
        };

        it('splits a file larger than one batch into multiple sequential preview calls', async () => {
            await upload(element, bigFile(BATCH_SIZE + 50));
            expect(previewMatches).toHaveBeenCalledTimes(2);
            expect(previewMatches.mock.calls[0][0].rows).toHaveLength(BATCH_SIZE);
            expect(previewMatches.mock.calls[1][0].rows).toHaveLength(50);
        });

        it('sends a small file — under one batch — as a single preview call', async () => {
            await upload(element, `${HEADER}\nJane,Doe,j@x.com,,Acme,`);
            expect(previewMatches).toHaveBeenCalledTimes(1);
        });

        it('accumulates preview results across batches, keeping file order', async () => {
            await upload(element, bigFile(BATCH_SIZE + 50));
            const rows = element.shadowRoot.querySelectorAll('tbody tr');
            expect(rows).toHaveLength(BATCH_SIZE + 50);
            expect(rows[0].querySelector('td:nth-child(2)').textContent.trim()).toBe(
                'First0 Last0'
            );
            expect(rows[rows.length - 1].querySelector('td:nth-child(2)').textContent.trim()).toBe(
                `First${BATCH_SIZE + 49} Last${BATCH_SIZE + 49}`
            );
        });

        it('shows which batch is running while a multi-batch preview is in flight', async () => {
            let resolveFirstBatch;
            const pendingFirstBatch = new Promise((resolve) => {
                resolveFirstBatch = resolve;
            });
            previewMatches
                .mockImplementationOnce(() => pendingFirstBatch)
                .mockImplementation(({ rows }) => Promise.resolve(echoPreview(rows)));

            const file = new File(
                [new TextEncoder().encode(bigFile(BATCH_SIZE + 50))],
                'attendees.csv',
                { type: 'text/csv' }
            );
            const input = element.shadowRoot.querySelector('lightning-input');
            Object.defineProperty(input, 'files', { value: [file], configurable: true });
            const changeEvent = new CustomEvent('change');
            Object.defineProperty(changeEvent, 'target', { value: input, configurable: true });
            input.dispatchEvent(changeEvent);
            await flush(5);

            expect(element.shadowRoot.textContent).toContain('Checking batch 1 of 2');

            resolveFirstBatch([]);
            await flush();
            expect(previewMatches).toHaveBeenCalledTimes(2);
        });

        it('applies selected rows in batches and accumulates created/updated counts', async () => {
            await upload(element, bigFile(BATCH_SIZE + 50));
            applyChanges
                .mockResolvedValueOnce({
                    attendeesCreated: 150,
                    attendeesUpdated: 20,
                    attendeesFailed: 0,
                    failures: []
                })
                .mockResolvedValueOnce({
                    attendeesCreated: 40,
                    attendeesUpdated: 10,
                    attendeesFailed: 0,
                    failures: []
                });

            clickApply();
            await flush();

            expect(applyChanges).toHaveBeenCalledTimes(2);
            expect(applyChanges.mock.calls[0][0].rows).toHaveLength(BATCH_SIZE);
            expect(applyChanges.mock.calls[1][0].rows).toHaveLength(50);
            expect(applyChanges.mock.calls[0][0].sourceFile).toBe('attendees.csv');
            expect(applyChanges.mock.calls[1][0].sourceFile).toBe('attendees.csv');
            expect(element.shadowRoot.textContent).toContain('190'); // 150 + 40 created
            expect(element.shadowRoot.textContent).toContain('30'); // 20 + 10 refreshed
        });

        it('aggregates failures from several apply batches and offers them for download', async () => {
            await upload(element, bigFile(BATCH_SIZE + 50));
            applyChanges
                .mockResolvedValueOnce({
                    attendeesCreated: 199,
                    attendeesUpdated: 0,
                    attendeesFailed: 1,
                    failures: [
                        {
                            row: {
                                firstName: 'First5',
                                lastName: 'Last5',
                                email: 'u5@x.com',
                                company: 'Acme'
                            },
                            message: 'REQUIRED_FIELD_MISSING'
                        }
                    ]
                })
                .mockResolvedValueOnce({
                    attendeesCreated: 48,
                    attendeesUpdated: 0,
                    attendeesFailed: 2,
                    failures: [
                        {
                            row: {
                                firstName: `First${BATCH_SIZE + 10}`,
                                lastName: `Last${BATCH_SIZE + 10}`,
                                email: `u${BATCH_SIZE + 10}@x.com`,
                                company: 'Acme'
                            },
                            message: 'DUPLICATE_VALUE'
                        },
                        {
                            row: {
                                firstName: `First${BATCH_SIZE + 20}`,
                                lastName: `Last${BATCH_SIZE + 20}`,
                                email: `u${BATCH_SIZE + 20}@x.com`,
                                company: 'Acme'
                            },
                            message: 'FIELD_CUSTOM_VALIDATION_EXCEPTION'
                        }
                    ]
                });

            clickApply();
            await flush();

            expect(element.shadowRoot.textContent).toContain('could not be imported');
            expect(element.shadowRoot.textContent).toContain('were not rolled back');

            const downloadBtn = [...element.shadowRoot.querySelectorAll('lightning-button')].find(
                (b) => b.label === 'Download Failed Rows'
            );
            expect(downloadBtn).not.toBeUndefined();
            downloadBtn.dispatchEvent(new CustomEvent('click'));

            const [csv, fileName] = downloadCsv.mock.calls[0];
            expect(fileName).toBe('failed_rows_manual_review.csv');
            expect(csv.split('\r\n')).toEqual([
                'Name,Email,Company,Why it failed',
                'First5 Last5,u5@x.com,Acme,REQUIRED_FIELD_MISSING',
                `First${BATCH_SIZE + 10} Last${BATCH_SIZE + 10},u${BATCH_SIZE + 10}@x.com,Acme,DUPLICATE_VALUE`,
                `First${BATCH_SIZE + 20} Last${BATCH_SIZE + 20},u${BATCH_SIZE + 20}@x.com,Acme,FIELD_CUSTOM_VALIDATION_EXCEPTION`
            ]);
        });

        it('neutralises a formula smuggled into a failed row before download', async () => {
            await upload(element, `${HEADER}\nJane,Doe,j@x.com,,Acme,`);
            applyChanges.mockResolvedValue({
                attendeesCreated: 0,
                attendeesUpdated: 0,
                attendeesFailed: 1,
                failures: [
                    {
                        row: {
                            firstName: '=HYPERLINK("http://evil")',
                            lastName: 'Doe',
                            email: 'j@x.com',
                            company: 'Acme'
                        },
                        message: 'DUPLICATE_VALUE'
                    }
                ]
            });

            clickApply();
            await flush();

            [...element.shadowRoot.querySelectorAll('lightning-button')]
                .find((b) => b.label === 'Download Failed Rows')
                .dispatchEvent(new CustomEvent('click'));
            const [csv] = downloadCsv.mock.calls[0];
            expect(csv).toContain('"\'=HYPERLINK(""http://evil"") Doe"');
            expect(csv).not.toMatch(/,=HYPERLINK/);
        });

        it('does not offer a failed-rows download when nothing failed', async () => {
            applyChanges.mockResolvedValue({
                attendeesCreated: 1,
                attendeesUpdated: 0,
                attendeesFailed: 0,
                failures: []
            });
            await upload(element, `${HEADER}\nJane,Doe,j@x.com,,Acme,`);
            clickApply();
            await flush();
            const labels = [...element.shadowRoot.querySelectorAll('lightning-button')].map(
                (b) => b.label
            );
            expect(labels).not.toContain('Download Failed Rows');
        });
    });

    describe('preview step', () => {
        const classify = (classifications) => {
            previewMatches.mockImplementation(({ rows }) =>
                Promise.resolve(
                    rows.map((row, i) => ({
                        row,
                        classification: classifications[i],
                        reason: '',
                        attendeeId: null
                    }))
                )
            );
        };

        const threeRows = `${HEADER}\nA,One,a@x.com,,Acme,\nB,Two,b@x.com,,Acme,\nC,Three,c@x.com,,Acme,`;

        const statValues = () =>
            [...element.shadowRoot.querySelectorAll('.stat b')].map((n) => n.textContent);

        // Tiles, in order: new attendees, already known, skipped.
        it('counts each classification into its own tile', async () => {
            classify(['NEW_ATTENDEE', 'EXISTING_ATTENDEE', 'SKIPPED']);
            await upload(element, threeRows);
            expect(statValues()).toEqual(['1', '1', '1']);
        });

        it('counts an unknown classification as skipped rather than dropping it', async () => {
            classify(['SOMETHING_NEW']);
            await upload(element, `${HEADER}\nA,One,a@x.com,,Acme,`);
            expect(statValues()[2]).toBe('1');
        });

        it('renders one table row per preview row', async () => {
            classify(['NEW_ATTENDEE', 'EXISTING_ATTENDEE', 'SKIPPED']);
            await upload(element, threeRows);
            expect(element.shadowRoot.querySelectorAll('tbody tr')).toHaveLength(3);
        });

        describe('preview ordering', () => {
            const typeColumn = () =>
                [...element.shadowRoot.querySelectorAll('tbody tr')].map((r) =>
                    r.querySelector('td:last-child').textContent.trim()
                );

            it('puts the rows needing a decision above the rest', async () => {
                // Server order deliberately buries the one that matters.
                classify(['EXISTING_ATTENDEE', 'NEW_ATTENDEE', 'SKIPPED']);
                await upload(element, threeRows);
                expect(typeColumn()).toEqual(['Skipped', 'New', 'Already known']);
            });

            it('keeps file order within one classification', async () => {
                classify(['NEW_ATTENDEE', 'SKIPPED', 'NEW_ATTENDEE']);
                await upload(element, threeRows);
                const names = [...element.shadowRoot.querySelectorAll('tbody tr')].map((r) =>
                    r.querySelector('td:nth-child(2)').textContent.trim()
                );
                expect(names).toEqual(['B Two', 'A One', 'C Three']);
            });

            it('still imports the row the user unticks after the reorder', async () => {
                // Sorting must not desynchronise a row from its checkbox.
                classify(['SKIPPED', 'NEW_ATTENDEE', 'EXISTING_ATTENDEE']);
                await upload(element, threeRows);
                const boxes = [...element.shadowRoot.querySelectorAll('tbody input')];
                const box = boxes[2]; // order: Skipped, New, Already known
                box.checked = false;
                box.dispatchEvent(new CustomEvent('change'));
                await flush(1);
                const label = [...element.shadowRoot.querySelectorAll('lightning-button')]
                    .map((b) => String(b.label))
                    .find((l) => l.startsWith('Import'));
                expect(label).toBe('Import 1 Attendee');
            });
        });

        it.each([
            ['NEW_ATTENDEE', true],
            ['EXISTING_ATTENDEE', true],
            ['SKIPPED', false]
        ])('pre-selects %s rows: %s', async (classification, selected) => {
            classify([classification]);
            await upload(element, `${HEADER}\nA,One,a@x.com,,Acme,`);
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
            classify(['NEW_ATTENDEE']);
            await upload(element, `${HEADER}\nJane,Doe,j@x.com,,Acme,`);
            expect(text(element, 'tbody tr td:nth-child(2)')).toBe('Jane Doe');
        });

        it('warns visually on rows that need a human', async () => {
            classify(['SKIPPED', 'NEW_ATTENDEE']);
            await upload(element, `${HEADER}\nA,One,a@x.com,,Acme,\nB,Two,b@x.com,,Acme,`);
            const badges = element.shadowRoot.querySelectorAll('tbody tr td:nth-child(6) span');
            expect(badges[0].className).toContain('warning');
            expect(badges[1].className).not.toContain('warning');
        });

        it('shows the server’s reason for each row', async () => {
            previewMatches.mockResolvedValue([
                {
                    row: { firstName: 'A', lastName: 'One', email: 'a@x.com', company: 'Acme' },
                    classification: 'EXISTING_ATTENDEE',
                    reason: 'Already an attendee — title, mobile and source file will be refreshed',
                    attendeeId: 'a03000000000001'
                }
            ]);
            await upload(element, `${HEADER}\nA,One,a@x.com,,Acme,`);
            expect(text(element, 'tbody tr td:nth-child(5)')).toBe(
                'Already an attendee — title, mobile and source file will be refreshed'
            );
        });

        it('labels the import button with the selected count, pluralised', async () => {
            classify(['NEW_ATTENDEE', 'EXISTING_ATTENDEE', 'SKIPPED']);
            await upload(element, threeRows);
            const labels = [...element.shadowRoot.querySelectorAll('lightning-button')].map(
                (b) => b.label
            );
            expect(labels).toContain('Import 2 Attendees');
        });

        it('singularises the import label for one attendee', async () => {
            classify(['NEW_ATTENDEE', 'SKIPPED']);
            await upload(element, `${HEADER}\nA,One,a@x.com,,Acme,\nB,Two,b@x.com,,Acme,`);
            const labels = [...element.shadowRoot.querySelectorAll('lightning-button')].map(
                (b) => b.label
            );
            expect(labels).toContain('Import 1 Attendee');
        });

        it('disables import when nothing is selectable', async () => {
            classify(['SKIPPED']);
            await upload(element, `${HEADER}\nA,One,a@x.com,,Acme,`);
            const apply = [...element.shadowRoot.querySelectorAll('lightning-button')].find((b) =>
                String(b.label).startsWith('Import')
            );
            expect(apply.disabled).toBe(true);
        });

        it('offers the skipped download only when something was skipped', async () => {
            classify(['NEW_ATTENDEE']);
            await upload(element, `${HEADER}\nA,One,a@x.com,,Acme,`);
            const labels = [...element.shadowRoot.querySelectorAll('lightning-button')].map(
                (b) => b.label
            );
            expect(labels).not.toContain('Download Skipped Rows');
        });

        it('offers the skipped download when a row was skipped', async () => {
            classify(['SKIPPED']);
            await upload(element, `${HEADER}\nA,One,a@x.com,,Acme,`);
            const labels = [...element.shadowRoot.querySelectorAll('lightning-button')].map(
                (b) => b.label
            );
            expect(labels).toContain('Download Skipped Rows');
        });

        it('deselecting a row lowers the import count', async () => {
            classify(['NEW_ATTENDEE', 'EXISTING_ATTENDEE']);
            await upload(element, `${HEADER}\nA,One,a@x.com,,Acme,\nB,Two,b@x.com,,Acme,`);
            const box = element.shadowRoot.querySelector('tbody input[type="checkbox"]');
            box.checked = false;
            box.dispatchEvent(new CustomEvent('change'));
            await flush(1);
            const labels = [...element.shadowRoot.querySelectorAll('lightning-button')].map(
                (b) => b.label
            );
            expect(labels).toContain('Import 1 Attendee');
        });
    });

    describe('apply step', () => {
        it('sends only the selected rows to Apex', async () => {
            previewMatches.mockImplementation(({ rows }) =>
                Promise.resolve(
                    rows.map((row, i) => ({
                        row,
                        classification: i === 0 ? 'NEW_ATTENDEE' : 'SKIPPED',
                        reason: '',
                        attendeeId: null
                    }))
                )
            );
            await upload(element, `${HEADER}\nA,One,a@x.com,,Acme,\nB,Two,b@x.com,,Acme,`);
            const apply = [...element.shadowRoot.querySelectorAll('lightning-button')].find((b) =>
                String(b.label).startsWith('Import')
            );
            apply.dispatchEvent(new CustomEvent('click'));
            await flush();
            expect(applyChanges).toHaveBeenCalledTimes(1);
            expect(applyChanges.mock.calls[0][0].rows).toHaveLength(1);
            expect(applyChanges.mock.calls[0][0].rows[0].email).toBe('a@x.com');
            // The file name travels with the rows so an attendee can be traced back.
            expect(applyChanges.mock.calls[0][0].sourceFile).toBe('attendees.csv');
        });

        it('shows the created and refreshed counts on success', async () => {
            applyChanges.mockResolvedValue({ attendeesCreated: 3, attendeesUpdated: 2 });
            await upload(element, `${HEADER}\nA,One,a@x.com,,Acme,`);
            const apply = [...element.shadowRoot.querySelectorAll('lightning-button')].find((b) =>
                String(b.label).startsWith('Import')
            );
            apply.dispatchEvent(new CustomEvent('click'));
            await flush();
            expect(element.shadowRoot.textContent).toContain('Import complete');
            expect(element.shadowRoot.textContent).toContain('3');
            expect(element.shadowRoot.textContent).toContain('2');
        });

        it('says plainly that nothing outside the attendee object was touched', async () => {
            applyChanges.mockResolvedValue({ attendeesCreated: 1, attendeesUpdated: 0 });
            await upload(element, `${HEADER}\nA,One,a@x.com,,Acme,`);
            [...element.shadowRoot.querySelectorAll('lightning-button')]
                .find((b) => String(b.label).startsWith('Import'))
                .dispatchEvent(new CustomEvent('click'));
            await flush();
            expect(element.shadowRoot.textContent).toContain(
                'No contact, lead or account was created, changed or deleted.'
            );
        });

        it('surfaces an apply failure without advancing the step', async () => {
            applyChanges.mockRejectedValue({ body: { message: 'row locked' } });
            await upload(element, `${HEADER}\nA,One,a@x.com,,Acme,`);
            const apply = [...element.shadowRoot.querySelectorAll('lightning-button')].find((b) =>
                String(b.label).startsWith('Import')
            );
            apply.dispatchEvent(new CustomEvent('click'));
            await flush();
            expect(text(element, '[role="alert"]')).toBe('row locked');
            expect(element.shadowRoot.textContent).not.toContain('Import complete');
        });
    });

    describe('skipped-row download', () => {
        const clickSkippedDownload = () =>
            [...element.shadowRoot.querySelectorAll('lightning-button')]
                .find((b) => b.label === 'Download Skipped Rows')
                .dispatchEvent(new CustomEvent('click'));

        const skippedOnly = (
            reason = 'No last name — an attendee with no name is unrecognisable later'
        ) => {
            previewMatches.mockImplementation(({ rows }) =>
                Promise.resolve(
                    rows.map((row) => ({
                        row,
                        classification: 'SKIPPED',
                        reason,
                        attendeeId: null
                    }))
                )
            );
        };

        it('writes a header row and one line per skipped row', async () => {
            skippedOnly('No last name');
            await upload(element, `${HEADER}\nJane,,j@x.com,,Acme,`);
            clickSkippedDownload();
            const [csv, fileName] = downloadCsv.mock.calls[0];
            expect(csv.split('\r\n')).toEqual([
                'Name,Email,Company,Why it was skipped',
                'Jane,j@x.com,Acme,No last name'
            ]);
            expect(fileName).toBe('skipped_rows_manual_review.csv');
        });

        // Keyed by content, not by index: mapRows moves the rows it could not key
        // (no last name) to the end, so position in the request is not file order.
        const skipTheNameless = () =>
            previewMatches.mockImplementation(({ rows }) =>
                Promise.resolve(
                    rows.map((row) => ({
                        row,
                        classification: row.lastName ? 'NEW_ATTENDEE' : 'SKIPPED',
                        reason: row.lastName ? '' : 'No last name',
                        attendeeId: null
                    }))
                )
            );

        it('excludes rows that were not skipped', async () => {
            skipTheNameless();
            await upload(element, `${HEADER}\nJane,,j@x.com,,Acme,\nJohn,Roe,r@x.com,,Acme,`);
            clickSkippedDownload();
            const [csv] = downloadCsv.mock.calls[0];
            expect(csv.split('\r\n')).toHaveLength(2);
            expect(csv).not.toContain('r@x.com');
        });

        it('neutralises a formula smuggled in through the uploaded name', async () => {
            // Every value here came out of an untrusted .csv, so the file it
            // writes back out must not be executable when Excel opens it.
            skippedOnly('No last name');
            await upload(element, `${HEADER}\n"=HYPERLINK(""http://evil"")",,j@x.com,,Acme,`);
            clickSkippedDownload();
            const [csv] = downloadCsv.mock.calls[0];
            expect(csv).toContain('"\'=HYPERLINK(""http://evil"")"');
            expect(csv).not.toMatch(/,=HYPERLINK/);
        });

        describe('after the import has been applied', () => {
            // The results step used to only *mention* the leftover list and point
            // back at a step with no way to return to it: miss the download once
            // and the list was gone for good.
            const reachResultsStep = async () => {
                skipTheNameless();
                applyChanges.mockResolvedValue({ attendeesCreated: 1, attendeesUpdated: 0 });
                await upload(element, `${HEADER}\nJane,,j@x.com,,Acme,\nJohn,Roe,r@x.com,,Acme,`);
                const apply = [...element.shadowRoot.querySelectorAll('lightning-button')].find(
                    (b) => String(b.label).startsWith('Import')
                );
                expect(apply.disabled).toBe(false); // otherwise the click below is a no-op
                apply.dispatchEvent(new CustomEvent('click'));
                await flush();
                expect(element.shadowRoot.textContent).toContain('Import complete');
            };

            it('still offers the download once the import is done', async () => {
                await reachResultsStep();
                clickSkippedDownload();
                const [csv] = downloadCsv.mock.calls[0];
                expect(csv).toContain('Jane,j@x.com,Acme,No last name');
            });

            it('says how many rows were left behind, and that leaving discards them', async () => {
                await reachResultsStep();
                const results = element.shadowRoot.textContent;
                expect(results).toContain('could not be imported');
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
            await upload(element, `${HEADER}\nA,One,a@x.com,,Acme,`);
            const items = element.shadowRoot.querySelectorAll('.slds-progress__list li');
            expect(items[0].className).toContain('slds-is-completed');
            expect(items[1].className).toContain('slds-is-active');
        });

        it('going back returns to the upload step and clears the preview', async () => {
            await upload(element, `${HEADER}\nA,One,a@x.com,,Acme,`);
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
            await upload(element, `${HEADER}\nA,One,a@x.com,,Acme,`);
            expect(input.value).toBeNull();
        });

        it('starting over clears the file name, the result and the preview', async () => {
            applyChanges.mockResolvedValue({ attendeesCreated: 1, attendeesUpdated: 0 });
            await upload(element, `${HEADER}\nA,One,a@x.com,,Acme,`, 'summit-list.csv');
            [...element.shadowRoot.querySelectorAll('lightning-button')]
                .find((b) => String(b.label).startsWith('Import'))
                .dispatchEvent(new CustomEvent('click'));
            await flush();

            [...element.shadowRoot.querySelectorAll('lightning-button')]
                .find((b) => b.label === 'Import Another File')
                .dispatchEvent(new CustomEvent('click'));
            await flush(1);

            expect(element.shadowRoot.querySelector('lightning-input')).not.toBeNull();
            expect(element.shadowRoot.textContent).not.toContain('Import complete');
            expect(element.shadowRoot.textContent).not.toContain('summit-list.csv');
        });
    });
});
