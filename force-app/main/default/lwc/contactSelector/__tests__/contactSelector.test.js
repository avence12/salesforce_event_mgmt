import { createElement } from 'lwc';
import ContactSelector from 'c/contactSelector';
import { registerApexTestWireAdapter } from '@salesforce/sfdx-lwc-jest';
import { refreshApex } from '@salesforce/apex';
import getSelectableContacts from '@salesforce/apex/InviteeSelectorController.getSelectableContacts';
import getSelectableLeads from '@salesforce/apex/InviteeSelectorController.getSelectableLeads';
import getAllInvitees from '@salesforce/apex/InviteeSelectorController.getAllInvitees';
import addInvitees from '@salesforce/apex/InviteeSelectorController.addInvitees';
import addLeadInvitees from '@salesforce/apex/InviteeSelectorController.addLeadInvitees';
import submitMyInvitees from '@salesforce/apex/InviteeSelectorController.submitMyInvitees';

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
jest.mock(
    '@salesforce/apex/InviteeSelectorController.addLeadInvitees',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock('@salesforce/apex', () => ({ refreshApex: jest.fn() }), { virtual: true });

const selectableAdapter = registerApexTestWireAdapter(getSelectableContacts);
const leadsAdapter = registerApexTestWireAdapter(getSelectableLeads);
const inviteesAdapter = registerApexTestWireAdapter(getAllInvitees);

const CONTACT_CAP = 2000;

/**
 * getSelectableContacts returns a wrapper, not a bare list, so a truncated
 * result can say so instead of reading as "that is everyone".
 */
const emitSelectable = (contacts, truncated = false) =>
    selectableAdapter.emit({ contacts, truncated, cap: CONTACT_CAP });

// The lead wire reuses the same wrapper shape; leadId is populated instead of
// contactId, and accountName carries the Lead's Company text.
const emitLeads = (contacts, truncated = false) =>
    leadsAdapter.emit({ contacts, truncated, cap: CONTACT_CAP });

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

const LEADS = [
    {
        leadId: '00Q000000000001',
        name: 'Hélène Dubois',
        email: 'h.dubois@unige.test',
        title: 'Professor of Cryptography',
        accountName: 'Université de Genève',
        accountOwnerName: 'Alex AM'
    },
    {
        leadId: '00Q000000000002',
        name: 'Anke Weber',
        email: 'a.weber@tuberlin.test',
        title: 'Professor',
        accountName: 'TU Berlin',
        accountOwnerName: 'Alex AM'
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
        status: 'Approved',
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
        addLeadInvitees.mockResolvedValue(1);
        submitMyInvitees.mockResolvedValue({ submitted: 1, approversNotified: 1 });
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
            emitSelectable([]);
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
            emitSelectable(SELECTABLE);
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
            emitSelectable(SELECTABLE);
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
            emitSelectable([
                { ...SELECTABLE[0], name: null, email: null, title: null },
                SELECTABLE[2]
            ]);
            await flush(1);
            await search(element, 'mia');
            expect(rowBoxes(element)).toHaveLength(1);
        });
    });

    describe('a truncated contact list', () => {
        const warning = () => element.shadowRoot.querySelector('[role="status"]');

        it('says nothing when the whole list came back', async () => {
            emitSelectable(SELECTABLE);
            await flush(1);
            expect(warning()).toBeNull();
        });

        it('warns, with the cap, when there are more contacts than were sent', async () => {
            emitSelectable(SELECTABLE, true);
            await flush(1);
            expect(warning().textContent).toContain(`first ${CONTACT_CAP} contacts`);
        });
    });

    describe('selections hidden by the filter', () => {
        const hiddenNote = () =>
            [...element.shadowRoot.querySelectorAll('p')].find((p) =>
                p.textContent.includes('outside the current filter')
            );

        beforeEach(async () => {
            emitSelectable(SELECTABLE);
            inviteesAdapter.emit(INVITEES);
            await flush(1);
        });

        it('says nothing while every selected contact is visible', async () => {
            await fire(rowBoxes(element)[0], 'change');
            expect(hiddenNote()).toBeUndefined();
        });

        it('keeps selections across a filter change and owns up to the mismatch', async () => {
            // Pick an Acme contact, then filter to Globex: the Add count still
            // includes it, so the component has to say so.
            rowBoxes(element)[0].checked = true;
            await fire(rowBoxes(element)[0], 'change');
            await filterAccount(element, 'Globex');

            expect(buttonStartingWith(element, 'Add Selected').label).toBe('Add Selected (1)');
            expect(hiddenNote().textContent).toContain('1 selected contact is');
        });

        it('pluralises the note for several hidden selections', async () => {
            for (const box of [rowBoxes(element)[0], rowBoxes(element)[1]]) {
                box.checked = true;
                await fire(box, 'change');
            }
            await filterAccount(element, 'Globex');
            expect(hiddenNote().textContent).toContain('2 selected contacts are');
        });
    });

    describe('adding contacts', () => {
        beforeEach(async () => {
            emitSelectable(SELECTABLE);
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
            emitSelectable(SELECTABLE);
            inviteesAdapter.emit(INVITEES);
            await flush(1);
        });

        const clickSubmit = async () => {
            buttonStartingWith(element, 'Submit My Invitees').dispatchEvent(
                new CustomEvent('click')
            );
            await flush();
        };

        it('counts only my own draft invitees', () => {
            // Jane is mine and Draft; John is mine but Approved; Ken is Draft but
            // someone else's — only Jane counts.
            expect(buttonStartingWith(element, 'Submit My Invitees').label).toBe(
                'Submit My Invitees for Approval (1)'
            );
        });

        it('is disabled when I have no drafts', async () => {
            inviteesAdapter.emit(INVITEES.filter((i) => !(i.mine && i.status === 'Draft')));
            await flush(1);
            expect(buttonStartingWith(element, 'Submit My Invitees').disabled).toBe(true);
        });

        it('submits for this event', async () => {
            await clickSubmit();
            expect(submitMyInvitees).toHaveBeenCalledWith({ eventId: EVENT_ID });
        });

        it('reports the submitted count and notified approvers', async () => {
            submitMyInvitees.mockResolvedValue({ submitted: 3, approversNotified: 2 });
            await clickSubmit();
            expect(toasts.at(-1).message).toBe(
                '3 invitee(s) sent for approval — 2 approver(s) notified.'
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

        it('shows the invitee type so Contact and Lead rows are told apart', async () => {
            inviteesAdapter.emit([
                { ...INVITEES[0], inviteeType: 'Contact', accountName: 'Acme' },
                {
                    inviteeId: 'a02000000000005',
                    contactName: 'Hélène Dubois',
                    accountName: 'Université de Genève',
                    inviteeType: 'Lead',
                    status: 'Pending Approval',
                    mine: true,
                    addedByName: 'Alex AM'
                }
            ]);
            await flush(1);
            const text = element.shadowRoot.textContent;
            expect(text).toContain('Université de Genève');
            expect(text).toContain('Lead');
        });
    });

    /**
     * The Leads tab exists because an Account means a transacting customer: a professor
     * has no Account, and a Contact without one would be a private contact nobody else
     * on the shared event could see.
     */
    describe('adding leads', () => {
        const leadBoxes = () =>
            rowBoxes(element).filter((b) => String(b.dataset.id).startsWith('00Q'));

        const clickAddLeads = async () => {
            buttonStartingWith(element, 'Add Selected Leads').dispatchEvent(
                new CustomEvent('click')
            );
            await flush();
        };

        beforeEach(async () => {
            emitLeads(LEADS);
            await flush(1);
        });

        it('lists the leads I own, grouped by their company text', () => {
            expect(leadBoxes()).toHaveLength(2);
            const headers = groupHeaders(element);
            expect(headers.some((h) => h.includes('Université de Genève'))).toBe(true);
            expect(headers.some((h) => h.includes('TU Berlin'))).toBe(true);
        });

        it('sends the selected lead ids, not contact ids', async () => {
            await fire(leadBoxes()[0], 'change', undefined);
            leadBoxes()[0].checked = true;
            await fire(leadBoxes()[0], 'change');
            await clickAddLeads();
            expect(addLeadInvitees).toHaveBeenCalledWith({
                eventId: EVENT_ID,
                leadIds: ['00Q000000000001']
            });
            expect(addInvitees).not.toHaveBeenCalled();
        });

        it('is disabled until something is selected', () => {
            expect(buttonStartingWith(element, 'Add Selected Leads').disabled).toBe(true);
        });

        it('keeps lead and contact selections apart', async () => {
            emitSelectable(SELECTABLE);
            await flush(1);
            const contactBox = rowBoxes(element).find((b) =>
                String(b.dataset.id).startsWith('003')
            );
            contactBox.checked = true;
            await fire(contactBox, 'change');
            // A contact selection must not arm the leads button.
            expect(buttonStartingWith(element, 'Add Selected Leads').disabled).toBe(true);
            expect(buttonStartingWith(element, 'Add Selected').label).toBe('Add Selected (1)');
        });

        it('reports how many were added and clears the selection', async () => {
            leadBoxes()[1].checked = true;
            await fire(leadBoxes()[1], 'change');
            await clickAddLeads();
            expect(toasts.at(-1)).toMatchObject({
                variant: 'success',
                message: '1 lead(s) added as Draft.'
            });
            expect(buttonStartingWith(element, 'Add Selected Leads').label).toBe(
                'Add Selected Leads (0)'
            );
        });

        it('surfaces an Apex failure and keeps the selection', async () => {
            addLeadInvitees.mockRejectedValue({ body: { message: 'lead not yours' } });
            leadBoxes()[0].checked = true;
            await fire(leadBoxes()[0], 'change');
            await clickAddLeads();
            expect(toasts.at(-1)).toMatchObject({ variant: 'error', message: 'lead not yours' });
            expect(buttonStartingWith(element, 'Add Selected Leads').label).toBe(
                'Add Selected Leads (1)'
            );
        });

        it('says so when the lead list is truncated', async () => {
            emitLeads(LEADS, true);
            await flush(1);
            expect(element.shadowRoot.textContent).toContain('Showing the first 2000 leads');
        });
    });
});
