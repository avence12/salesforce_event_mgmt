# Salesforce Event Management PoC

Invite-and-approve workflow for marketing events, built on existing **Account** and **Contact** data.
Design doc: [design.md](design.md) · Requirements: [requirement.md](requirement.md)

## What it does

1. **Import** — AM uploads a CSV (.csv) contact list (comma, semicolon or tab separated; must be UTF-8); rows are matched to existing Contacts by email with a diff preview (New / Update / Unchanged / Company change / Skipped) before anything is applied.
2. **Create & select** — AM creates a Marketing Event and adds contacts from their own accounts. Events are shared: every AM adds their own batch (`Added By` is tracked per invitee).
3. **Approve** — Each AM submits their batch; every affected **Account Owner** gets an email + bell notification and bulk-approves/rejects their pending invitees on the event page (desktop or Salesforce Mobile App).
4. **Export** — When an AM's batch is fully reviewed they're notified and can download the approved list as CSV (re-export safe) — either one event from its record page, or **every signed-off invitee across all events in a single file** from the *Approved Exports* tab, optionally limited to a sign-off date range.

## Components

| Layer | Items |
|---|---|
| Objects | `Marketing_Event__c` (+4 roll-up counters), `Event_Invitee__c` (junction, unique per event+contact, status state machine) |
| Apex | `ContactImportController`, `InviteeSelectorController`, `ApprovalConsoleController`, `EventExportController`, `EventNotificationService` + test classes |
| LWC | `importWizard` + `approvedExport` (app pages/tabs), `contactSelector` + `approvalConsole` (event record page), `csvDownload` (shared download helper) |
| Config | Permission sets `Event_AM` / `Event_Approver`, custom notification type, app + tabs + flexipages + layouts |

## Prerequisites

- Salesforce CLI (`npm install -g @salesforce/cli`) on a machine that can reach the Sandbox.
- Sandbox user with permission to deploy metadata.
- Email deliverability set to "All Email" (Setup → Deliverability) if you want to demo the notification emails.
- Optional (for AM-via-team scoping): enable Account Teams and add the AM users to the demo accounts' teams. Otherwise AMs see accounts they own.

## Deploy

```bash
sf org login web --alias poc-sandbox --instance-url https://test.salesforce.com
sf project deploy start -o poc-sandbox
sf apex run test -o poc-sandbox --wait 10 --code-coverage
```

Can't complete a browser login? [DEPLOYMENT.md](DEPLOYMENT.md#step-2-authenticate-to-the-sandbox)
covers device flow, auth URL, JWT and access-token logins.

## Quality checks

```bash
npm install
npm run gauntlet     # tests, coverage, lint, format, Apex static analysis, mutation
```

See [QUALITY.md](QUALITY.md) for what each layer proves, the anti-gaming rules, and the known gaps.

## Post-deploy setup (once, ~5 minutes)

1. **Activate the record page**: Setup → Object Manager → Marketing Event → Lightning Record Pages → *Marketing Event Record Page* → Activate → **Org Default** (desktop + phone).
2. **Assign permission sets**: `Event AM` to the AM demo users, `Event Approver` to the Account Owner demo users.
3. **Seed demo data**: edit the two owner usernames at the top of `scripts/seed-demo-data.apex`, then
   `sf apex run --file scripts/seed-demo-data.apex -o poc-sandbox`
4. Demo import file: `demo-data/FinTech_Summit_2026_Attendees.csv` (regenerate with `node scripts/generate-demo-csv.mjs`).

## Demo script (5 minutes)

1. As **AM**: open the *Event Management* app → *Import Contacts* tab → upload the demo .csv → show the five-way diff preview (incl. the company-change manual list) → Apply.
2. Still as AM: open *Q3 2026 Customer Appreciation Gala* → **Add Contacts** tab → group-by-account selection → Add → **Submit My Contacts for Approval**. (Optionally repeat as a second AM.)
3. As **Account Owner** (desktop or the Salesforce Mobile App): open the event from the bell notification → *Pending Your Approval* → Select All → Approve (reject one for effect).
4. Back as AM: show the completion email/bell, the roll-up counters on the event, then **Export Approved List (CSV)** — open the file.
5. Open the **Approved Exports** tab: every event with signed-off invitees, with counts of what has and hasn't been downloaded yet. **Download All Approved** pulls the lot into one CSV (tick *Only invitees I added* to get just your own batches). Set *Approved from* / *Approved to* to limit the file to a sign-off date range — both ends inclusive, read in your own timezone.

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
- Apex carries 84 baselined PMD findings — 26 of them CRUD/FLS, overlapping the hardening item
  above. The gate is "no new violations"; see [QUALITY.md](QUALITY.md#known-gaps-stated-plainly).
