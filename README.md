# Salesforce Event Management PoC

Invite-and-approve workflow for marketing events, built on existing **Account** and **Contact** data.
Design doc: [design.md](design.md) · Requirements: [requirement.md](requirement.md)

## What it does

1. **Import** — AM uploads an Excel (.xlsx) contact list; rows are matched to existing Contacts by email with a diff preview (New / Update / Unchanged / Company change / Skipped) before anything is applied.
2. **Create & select** — AM creates a Marketing Event and adds contacts from their own accounts. Events are shared: every AM adds their own batch (`Added By` is tracked per invitee).
3. **Approve** — Each AM submits their batch; every affected **Account Owner** gets an email + bell notification and bulk-approves/rejects their pending invitees on the event page (desktop or Salesforce Mobile App).
4. **Export** — When an AM's batch is fully reviewed they're notified and can download the approved list as CSV (re-export safe).

## Components

| Layer | Items |
|---|---|
| Objects | `Marketing_Event__c` (+4 roll-up counters), `Event_Invitee__c` (junction, unique per event+contact, status state machine) |
| Apex | `ContactImportController`, `InviteeSelectorController`, `ApprovalConsoleController`, `EventExportController`, `EventNotificationService` + test classes |
| LWC | `importWizard` (app page/tab), `contactSelector` + `approvalConsole` (event record page) |
| Static resource | `sheetjs` (SheetJS CE 0.18.5 — client-side .xlsx parsing) |
| Config | Permission sets `Event_AM` / `Event_Approver`, custom notification type, app + tabs + flexipages + layouts |

## Prerequisites

- Salesforce CLI (`npm install -g @salesforce/cli`) on a machine that can reach the Sandbox.
- **Lightning Web Security enabled** (Setup → Session Settings → "Use Lightning Web Security…"). SheetJS breaks under legacy Locker Service — verify this first.
- Sandbox user with permission to deploy metadata.
- Email deliverability set to "All Email" (Setup → Deliverability) if you want to demo the notification emails.
- Optional (for AM-via-team scoping): enable Account Teams and add the AM users to the demo accounts' teams. Otherwise AMs see accounts they own.

## Deploy

```bash
sf org login web --alias poc-sandbox --instance-url https://test.salesforce.com
sf project deploy start -o poc-sandbox
sf apex run test -o poc-sandbox --wait 10 --code-coverage
```

## Post-deploy setup (once, ~5 minutes)

1. **Activate the record page**: Setup → Object Manager → Marketing Event → Lightning Record Pages → *Marketing Event Record Page* → Activate → **Org Default** (desktop + phone).
2. **Assign permission sets**: `Event AM` to the AM demo users, `Event Approver` to the Account Owner demo users.
3. **Seed demo data**: edit the two owner usernames at the top of `scripts/seed-demo-data.apex`, then
   `sf apex run --file scripts/seed-demo-data.apex -o poc-sandbox`
4. Demo import file: `demo-data/FinTech_Summit_2026_Attendees.xlsx` (regenerate with `node scripts/generate-demo-xlsx.mjs`; `npm install` inside `scripts/` first).

## Demo script (5 minutes)

1. As **AM**: open the *Event Management* app → *Import Contacts* tab → upload the demo .xlsx → show the five-way diff preview (incl. the company-change manual list) → Apply.
2. Still as AM: open *Q3 2026 Customer Appreciation Gala* → **Add Contacts** tab → group-by-account selection → Add → **Submit My Contacts for Approval**. (Optionally repeat as a second AM.)
3. As **Account Owner** (desktop or the Salesforce Mobile App): open the event from the bell notification → *Pending Your Approval* → Select All → Approve (reject one for effect).
4. Back as AM: show the completion email/bell, the roll-up counters on the event, then **Export Approved List (CSV)** — open the file.

## Design decisions worth knowing

- **Status lives on the invitee, not the event** — multiple AMs submit independent batches; event-level state would deadlock. The event shows roll-up counts instead.
- `Account__c` / `Account_Owner__c` are **snapshots** set by Apex (add/submit time), deliberately not formulas.
- Re-adding a **rejected** contact resets the existing row to Draft (`Unique_Key__c` forbids duplicates).
- Aggregate notification conditions ("one per distinct owner", "zero pending left per AM") are computed **in Apex**, not record-triggered Flows.
- Status transitions run in system mode; `Status__c` is FLS-read-only for users.

## Known PoC limits

- 500-row import cap; company changes are flagged for manual handling, never auto-reparented.
- `addInvitees` trusts the client-side account scoping (server re-verification is a production hardening item).
- No i18n; UI is English-only by design (US/EU AM audience).
