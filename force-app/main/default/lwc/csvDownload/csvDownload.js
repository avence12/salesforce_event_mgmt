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
    setTimeout(() => {
        document.body.removeChild(anchor);
        URL.revokeObjectURL(url);
    }, 0);
}
