import { createElement } from 'lwc';
import ContactSelector from 'c/contactSelector';
import { registerApexTestWireAdapter } from '@salesforce/sfdx-lwc-jest';
import { refreshApex } from '@salesforce/apex';
import getSelectableContacts from '@salesforce/apex/InviteeSelectorController.getSelectableContacts';
import getAllInvitees from '@salesforce/apex/InviteeSelectorController.getAllInvitees';
import addInvitees from '@salesforce/apex/InviteeSelectorController.addInvitees';
import submitMyInvitees from '@salesforce/apex/InviteeSelectorController.submitMyInvitees';
import exportApproved from '@salesforce/apex/EventExportController.exportApproved';
import { downloadCsv } from 'c/csvDownload';

jest.mock(
    '@salesforce/apex/InviteeSelectorController.addInvitees',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/InviteeSelectorController.submitMyInvitees',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock('@salesforce/apex/EventExportController.exportApproved', () => ({ default: jest.fn() }), {
    virtual: true
});
jest.mock('@salesforce/apex', () => ({ refreshApex: jest.fn() }), { virtual: true });
jest.mock('c/csvDownload', () => ({
    downloadCsv: jest.fn(),
    csvRow: jest.fn(),
    csvCell: jest.fn()
}));

const selectableAdapter = registerApexTestWireAdapter(getSelectableContacts);
const inviteesAdapter = registerApexTestWireAdapter(getAllInvitees);

const flush = async (times = 4) => {
    for (let i = 0; i < times; i++) {
        await new Promise((resolve) => setTimeout(resolve, 0));
    }
};

const EVENT_ID = 'a01000000000001';

const SELECTABLE = [
    {
        contactId: '003000000000001',
        name: 'Jane Doe',
        email: 'jane@acme.com',
        title: 'CTO',
        accountId: '001000000000001',
        accountName: 'Acme',
        accountOwnerName: 'Olivia Owner'
    },
    {
        contactId: '003000000000002',
        name: 'John Roe',
        email: 'john@acme.com',
        title: 'Buyer',
        accountId: '001000000000001',
        accountName: 'Acme',
        accountOwnerName: 'Olivia Owner'
    },
    {
        contactId: '003000000000003',
        name: 'Mia Lin',
        email: 'mia@globex.com',
        title: 'Head of Ops',
        accountId: '001000000000002',
        accountName: 'Globex',
        accountOwnerName: 'Omar Owner'
    }
];

const INVITEES = [
    {
        inviteeId: 'a02000000000001',
        contactName: 'Jane Doe',
        status: 'Draft',
        mine: true,
        addedByName: 'Alex AM'
    },
    {
        inviteeId: 'a02000000000002',
        contactName: 'John Roe',
        status: 'Approved',
        mine: true,
        addedByName: 'Alex AM'
    },
    {
        inviteeId: 'a02000000000003',
        contactName: 'Mia Lin',
        status: 'Exported',
        mine: false,
        addedByName: 'Sam AM'
    },
    {
        inviteeId: 'a02000000000004',
        contactName: 'Ken Ito',
        status: 'Draft',
        mine: false,
        addedByName: 'Sam AM'
    }
];

function mount() {
    const element = createElement('c-contact-selector', { is: ContactSelector });
    element.recordId = EVENT_ID;
    document.body.appendChild(element);
    return element;
}

const buttons = (element) => [...element.shadowRoot.querySelectorAll('lightning-button')];
const buttonStartingWith = (element, prefix) =>
    buttons(element).find((b) => String(b.label).startsWith(prefix));
const rowBoxes = (element) => [
    ...element.shadowRoot.querySelectorAll('input[type="checkbox"][data-id]')
];
const groupHeaders = (element) =>
    [...element.shadowRoot.querySelectorAll('tr.group-header')].map((r) => r.textContent.trim());

async function fire(node, eventName, detail) {
    const event = detail ? new CustomEvent(eventName, { detail }) : new CustomEvent(eventName);
    Object.defineProperty(event, 'target', { value: node, configurable: true });
    node.dispatchEvent(event);
    await flush(1);
}

async function search(element, term) {
    const input = element.shadowRoot.querySelector('lightning-input');
    input.value = term;
    await fire(input, 'change');
}

async function filterAccount(element, value) {
    const combobox = element.shadowRoot.querySelector('lightning-combobox');
    await fire(combobox, 'change', { value });
}

describe('c-contact-selector', () => {
    let element;
    let toasts;

    beforeEach(() => {
        addInvitees.mockResolvedValue(2);
        submitMyInvitees.mockResolvedValue({ submitted: 1, ownersNotified: 1 });
        exportApproved.mockResolvedValue({
            csv: 'Name,Email\r\nJane,j@x.com',
            fileName: 'approved.csv',
            rowCount: 2
        });
        refreshApex.mockResolvedValue(undefined);
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

    describe('wiring', () => {
        it('passes the record id to both wires', () => {
            expect(selectableAdapter.getLastConfig()).toEqual({ eventId: EVENT_ID });
            expect(inviteesAdapter.getLastConfig()).toEqual({ eventId: EVENT_ID });
        });

        it('shows an empty state when nothing is selectable', async () => {
            selectableAdapter.emit([]);
            await flush(1);
            expect(element.shadowRoot.querySelectorAll('tbody tr')).toHaveLength(0);
        });

        it('shows an empty state when there are no invitees', async () => {
            inviteesAdapter.emit([]);
            await flush(1);
            expect(element.shadowRoot.textContent).toContain('No invitees yet.');
        });
    });

    describe('account filter options', () => {
        it('lists each account once, sorted, behind an All option', async () => {
            selectableAdapter.emit(SELECTABLE);
            await flush(1);
            const combobox = element.shadowRoot.querySelector('lightning-combobox');
            expect(combobox.options).toEqual([
                { label: 'All', value: '' },
                { label: 'Acme', value: 'Acme' },
                { label: 'Globex', value: 'Globex' }
            ]);
        });
    });

    describe('grouping and filtering', () => {
        beforeEach(async () => {
            selectableAdapter.emit(SELECTABLE);
            await flush(1);
        });

        it('groups contacts by account', () => {
            expect(groupHeaders(element)).toHaveLength(2);
        });

        it('names the account owner and the selected tally in each header', () => {
            expect(groupHeaders(element)[0]).toBe('Acme (Owner: Olivia Owner) — 0/2 selected');
        });

        it('updates the tally as rows are selected', async () => {
            await fire(Object.assign(rowBoxes(element)[0], { checked: true }), 'change');
            expect(groupHeaders(element)[0]).toBe('Acme (Owner: Olivia Owner) — 1/2 selected');
        });

        it('filters to a single account', async () => {
            await filterAccount(element, 'Globex');
            expect(groupHeaders(element)).toEqual(['Globex (Owner: Omar Owner) — 0/1 selected']);
        });

        it('the All option restores every account', async () => {
            await filterAccount(element, 'Globex');
            await filterAccount(element, '');
            expect(groupHeaders(element)).toHaveLength(2);
        });

        it('searches by name', async () => {
            await search(element, 'mia');
            expect(rowBoxes(element)).toHaveLength(1);
            expect(element.shadowRoot.textContent).toContain('Mia Lin');
        });

        it('searches by email', async () => {
            await search(element, 'john@acme');
            expect(rowBoxes(element)).toHaveLength(1);
        });

        it('searches by title', async () => {
            await search(element, 'head of ops');
            expect(rowBoxes(element)).toHaveLength(1);
        });

        it('matches case-insensitively', async () => {
            await search(element, 'JANE');
            expect(rowBoxes(element)).toHaveLength(1);
        });

        it('combines the search term with the account filter', async () => {
            await filterAccount(element, 'Acme');
            await search(element, 'mia');
            expect(rowBoxes(element)).toHaveLength(0);
        });

        it('an empty term shows everything again', async () => {
            await search(element, 'mia');
            await search(element, '');
            expect(rowBoxes(element)).toHaveLength(3);
        });

        it('a term matching nothing yields no rows', async () => {
            await search(element, 'zzzz');
            expect(rowBoxes(element)).toHaveLength(0);
        });

        it('searches past a contact with null name, email and title', async () => {
            // A Contact can legitimately have no email or title; an unguarded
            // .toLowerCase() on those would throw and blank the whole table.
            selectableAdapter.emit([
                { ...SELECTABLE[0], name: null, email: null, title: null },
                SELECTABLE[2]
            ]);
            await flush(1);
            await search(element, 'mia');
            expect(rowBoxes(element)).toHaveLength(1);
        });
    });

    describe('adding contacts', () => {
        beforeEach(async () => {
            selectableAdapter.emit(SELECTABLE);
            inviteesAdapter.emit(INVITEES);
            await flush(1);
        });

        const clickAdd = async () => {
            buttonStartingWith(element, 'Add Selected').dispatchEvent(new CustomEvent('click'));
            await flush();
        };

        it('starts with nothing selected and the button disabled', () => {
            expect(buttonStartingWith(element, 'Add Selected').label).toBe('Add Selected (0)');
            expect(buttonStartingWith(element, 'Add Selected').disabled).toBe(true);
        });

        it('counts selections on the button label', async () => {
            await fire(Object.assign(rowBoxes(element)[0], { checked: true }), 'change');
            await fire(Object.assign(rowBoxes(element)[2], { checked: true }), 'change');
            expect(buttonStartingWith(element, 'Add Selected').label).toBe('Add Selected (2)');
        });

        it('deselecting removes the contact again', async () => {
            const box = rowBoxes(element)[0];
            await fire(Object.assign(box, { checked: true }), 'change');
            await fire(Object.assign(box, { checked: false }), 'change');
            expect(buttonStartingWith(element, 'Add Selected').label).toBe('Add Selected (0)');
        });

        it('sends the selected contact ids for this event', async () => {
            await fire(Object.assign(rowBoxes(element)[0], { checked: true }), 'change');
            await clickAdd();
            expect(addInvitees).toHaveBeenCalledWith({
                eventId: EVENT_ID,
                contactIds: ['003000000000001']
            });
        });

        it('reports how many were added', async () => {
            await fire(Object.assign(rowBoxes(element)[0], { checked: true }), 'change');
            await clickAdd();
            expect(toasts.at(-1)).toMatchObject({ variant: 'success' });
            expect(toasts.at(-1).message).toBe('2 contact(s) added as Draft.');
        });

        it('clears the selection after a successful add', async () => {
            await fire(Object.assign(rowBoxes(element)[0], { checked: true }), 'change');
            await clickAdd();
            expect(buttonStartingWith(element, 'Add Selected').label).toBe('Add Selected (0)');
        });

        it('refreshes both wires after a successful add', async () => {
            await fire(Object.assign(rowBoxes(element)[0], { checked: true }), 'change');
            await clickAdd();
            expect(refreshApex).toHaveBeenCalledTimes(2);
        });

        it('surfaces an Apex failure and keeps the selection', async () => {
            addInvitees.mockRejectedValue({ body: { message: 'not your account' } });
            await fire(Object.assign(rowBoxes(element)[0], { checked: true }), 'change');
            await clickAdd();
            expect(toasts.at(-1)).toMatchObject({ variant: 'error', message: 'not your account' });
            expect(buttonStartingWith(element, 'Add Selected').label).toBe('Add Selected (1)');
        });
    });

    describe('submitting for approval', () => {
        beforeEach(async () => {
            selectableAdapter.emit(SELECTABLE);
            inviteesAdapter.emit(INVITEES);
            await flush(1);
        });

        const clickSubmit = async () => {
            buttonStartingWith(element, 'Submit My Contacts').dispatchEvent(
                new CustomEvent('click')
            );
            await flush();
        };

        it('counts only my own draft invitees', () => {
            // Jane is mine and Draft; John is mine but Approved; Ken is Draft but
            // someone else's — only Jane counts.
            expect(buttonStartingWith(element, 'Submit My Contacts').label).toBe(
                'Submit My Contacts for Approval (1)'
            );
        });

        it('is disabled when I have no drafts', async () => {
            inviteesAdapter.emit(INVITEES.filter((i) => !(i.mine && i.status === 'Draft')));
            await flush(1);
            expect(buttonStartingWith(element, 'Submit My Contacts').disabled).toBe(true);
        });

        it('submits for this event', async () => {
            await clickSubmit();
            expect(submitMyInvitees).toHaveBeenCalledWith({ eventId: EVENT_ID });
        });

        it('reports the submitted count and notified owners', async () => {
            submitMyInvitees.mockResolvedValue({ submitted: 3, ownersNotified: 2 });
            await clickSubmit();
            expect(toasts.at(-1).message).toBe(
                '3 contact(s) sent for approval — 2 Account Owner(s) notified.'
            );
        });

        it('refreshes the invitee list afterwards', async () => {
            await clickSubmit();
            expect(refreshApex).toHaveBeenCalledTimes(1);
        });

        it('surfaces an Apex failure', async () => {
            submitMyInvitees.mockRejectedValue(new Error('nothing to submit'));
            await clickSubmit();
            expect(toasts.at(-1)).toMatchObject({
                variant: 'error',
                message: 'nothing to submit'
            });
        });
    });

    describe('invitee list', () => {
        beforeEach(async () => {
            inviteesAdapter.emit(INVITEES);
            await flush(1);
        });

        it('renders one row per invitee', () => {
            expect(element.shadowRoot.querySelectorAll('.slds-badge')).toHaveLength(4);
        });

        it('marks my own rows with (me)', () => {
            expect(element.shadowRoot.textContent).toContain('Alex AM (me)');
        });

        it('leaves other people’s rows unmarked', () => {
            expect(element.shadowRoot.textContent).toContain('Sam AM');
            expect(element.shadowRoot.textContent).not.toContain('Sam AM (me)');
        });
    });

    describe('exporting', () => {
        const clickExport = async () => {
            buttonStartingWith(element, 'Export Approved List').dispatchEvent(
                new CustomEvent('click')
            );
            await flush();
        };

        it('hides the export until something is approved', async () => {
            inviteesAdapter.emit([INVITEES[0]]); // Draft only
            await flush(1);
            expect(buttonStartingWith(element, 'Export Approved List')).toBeUndefined();
        });

        it('shows the export once a row is Approved or Exported', async () => {
            inviteesAdapter.emit(INVITEES);
            await flush(1);
            expect(buttonStartingWith(element, 'Export Approved List')).toBeDefined();
        });

        it('exports the whole approved list for this event, unfiltered by date', async () => {
            // The Approved Exports tab is where a decision-date range applies.
            inviteesAdapter.emit(INVITEES);
            await flush(1);
            await clickExport();
            expect(exportApproved).toHaveBeenCalledWith({
                eventId: EVENT_ID,
                fromDate: null,
                toDate: null
            });
        });

        it('hands the csv to the downloader and reports the count', async () => {
            inviteesAdapter.emit(INVITEES);
            await flush(1);
            await clickExport();
            expect(downloadCsv).toHaveBeenCalledWith('Name,Email\r\nJane,j@x.com', 'approved.csv');
            expect(toasts.at(-1).message).toBe('2 approved contact(s) exported.');
        });

        it('refreshes the invitee list so statuses flip to Exported', async () => {
            inviteesAdapter.emit(INVITEES);
            await flush(1);
            await clickExport();
            expect(refreshApex).toHaveBeenCalledTimes(1);
        });

        it('surfaces an export failure without downloading', async () => {
            inviteesAdapter.emit(INVITEES);
            await flush(1);
            exportApproved.mockRejectedValue({});
            await clickExport();
            expect(toasts.at(-1)).toMatchObject({
                variant: 'error',
                message: 'Unexpected error'
            });
            expect(downloadCsv).not.toHaveBeenCalled();
        });
    });
});
