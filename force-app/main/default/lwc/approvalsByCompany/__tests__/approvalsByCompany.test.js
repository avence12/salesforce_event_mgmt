import { createElement } from 'lwc';
import ApprovalsByCompany from 'c/approvalsByCompany';
import { registerApexTestWireAdapter } from '@salesforce/sfdx-lwc-jest';
import { refreshApex } from '@salesforce/apex';
import getMyPendingByCompany from '@salesforce/apex/InviteeApprovalController.getMyPendingByCompany';
import decide from '@salesforce/apex/InviteeApprovalController.decide';
import getAddableAttendees from '@salesforce/apex/InviteeApprovalController.getAddableAttendees';
import addInvitees from '@salesforce/apex/InviteeApprovalController.addInvitees';

jest.mock('@salesforce/apex/InviteeApprovalController.decide', () => ({ default: jest.fn() }), {
    virtual: true
});
jest.mock(
    '@salesforce/apex/InviteeApprovalController.addInvitees',
    () => ({ default: jest.fn() }),
    {
        virtual: true
    }
);
jest.mock('@salesforce/apex', () => ({ refreshApex: jest.fn() }), { virtual: true });

const pendingAdapter = registerApexTestWireAdapter(getMyPendingByCompany);
const addableAdapter = registerApexTestWireAdapter(getAddableAttendees);

const flush = async (times = 4) => {
    for (let i = 0; i < times; i++) {
        await new Promise((resolve) => setTimeout(resolve, 0));
    }
};

const EVENT_ID = 'a01000000000001';

const ACME = {
    groupKey: '001000000000001',
    company: 'Acme Corporation',
    custCd: 'CUST-0042',
    hasCustomer: true,
    invitees: [
        {
            inviteeId: 'a02000000000001',
            name: 'Emily Carter',
            title: 'Senior Manager',
            salutation: 'Ms',
            vip: false,
            remark: null,
            addedByName: 'Alex AM',
            level: 2,
            levels: 3
        },
        {
            inviteeId: 'a02000000000002',
            name: 'Robert Kim',
            title: 'Head of Data',
            salutation: null,
            vip: false,
            remark: null,
            addedByName: 'Alex AM',
            level: 2,
            levels: 3
        },
        {
            inviteeId: 'a02000000000003',
            name: 'Lena Farrow',
            title: 'Partner',
            salutation: 'Dr',
            vip: true,
            remark: 'Keynote guest, confirmed by marketing',
            addedByName: 'Alex AM',
            level: 2,
            levels: 3
        }
    ]
};

const GENEVA = {
    groupKey: 'text:Université de Genève',
    company: 'Université de Genève',
    custCd: null,
    hasCustomer: false,
    invitees: [
        {
            inviteeId: 'a02000000000009',
            name: 'Hélène Dubois',
            title: 'Professor',
            salutation: 'Prof',
            vip: false,
            remark: null,
            addedByName: 'Maria AM',
            level: 1,
            levels: 1
        }
    ]
};

const build = () => {
    const el = createElement('c-approvals-by-company', { is: ApprovalsByCompany });
    el.recordId = EVENT_ID;
    document.body.appendChild(el);
    return el;
};

const groupBoxes = (el) => [...el.shadowRoot.querySelectorAll('[data-group-box]')];
const rowBoxes = (el) => [...el.shadowRoot.querySelectorAll('[data-id]')];
const buttons = (el) => [...el.shadowRoot.querySelectorAll('lightning-button')];
const buttonLabels = (el) => buttons(el).map((b) => b.label);
const buttonByLabel = (el, label) => buttons(el).find((b) => b.label === label);

// ★R13 add panel helpers
const ATTENDEE_CAP = 2000;
const attendee = (n, over = {}) => ({
    attendeeId: `a03${String(n).padStart(12, '0')}`,
    name: `Person ${n}`,
    title: 'Analyst',
    email: `person${n}@evt.example`,
    company: 'Acme Corporation',
    ...over
});
const ADDABLE = [
    attendee(1, {
        name: 'Nina Alvarez',
        title: 'Treasurer',
        email: 'nina@nordbank.example',
        company: 'Nordbank AG'
    }),
    attendee(2, { name: 'Omar Haddad', title: 'Risk Lead' }),
    attendee(3, { name: 'Priya Nair', title: 'Economist', company: 'Université de Genève' })
];
const emitAddable = (attendees, over = {}) =>
    addableAdapter.emit({ canAdd: true, attendees, truncated: false, cap: ATTENDEE_CAP, ...over });
const addBoxes = (el) => [...el.shadowRoot.querySelectorAll('[data-attendee]')];
const openAddPanel = async (el) => {
    buttonByLabel(el, 'Add invitees from the attendee list').click();
    await flush();
};
const tickAttendee = async (el, index) => {
    const box = addBoxes(el)[index];
    box.checked = true;
    box.dispatchEvent(new CustomEvent('change'));
    await flush();
};
const search = async (el, term) => {
    const input = el.shadowRoot.querySelector('.add-search');
    input.value = term;
    input.dispatchEvent(new CustomEvent('change', { target: { value: term } }));
    await flush();
};

describe('c-approvals-by-company', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    describe('empty state', () => {
        it('says nothing is waiting rather than showing an empty table', async () => {
            const el = build();
            pendingAdapter.emit([]);
            await flush();

            expect(el.shadowRoot.querySelector('table')).toBeNull();
            expect(el.shadowRoot.textContent).toContain('Nothing on this event is waiting on you');
        });
    });

    describe('rendering the pending work', () => {
        it('groups invitees under the company they were invited as', async () => {
            const el = build();
            pendingAdapter.emit([ACME, GENEVA]);
            await flush();

            expect(el.shadowRoot.textContent).toContain('Acme Corporation');
            expect(el.shadowRoot.textContent).toContain('CUST-0042');
            expect(el.shadowRoot.textContent).toContain('Université de Genève');
            expect(groupBoxes(el)).toHaveLength(2);
            expect(rowBoxes(el)).toHaveLength(4);
        });

        it('counts the whole workload, not the visible group', async () => {
            const el = build();
            pendingAdapter.emit([ACME, GENEVA]);
            await flush();

            expect(el.shadowRoot.textContent).toContain('4 invitees awaiting your approval');
        });

        it('marks a guest with no customer instead of leaving the code blank', async () => {
            const el = build();
            pendingAdapter.emit([GENEVA]);
            await flush();

            expect(el.shadowRoot.textContent).toContain('Not a customer');
        });

        it('shows the salutation, the VIP badge and the remark the AM wrote', async () => {
            const el = build();
            pendingAdapter.emit([ACME]);
            await flush();

            const text = el.shadowRoot.textContent;
            expect(text).toContain('Dr Lena Farrow');
            expect(text).toContain('VIP');
            expect(text).toContain('Keynote guest, confirmed by marketing');
        });

        // ★R9 An approver in the middle of a chain is deciding something different from the
        // last signature, and neither the standard Approvals list nor the record page tells
        // them which they are.
        it('says which level of the chain the approver is on', async () => {
            const el = build();
            pendingAdapter.emit([ACME]);
            await flush();

            expect(el.shadowRoot.textContent).toContain('Level 2 of 3');
        });

        it('shows no level badge when the chain has only one level', async () => {
            const el = build();
            pendingAdapter.emit([GENEVA]);
            await flush();

            expect(el.shadowRoot.textContent).not.toContain('Level 1 of 1');
        });

        it('falls back to the bare name when there is no salutation', async () => {
            const el = build();
            pendingAdapter.emit([ACME]);
            await flush();

            expect(el.shadowRoot.textContent).toContain('Robert Kim');
            expect(el.shadowRoot.textContent).not.toContain('null Robert Kim');
        });
    });

    describe('selection', () => {
        it('starts with nothing selected, so a bulk approval is never the default', async () => {
            const el = build();
            pendingAdapter.emit([ACME, GENEVA]);
            await flush();

            expect(rowBoxes(el).every((b) => !b.checked)).toBe(true);
            expect(buttonByLabel(el, 'Approve selected (0)').disabled).toBe(true);
        });

        it('ticking the company selects everyone in it — the whole requirement, in one tick', async () => {
            const el = build();
            pendingAdapter.emit([ACME, GENEVA]);
            await flush();

            const acmeBox = groupBoxes(el)[0];
            acmeBox.checked = true;
            acmeBox.dispatchEvent(new CustomEvent('change'));
            await flush();

            expect(rowBoxes(el).filter((b) => b.checked)).toHaveLength(3);
            expect(buttonLabels(el)).toContain('Approve 3');
            expect(buttonLabels(el)).toContain('Approve selected (3)');
        });

        it('ticking the company again clears only that company', async () => {
            const el = build();
            pendingAdapter.emit([ACME, GENEVA]);
            await flush();

            const [acmeBox, genevaBox] = groupBoxes(el);
            acmeBox.checked = true;
            acmeBox.dispatchEvent(new CustomEvent('change'));
            genevaBox.checked = true;
            genevaBox.dispatchEvent(new CustomEvent('change'));
            await flush();
            expect(buttonLabels(el)).toContain('Approve selected (4)');

            const acmeAgain = groupBoxes(el)[0];
            acmeAgain.checked = false;
            acmeAgain.dispatchEvent(new CustomEvent('change'));
            await flush();

            expect(buttonLabels(el)).toContain('Approve selected (1)');
        });

        it('leaves the company checkbox indeterminate when only some of it is picked', async () => {
            const el = build();
            pendingAdapter.emit([ACME]);
            await flush();

            const row = rowBoxes(el)[0];
            row.checked = true;
            row.dispatchEvent(new CustomEvent('change'));
            await flush();

            expect(groupBoxes(el)[0].indeterminate).toBe(true);
            expect(groupBoxes(el)[0].checked).toBe(false);
        });

        it('clears indeterminate once every row in the company is picked', async () => {
            const el = build();
            pendingAdapter.emit([ACME]);
            await flush();

            rowBoxes(el).forEach((b) => {
                b.checked = true;
                b.dispatchEvent(new CustomEvent('change'));
            });
            await flush();

            expect(groupBoxes(el)[0].indeterminate).toBe(false);
            expect(groupBoxes(el)[0].checked).toBe(true);
        });
    });

    describe('deciding', () => {
        const selectAcme = async (el) => {
            const box = groupBoxes(el)[0];
            box.checked = true;
            box.dispatchEvent(new CustomEvent('change'));
            await flush();
        };

        it("sends only the company's selected ids when its Approve button is used", async () => {
            decide.mockResolvedValue({ decided: 3, skipped: 0 });
            const el = build();
            pendingAdapter.emit([ACME, GENEVA]);
            await flush();

            // Select both companies, then approve one of them.
            groupBoxes(el).forEach((b) => {
                b.checked = true;
                b.dispatchEvent(new CustomEvent('change'));
            });
            await flush();

            buttonByLabel(el, 'Approve 3').click();
            await flush();

            expect(decide).toHaveBeenCalledTimes(1);
            const call = decide.mock.calls[0][0];
            expect(call.eventId).toBe(EVENT_ID);
            expect(call.approve).toBe(true);
            expect(call.inviteeIds.sort()).toEqual([
                'a02000000000001',
                'a02000000000002',
                'a02000000000003'
            ]);
            expect(call.inviteeIds).not.toContain('a02000000000009');
        });

        it('rejects through the same path with approve false', async () => {
            decide.mockResolvedValue({ decided: 3, skipped: 0 });
            const el = build();
            pendingAdapter.emit([ACME]);
            await flush();
            await selectAcme(el);

            buttonByLabel(el, 'Reject 3').click();
            await flush();

            expect(decide.mock.calls[0][0].approve).toBe(false);
        });

        it('passes the comment along and clears it afterwards', async () => {
            decide.mockResolvedValue({ decided: 3, skipped: 0 });
            const el = build();
            pendingAdapter.emit([ACME]);
            await flush();

            const input = el.shadowRoot.querySelector('lightning-input');
            input.value = 'Budget approved for this account';
            input.dispatchEvent(new CustomEvent('change', { target: input }));
            await flush();
            await selectAcme(el);

            buttonByLabel(el, 'Approve 3').click();
            await flush();

            expect(decide.mock.calls[0][0].comment).toBe('Budget approved for this account');
            expect(el.shadowRoot.querySelector('lightning-input').value).toBe('');
        });

        it('clears the selection and refreshes once a decision lands', async () => {
            decide.mockResolvedValue({ decided: 3, skipped: 0 });
            const el = build();
            pendingAdapter.emit([ACME]);
            await flush();
            await selectAcme(el);

            buttonByLabel(el, 'Approve 3').click();
            await flush();

            expect(refreshApex).toHaveBeenCalled();
            expect(buttonLabels(el)).toContain('Approve selected (0)');
        });

        it('reports rows that stopped being theirs rather than quietly shrinking the count', async () => {
            decide.mockResolvedValue({ decided: 2, skipped: 1 });
            const handler = jest.fn();
            const el = build();
            el.addEventListener('lightning__showtoast', handler);
            pendingAdapter.emit([ACME]);
            await flush();
            await selectAcme(el);

            buttonByLabel(el, 'Approve 3').click();
            await flush();

            expect(handler).toHaveBeenCalled();
            const { detail } = handler.mock.calls[0][0];
            expect(detail.message).toContain('2 invitee(s) approved');
            expect(detail.message).toContain('1 were no longer waiting on you');
        });

        it('surfaces a server refusal as an error toast and keeps the selection', async () => {
            decide.mockRejectedValue({
                body: { message: 'None of the selected invitees are waiting on you' }
            });
            const handler = jest.fn();
            const el = build();
            el.addEventListener('lightning__showtoast', handler);
            pendingAdapter.emit([ACME]);
            await flush();
            await selectAcme(el);

            buttonByLabel(el, 'Approve 3').click();
            await flush();

            const { detail } = handler.mock.calls[0][0];
            expect(detail.variant).toBe('error');
            expect(detail.title).toBe('Nothing was changed');
            expect(detail.message).toContain('None of the selected invitees are waiting on you');
            // The rows stay picked: the user's next move is usually to refresh and retry,
            // and re-ticking a whole company by hand would be a punishment for a race.
            expect(buttonLabels(el)).toContain('Approve selected (3)');
        });

        it('drops a selected id that has disappeared from a later load', async () => {
            const el = build();
            pendingAdapter.emit([ACME]);
            await flush();
            await selectAcme(el);
            expect(buttonLabels(el)).toContain('Approve selected (3)');

            // Somebody else decided two of them; the wire re-emits what is left.
            pendingAdapter.emit([{ ...ACME, invitees: [ACME.invitees[0]] }]);
            await flush();

            expect(buttonLabels(el)).toContain('Approve selected (1)');
        });
    });

    /**
     * ★R13 The approver's own way of putting somebody forward. The behaviour worth pinning
     * down is not the picker — it is that the panel is invisible to anyone the server has not
     * called an approver, and that the toast says where each added person actually went.
     */
    describe('adding invitees mid-review', () => {
        it('shows no add controls at all until the server says this user approves something here', async () => {
            const el = build();
            pendingAdapter.emit([ACME]);
            addableAdapter.emit({
                canAdd: false,
                attendees: [],
                truncated: false,
                cap: ATTENDEE_CAP
            });
            await flush();

            expect(buttonLabels(el)).not.toContain('Add invitees from the attendee list');
        });

        it('offers the panel even when nothing is left waiting, so a late addition is still possible', async () => {
            const el = build();
            pendingAdapter.emit([]);
            emitAddable(ADDABLE);
            await flush();

            expect(el.shadowRoot.textContent).toContain('Nothing on this event is waiting on you');
            expect(buttonLabels(el)).toContain('Add invitees from the attendee list');
        });

        it('stays folded away until it is asked for', async () => {
            const el = build();
            pendingAdapter.emit([ACME]);
            emitAddable(ADDABLE);
            await flush();

            expect(addBoxes(el)).toHaveLength(0);

            await openAddPanel(el);
            expect(addBoxes(el)).toHaveLength(3);
            expect(el.shadowRoot.textContent).toContain('Nina Alvarez');

            buttonByLabel(el, 'Close').click();
            await flush();
            expect(addBoxes(el)).toHaveLength(0);
        });

        it('says plainly that an addition is approved like any other invitation', async () => {
            const el = build();
            pendingAdapter.emit([ACME]);
            emitAddable(ADDABLE);
            await flush();
            await openAddPanel(el);

            expect(el.shadowRoot.textContent).toContain('account manager who owns their customer');
        });

        it('searches across name, organisation and email', async () => {
            const el = build();
            pendingAdapter.emit([ACME]);
            emitAddable(ADDABLE);
            await flush();
            await openAddPanel(el);

            await search(el, 'nordbank');
            expect(addBoxes(el)).toHaveLength(1);
            expect(el.shadowRoot.textContent).toContain('Nina Alvarez');

            await search(el, 'person2@evt');
            expect(addBoxes(el)).toHaveLength(1);
            expect(el.shadowRoot.textContent).toContain('Omar Haddad');

            await search(el, 'economist');
            expect(addBoxes(el)).toHaveLength(1);
            expect(el.shadowRoot.textContent).toContain('Priya Nair');
        });

        it('says how many matches it is not showing rather than showing a wall of rows', async () => {
            const many = Array.from({ length: 30 }, (unused, i) => attendee(i + 10));
            const el = build();
            pendingAdapter.emit([ACME]);
            emitAddable(many);
            await flush();
            await openAddPanel(el);

            expect(addBoxes(el)).toHaveLength(25);
            expect(el.shadowRoot.textContent).toContain('5 more attendee(s) match');
        });

        it('repeats the server truncation notice rather than implying that is everyone', async () => {
            const el = build();
            pendingAdapter.emit([ACME]);
            emitAddable(ADDABLE, { truncated: true });
            await flush();
            await openAddPanel(el);

            expect(el.shadowRoot.textContent).toContain(
                `Only the first ${ATTENDEE_CAP} attendees were loaded`
            );
        });

        it('says when a search has hidden something already ticked', async () => {
            const el = build();
            pendingAdapter.emit([ACME]);
            emitAddable(ADDABLE);
            await flush();
            await openAddPanel(el);
            await tickAttendee(el, 0);

            await search(el, 'priya');
            expect(el.shadowRoot.textContent).toContain(
                '1 ticked attendee(s) are outside the current search'
            );
            expect(buttonLabels(el)).toContain('Add and submit (1)');
        });

        it('explains an empty picker instead of showing an empty table', async () => {
            const el = build();
            pendingAdapter.emit([ACME]);
            emitAddable([]);
            await flush();
            await openAddPanel(el);

            expect(el.shadowRoot.querySelector('.no-matches')).not.toBeNull();
            expect(el.shadowRoot.textContent).toContain(
                'only the AM who proposed them can put those forward again'
            );
        });

        it('sends only the ticked attendees, and nothing until one is ticked', async () => {
            addInvitees.mockResolvedValue({
                added: 1,
                skipped: 0,
                waitingOnMe: 1,
                approversNotified: 0,
                levels: 1
            });
            const el = build();
            pendingAdapter.emit([ACME]);
            emitAddable(ADDABLE);
            await flush();
            await openAddPanel(el);

            expect(buttonByLabel(el, 'Add and submit (0)').disabled).toBe(true);

            await tickAttendee(el, 1);
            buttonByLabel(el, 'Add and submit (1)').click();
            await flush();

            expect(addInvitees).toHaveBeenCalledTimes(1);
            expect(addInvitees.mock.calls[0][0]).toEqual({
                eventId: EVENT_ID,
                attendeeIds: [ADDABLE[1].attendeeId]
            });
        });

        it('unticking removes an attendee from the batch', async () => {
            const el = build();
            pendingAdapter.emit([ACME]);
            emitAddable(ADDABLE);
            await flush();
            await openAddPanel(el);
            await tickAttendee(el, 0);
            expect(buttonLabels(el)).toContain('Add and submit (1)');

            const box = addBoxes(el)[0];
            box.checked = false;
            box.dispatchEvent(new CustomEvent('change'));
            await flush();

            expect(buttonLabels(el)).toContain('Add and submit (0)');
        });

        it('tells the approver which of the added rows landed on them', async () => {
            addInvitees.mockResolvedValue({
                added: 3,
                skipped: 1,
                waitingOnMe: 2,
                approversNotified: 1,
                levels: 3
            });
            const handler = jest.fn();
            const el = build();
            el.addEventListener('lightning__showtoast', handler);
            pendingAdapter.emit([ACME]);
            emitAddable(ADDABLE);
            await flush();
            await openAddPanel(el);
            await tickAttendee(el, 0);

            buttonByLabel(el, 'Add and submit (1)').click();
            await flush();

            const { detail } = handler.mock.calls[0][0];
            expect(detail.variant).toBe('success');
            expect(detail.message).toContain('3 attendee(s) added and submitted');
            expect(detail.message).toContain('2 of them are waiting on you');
            expect(detail.message).toContain('1 other approver(s) were notified');
            expect(detail.message).toContain('longest chain is 3 levels');
            expect(detail.message).toContain('1 were already on this event');
        });

        it('says nothing about levels, other approvers or skipped rows when there are none', async () => {
            addInvitees.mockResolvedValue({
                added: 1,
                skipped: 0,
                waitingOnMe: 0,
                approversNotified: 1,
                levels: 1
            });
            const handler = jest.fn();
            const el = build();
            el.addEventListener('lightning__showtoast', handler);
            pendingAdapter.emit([ACME]);
            emitAddable(ADDABLE);
            await flush();
            await openAddPanel(el);
            await tickAttendee(el, 0);

            buttonByLabel(el, 'Add and submit (1)').click();
            await flush();

            const { detail } = handler.mock.calls[0][0];
            expect(detail.message).toBe(
                '1 attendee(s) added and submitted for approval. 1 other approver(s) were notified.'
            );
        });

        it('clears the picker and refreshes both lists once an add lands', async () => {
            addInvitees.mockResolvedValue({
                added: 1,
                skipped: 0,
                waitingOnMe: 1,
                approversNotified: 0,
                levels: 1
            });
            const el = build();
            pendingAdapter.emit([ACME]);
            emitAddable(ADDABLE);
            await flush();
            await openAddPanel(el);
            await search(el, 'nordbank');
            await tickAttendee(el, 0);

            buttonByLabel(el, 'Add and submit (1)').click();
            await flush();

            expect(refreshApex).toHaveBeenCalledTimes(2);
            expect(buttonLabels(el)).toContain('Add and submit (0)');
            // The search box is cleared too, so the whole pool is back in view.
            expect(addBoxes(el)).toHaveLength(3);
        });

        it('surfaces a refusal as an error toast and keeps the ticks', async () => {
            addInvitees.mockRejectedValue({
                body: { message: 'Everyone you picked is already on this event.' }
            });
            const handler = jest.fn();
            const el = build();
            el.addEventListener('lightning__showtoast', handler);
            pendingAdapter.emit([ACME]);
            emitAddable(ADDABLE);
            await flush();
            await openAddPanel(el);
            await tickAttendee(el, 0);

            buttonByLabel(el, 'Add and submit (1)').click();
            await flush();

            const { detail } = handler.mock.calls[0][0];
            expect(detail.variant).toBe('error');
            expect(detail.title).toBe('Nothing was added');
            expect(detail.message).toContain('already on this event');
            expect(buttonLabels(el)).toContain('Add and submit (1)');
        });

        it('drops a tick for somebody who has since been invited by another approver', async () => {
            const el = build();
            pendingAdapter.emit([ACME]);
            emitAddable(ADDABLE);
            await flush();
            await openAddPanel(el);
            await tickAttendee(el, 0);
            expect(buttonLabels(el)).toContain('Add and submit (1)');

            emitAddable([ADDABLE[1], ADDABLE[2]]);
            await flush();

            expect(buttonLabels(el)).toContain('Add and submit (0)');
        });
    });
});
