import { createElement } from 'lwc';
import ApprovalsByCompany from 'c/approvalsByCompany';
import { registerApexTestWireAdapter } from '@salesforce/sfdx-lwc-jest';
import { refreshApex } from '@salesforce/apex';
import getMyPendingByCompany from '@salesforce/apex/InviteeApprovalController.getMyPendingByCompany';
import decide from '@salesforce/apex/InviteeApprovalController.decide';

jest.mock('@salesforce/apex/InviteeApprovalController.decide', () => ({ default: jest.fn() }), {
    virtual: true
});
jest.mock('@salesforce/apex', () => ({ refreshApex: jest.fn() }), { virtual: true });

const pendingAdapter = registerApexTestWireAdapter(getMyPendingByCompany);

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
            addedByName: 'Alex AM'
        },
        {
            inviteeId: 'a02000000000002',
            name: 'Robert Kim',
            title: 'Head of Data',
            salutation: null,
            vip: false,
            remark: null,
            addedByName: 'Alex AM'
        },
        {
            inviteeId: 'a02000000000003',
            name: 'Lena Farrow',
            title: 'Partner',
            salutation: 'Dr',
            vip: true,
            remark: 'Keynote guest, confirmed by marketing',
            addedByName: 'Alex AM'
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
            addedByName: 'Maria AM'
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
});
