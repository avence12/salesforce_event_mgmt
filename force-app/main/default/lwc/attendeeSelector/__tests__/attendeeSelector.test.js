import { createElement } from 'lwc';
import AttendeeSelector from 'c/attendeeSelector';
import { registerApexTestWireAdapter } from '@salesforce/sfdx-lwc-jest';
import { refreshApex } from '@salesforce/apex';
import getSelectableAttendees from '@salesforce/apex/InviteeSelectorController.getSelectableAttendees';
import getAllInvitees from '@salesforce/apex/InviteeSelectorController.getAllInvitees';
import addAttendees from '@salesforce/apex/InviteeSelectorController.addAttendees';
import submitMyInvitees from '@salesforce/apex/InviteeSelectorController.submitMyInvitees';

jest.mock(
    '@salesforce/apex/InviteeSelectorController.addAttendees',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/InviteeSelectorController.submitMyInvitees',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock('@salesforce/apex', () => ({ refreshApex: jest.fn() }), { virtual: true });

const selectableAdapter = registerApexTestWireAdapter(getSelectableAttendees);
const inviteesAdapter = registerApexTestWireAdapter(getAllInvitees);

const ATTENDEE_CAP = 2000;

/**
 * getSelectableAttendees returns a wrapper, not a bare list, so a truncated
 * result can say so instead of reading as "that is everyone".
 */
const emitSelectable = (attendees, truncated = false) =>
    selectableAdapter.emit({ attendees, truncated, cap: ATTENDEE_CAP });

const flush = async (times = 4) => {
    for (let i = 0; i < times; i++) {
        await new Promise((resolve) => setTimeout(resolve, 0));
    }
};

const EVENT_ID = 'a01000000000001';

const SELECTABLE = [
    {
        attendeeId: 'a03000000000001',
        name: 'Jane Doe',
        email: 'jane@acme.example',
        title: 'CTO',
        company: 'Acme Corp'
    },
    {
        attendeeId: 'a03000000000002',
        name: 'John Roe',
        email: 'john@acme.example',
        title: 'Buyer',
        company: 'Acme Corp'
    },
    {
        attendeeId: 'a03000000000003',
        name: 'Hélène Dubois',
        email: 'h.dubois@unige.example',
        title: 'Professor of Cryptography',
        company: 'Université de Genève'
    }
];

const INVITEES = [
    {
        inviteeId: 'a02000000000001',
        attendeeName: 'Jane Doe',
        company: 'Acme Corp',
        status: 'Draft',
        mine: true,
        addedByName: 'Alex AM'
    },
    {
        inviteeId: 'a02000000000002',
        attendeeName: 'John Roe',
        company: 'Acme Corp',
        status: 'Approved',
        mine: true,
        addedByName: 'Alex AM'
    },
    {
        inviteeId: 'a02000000000003',
        attendeeName: 'Hélène Dubois',
        company: 'Université de Genève',
        status: 'Approved',
        mine: false,
        addedByName: 'Sam AM'
    },
    {
        inviteeId: 'a02000000000004',
        attendeeName: 'Ken Ito',
        company: 'Quantumsoft',
        status: 'Draft',
        mine: false,
        addedByName: 'Sam AM'
    }
];

function mount() {
    const element = createElement('c-attendee-selector', { is: AttendeeSelector });
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

async function filterCompany(element, value) {
    const combobox = element.shadowRoot.querySelector('lightning-combobox');
    await fire(combobox, 'change', { value });
}

describe('c-attendee-selector', () => {
    let element;
    let toasts;

    beforeEach(() => {
        addAttendees.mockResolvedValue(2);
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
            expect(element.shadowRoot.textContent).toContain('No selectable attendees');
        });

        it('shows an empty state when there are no invitees', async () => {
            inviteesAdapter.emit([]);
            await flush(1);
            expect(element.shadowRoot.textContent).toContain('No invitees yet.');
        });
    });

    describe('organisation filter options', () => {
        it('lists each organisation once, sorted, behind an All option', async () => {
            emitSelectable(SELECTABLE);
            await flush(1);
            const combobox = element.shadowRoot.querySelector('lightning-combobox');
            expect(combobox.options).toEqual([
                { label: 'All', value: '' },
                { label: 'Acme Corp', value: 'Acme Corp' },
                { label: 'Université de Genève', value: 'Université de Genève' }
            ]);
        });
    });

    describe('grouping and filtering', () => {
        beforeEach(async () => {
            emitSelectable(SELECTABLE);
            await flush(1);
        });

        it('groups attendees by their company text', () => {
            expect(groupHeaders(element)).toHaveLength(2);
        });

        it('names the organisation and the selected tally in each header', () => {
            expect(groupHeaders(element)[0]).toBe('Acme Corp — 0/2 selected');
        });

        it('updates the tally as rows are selected', async () => {
            await fire(Object.assign(rowBoxes(element)[0], { checked: true }), 'change');
            expect(groupHeaders(element)[0]).toBe('Acme Corp — 1/2 selected');
        });

        it('labels a group whose company is blank rather than showing an empty header', async () => {
            emitSelectable([{ ...SELECTABLE[0], company: null }]);
            await flush(1);
            expect(groupHeaders(element)[0]).toContain('(no company)');
        });

        it('filters to a single organisation', async () => {
            await filterCompany(element, 'Université de Genève');
            expect(groupHeaders(element)).toEqual(['Université de Genève — 0/1 selected']);
        });

        it('the All option restores every organisation', async () => {
            await filterCompany(element, 'Acme Corp');
            await filterCompany(element, '');
            expect(groupHeaders(element)).toHaveLength(2);
        });

        it('searches by name', async () => {
            await search(element, 'hélène');
            expect(rowBoxes(element)).toHaveLength(1);
        });

        it('searches by email', async () => {
            await search(element, 'john@acme');
            expect(rowBoxes(element)).toHaveLength(1);
        });

        it('searches by title', async () => {
            await search(element, 'cryptography');
            expect(rowBoxes(element)).toHaveLength(1);
        });

        it('matches case-insensitively', async () => {
            await search(element, 'JANE');
            expect(rowBoxes(element)).toHaveLength(1);
        });

        it('combines the search term with the organisation filter', async () => {
            await filterCompany(element, 'Acme Corp');
            await search(element, 'hélène');
            expect(rowBoxes(element)).toHaveLength(0);
        });

        it('an empty term shows everything again', async () => {
            await search(element, 'jane');
            await search(element, '');
            expect(rowBoxes(element)).toHaveLength(3);
        });

        it('a term matching nothing yields no rows', async () => {
            await search(element, 'zzzz');
            expect(rowBoxes(element)).toHaveLength(0);
        });

        it('searches past an attendee with null name, email and title', async () => {
            // An imported attendee legitimately has no email or title; an unguarded
            // .toLowerCase() on those would throw and blank the whole table.
            emitSelectable([
                { ...SELECTABLE[0], name: null, email: null, title: null },
                SELECTABLE[2]
            ]);
            await flush(1);
            await search(element, 'hélène');
            expect(rowBoxes(element)).toHaveLength(1);
        });
    });

    describe('a truncated attendee list', () => {
        const warning = () => element.shadowRoot.querySelector('[role="status"]');

        it('says nothing when the whole list came back', async () => {
            emitSelectable(SELECTABLE);
            await flush(1);
            expect(warning()).toBeNull();
        });

        it('warns, with the cap, when there are more attendees than were sent', async () => {
            emitSelectable(SELECTABLE, true);
            await flush(1);
            expect(warning().textContent).toContain(`first ${ATTENDEE_CAP} attendees`);
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

        it('says nothing while every selected attendee is visible', async () => {
            await fire(rowBoxes(element)[0], 'change');
            expect(hiddenNote()).toBeUndefined();
        });

        it('keeps selections across a filter change and owns up to the mismatch', async () => {
            rowBoxes(element)[0].checked = true;
            await fire(rowBoxes(element)[0], 'change');
            await filterCompany(element, 'Université de Genève');

            expect(buttonStartingWith(element, 'Add Selected').label).toBe('Add Selected (1)');
            expect(hiddenNote().textContent).toContain('1 selected attendee is');
        });

        it('pluralises the note for several hidden selections', async () => {
            for (const box of [rowBoxes(element)[0], rowBoxes(element)[1]]) {
                box.checked = true;
                await fire(box, 'change');
            }
            await filterCompany(element, 'Université de Genève');
            expect(hiddenNote().textContent).toContain('2 selected attendees are');
        });
    });

    describe('adding attendees', () => {
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

        it('deselecting removes the attendee again', async () => {
            const box = rowBoxes(element)[0];
            await fire(Object.assign(box, { checked: true }), 'change');
            await fire(Object.assign(box, { checked: false }), 'change');
            expect(buttonStartingWith(element, 'Add Selected').label).toBe('Add Selected (0)');
        });

        it('sends the selected attendee ids for this event', async () => {
            await fire(Object.assign(rowBoxes(element)[0], { checked: true }), 'change');
            await clickAdd();
            expect(addAttendees).toHaveBeenCalledWith({
                eventId: EVENT_ID,
                attendeeIds: ['a03000000000001']
            });
        });

        it('reports how many were added', async () => {
            await fire(Object.assign(rowBoxes(element)[0], { checked: true }), 'change');
            await clickAdd();
            expect(toasts.at(-1)).toMatchObject({ variant: 'success' });
            expect(toasts.at(-1).message).toBe('2 attendee(s) added as Draft.');
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
            addAttendees.mockRejectedValue({ body: { message: 'attendee was deleted' } });
            await fire(Object.assign(rowBoxes(element)[0], { checked: true }), 'change');
            await clickAdd();
            expect(toasts.at(-1)).toMatchObject({
                variant: 'error',
                message: 'attendee was deleted'
            });
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
            submitMyInvitees.mockResolvedValue({ submitted: 3, approversNotified: 1 });
            await clickSubmit();
            expect(toasts.at(-1).message).toBe(
                '3 invitee(s) sent for approval — 1 approver(s) notified.'
            );
        });

        it('refreshes the invitee list afterwards', async () => {
            await clickSubmit();
            expect(refreshApex).toHaveBeenCalledTimes(1);
        });

        it('surfaces the no-manager refusal rather than looking like a success', async () => {
            submitMyInvitees.mockRejectedValue({
                body: { message: 'your user record has no Manager' }
            });
            await clickSubmit();
            expect(toasts.at(-1)).toMatchObject({
                variant: 'error',
                message: 'your user record has no Manager'
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

        it('shows the attendee name and organisation read through the formula fields', () => {
            const text = element.shadowRoot.textContent;
            expect(text).toContain('Hélène Dubois');
            expect(text).toContain('Université de Genève');
        });
    });
});
