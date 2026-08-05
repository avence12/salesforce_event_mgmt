import { createElement } from 'lwc';
import ApprovalConsole from 'c/approvalConsole';
import { registerApexTestWireAdapter } from '@salesforce/sfdx-lwc-jest';
import { refreshApex } from '@salesforce/apex';
import LightningConfirm from 'lightning/confirm';
import getPendingForMe from '@salesforce/apex/ApprovalConsoleController.getPendingForMe';
import decide from '@salesforce/apex/ApprovalConsoleController.decide';

jest.mock('@salesforce/apex/ApprovalConsoleController.decide', () => ({ default: jest.fn() }), {
    virtual: true
});
jest.mock('@salesforce/apex', () => ({ refreshApex: jest.fn() }), { virtual: true });

const pendingAdapter = registerApexTestWireAdapter(getPendingForMe);

const flush = async (times = 4) => {
    for (let i = 0; i < times; i++) {
        await new Promise((resolve) => setTimeout(resolve, 0));
    }
};

const EVENT_ID = 'a01000000000001';

const PENDING = [
    {
        inviteeId: 'a02000000000001',
        accountId: '001000000000001',
        accountName: 'Acme',
        contactName: 'Jane Doe',
        contactTitle: 'CTO',
        addedByName: 'Alex AM'
    },
    {
        inviteeId: 'a02000000000002',
        accountId: '001000000000001',
        accountName: 'Acme',
        contactName: 'John Roe',
        contactTitle: null,
        addedByName: 'Alex AM'
    },
    {
        inviteeId: 'a02000000000003',
        accountId: '001000000000002',
        accountName: 'Globex',
        contactName: 'Mia Lin',
        contactTitle: 'Head of Ops',
        addedByName: 'Sam AM'
    }
];

function mount() {
    const element = createElement('c-approval-console', { is: ApprovalConsole });
    element.recordId = EVENT_ID;
    document.body.appendChild(element);
    return element;
}

const buttons = (element) => [...element.shadowRoot.querySelectorAll('lightning-button')];
const actionButton = (element, verb) =>
    buttons(element).find((b) => String(b.label).startsWith(verb));
const rowBoxes = (element) => [
    ...element.shadowRoot.querySelectorAll('input[type="checkbox"][data-id]')
];
const selectAllBox = (element) =>
    element.shadowRoot.querySelector('.slds-checkbox_toggle input[type="checkbox"]');

async function toggle(box, checked) {
    box.checked = checked;
    const event = new CustomEvent('change');
    Object.defineProperty(event, 'target', { value: box, configurable: true });
    box.dispatchEvent(event);
    await flush(1);
}

describe('c-approval-console', () => {
    let element;
    let toasts;

    beforeEach(() => {
        decide.mockResolvedValue({ decided: 3, amsNotified: 0 });
        refreshApex.mockResolvedValue(undefined);
        // The stub's static open() throws by design — replacing it is the
        // documented way to test LightningConfirm. Default to the user
        // confirming so the reject specs still reach the decision path;
        // the specs below cover declining.
        LightningConfirm.open = jest.fn().mockResolvedValue(true);
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

    describe('rendering', () => {
        it('stays hidden until there is something pending', async () => {
            pendingAdapter.emit([]);
            await flush(1);
            expect(element.shadowRoot.querySelector('lightning-card')).toBeNull();
        });

        it('groups rows by account', async () => {
            pendingAdapter.emit(PENDING);
            await flush(1);
            const headers = [...element.shadowRoot.querySelectorAll('.group-header')];
            expect(headers.map((h) => h.textContent.trim())).toEqual(['Acme', 'Globex']);
        });

        it('keeps every invitee across the groups', async () => {
            pendingAdapter.emit(PENDING);
            await flush(1);
            expect(element.shadowRoot.querySelectorAll('.row')).toHaveLength(3);
        });

        it('appends the title to the name when there is one', async () => {
            pendingAdapter.emit(PENDING);
            await flush(1);
            expect(element.shadowRoot.textContent).toContain('Jane Doe · CTO');
        });

        it('shows the bare name when the contact has no title', async () => {
            pendingAdapter.emit(PENDING);
            await flush(1);
            expect(element.shadowRoot.textContent).toContain('John Roe');
            expect(element.shadowRoot.textContent).not.toContain('John Roe ·');
        });

        it('credits the AM who added each invitee', async () => {
            pendingAdapter.emit(PENDING);
            await flush(1);
            expect(element.shadowRoot.textContent).toContain('Added by Alex AM');
            expect(element.shadowRoot.textContent).toContain('Added by Sam AM');
        });

        it('passes the record id to the wire', () => {
            expect(pendingAdapter.getLastConfig()).toEqual({ eventId: EVENT_ID });
        });
    });

    describe('selection', () => {
        beforeEach(async () => {
            pendingAdapter.emit(PENDING);
            await flush(1);
        });

        it('selects everything by default', () => {
            // The console's whole point is two-tap bulk approval.
            expect(rowBoxes(element).every((b) => b.checked)).toBe(true);
            expect(actionButton(element, 'Approve').label).toBe('Approve (3)');
        });

        it('ticks the select-all toggle when everything is selected', () => {
            expect(selectAllBox(element).checked).toBe(true);
        });

        it('counts the total on the select-all label', () => {
            expect(element.shadowRoot.textContent).toContain('Select All (3)');
        });

        it('deselecting one row lowers both action counts', async () => {
            await toggle(rowBoxes(element)[0], false);
            expect(actionButton(element, 'Approve').label).toBe('Approve (2)');
            expect(actionButton(element, 'Reject').label).toBe('Reject (2)');
        });

        it('deselecting one row unticks the select-all toggle', async () => {
            await toggle(rowBoxes(element)[0], false);
            expect(selectAllBox(element).checked).toBe(false);
        });

        it('re-selecting a row restores the count', async () => {
            await toggle(rowBoxes(element)[0], false);
            await toggle(rowBoxes(element)[0], true);
            expect(actionButton(element, 'Approve').label).toBe('Approve (3)');
        });

        it('select-all clears everything when unticked', async () => {
            await toggle(selectAllBox(element), false);
            expect(rowBoxes(element).some((b) => b.checked)).toBe(false);
            expect(actionButton(element, 'Approve').label).toBe('Approve (0)');
        });

        it('select-all re-selects everything when ticked', async () => {
            await toggle(selectAllBox(element), false);
            await toggle(selectAllBox(element), true);
            expect(rowBoxes(element).every((b) => b.checked)).toBe(true);
        });

        it('disables both actions when nothing is selected', async () => {
            await toggle(selectAllBox(element), false);
            expect(actionButton(element, 'Approve').disabled).toBe(true);
            expect(actionButton(element, 'Reject').disabled).toBe(true);
        });
    });

    describe('deciding', () => {
        beforeEach(async () => {
            pendingAdapter.emit(PENDING);
            await flush(1);
        });

        const click = async (verb) => {
            actionButton(element, verb).dispatchEvent(new CustomEvent('click'));
            await flush();
        };

        it('approves the selected invitees for this event', async () => {
            await click('Approve');
            expect(decide).toHaveBeenCalledWith({
                eventId: EVENT_ID,
                inviteeIds: PENDING.map((p) => p.inviteeId),
                approve: true
            });
        });

        it('rejects with the same payload but approve false', async () => {
            await click('Reject');
            expect(decide.mock.calls[0][0].approve).toBe(false);
        });

        describe('the reject confirmation', () => {
            it('asks before rejecting anything', async () => {
                await click('Reject');
                expect(LightningConfirm.open).toHaveBeenCalledTimes(1);
                const opts = LightningConfirm.open.mock.calls[0][0];
                expect(opts.label).toBe('Reject 3 invitees?');
                expect(opts.theme).toBe('warning');
                expect(opts.message).toContain('re-add and re-submit');
            });

            it('decides nothing when the user backs out', async () => {
                LightningConfirm.open.mockResolvedValue(false);
                await click('Reject');
                expect(decide).not.toHaveBeenCalled();
                expect(toasts).toHaveLength(0);
            });

            it('singularises the prompt for one invitee', async () => {
                await toggle(rowBoxes(element)[0], false);
                await toggle(rowBoxes(element)[1], false);
                await click('Reject');
                expect(LightningConfirm.open.mock.calls[0][0].label).toBe('Reject 1 invitee?');
            });

            it('never asks before approving — that is the one-tap path', async () => {
                await click('Approve');
                expect(LightningConfirm.open).not.toHaveBeenCalled();
                expect(decide).toHaveBeenCalledTimes(1);
            });
        });

        it('sends only the still-selected invitees', async () => {
            await toggle(rowBoxes(element)[0], false);
            await click('Approve');
            expect(decide.mock.calls[0][0].inviteeIds).toEqual([
                'a02000000000002',
                'a02000000000003'
            ]);
        });

        it('reports how many were approved', async () => {
            await click('Approve');
            expect(toasts.at(-1)).toMatchObject({ variant: 'success' });
            expect(toasts.at(-1).message).toBe('3 invitee(s) approved.');
        });

        it('uses the rejected wording for a rejection', async () => {
            decide.mockResolvedValue({ decided: 2, amsNotified: 0 });
            await click('Reject');
            expect(toasts.at(-1).message).toBe('2 invitee(s) rejected.');
        });

        it('mentions the notified AMs when a batch completes', async () => {
            decide.mockResolvedValue({ decided: 3, amsNotified: 2 });
            await click('Approve');
            expect(toasts.at(-1).message).toContain('2 AM(s) notified');
        });

        it('stays quiet about AMs when none were notified', async () => {
            await click('Approve');
            expect(toasts.at(-1).message).not.toContain('notified');
        });

        it('refreshes the pending list afterwards', async () => {
            await click('Approve');
            expect(refreshApex).toHaveBeenCalledTimes(1);
        });

        it('surfaces an Apex failure as an error toast', async () => {
            decide.mockRejectedValue({ body: { message: 'no permission' } });
            await click('Approve');
            expect(toasts.at(-1)).toMatchObject({ variant: 'error', message: 'no permission' });
        });

        it('falls back to a plain Error message', async () => {
            decide.mockRejectedValue(new Error('network down'));
            await click('Approve');
            expect(toasts.at(-1).message).toBe('network down');
        });

        it('falls back to a generic message for an opaque failure', async () => {
            decide.mockRejectedValue({});
            await click('Approve');
            expect(toasts.at(-1).message).toBe('Unexpected error');
        });

        it('does not refresh when the decision failed', async () => {
            decide.mockRejectedValue(new Error('boom'));
            await click('Approve');
            expect(refreshApex).not.toHaveBeenCalled();
        });

        it('re-enables the actions after a failure', async () => {
            decide.mockRejectedValue(new Error('boom'));
            await click('Approve');
            expect(actionButton(element, 'Approve').disabled).toBe(false);
        });
    });
});
