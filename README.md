# Salesforce Event Management PoC

Invite-and-approve workflow for marketing events, built on **Event Attendees** — a person
object this project owns. As of R5 the workflow does not read or write a single standard
object: no Account, no Contact, no Lead.
Design doc: [design.md](design.md) · Requirements: [requirement.md](requirement.md) ·
End-to-end flow diagram: [docs/business-process.md](docs/business-process.md)

## What it does

0. **Tag the event** — a Marketing Event carries a **Topic** (multi-select) as well as a type (Symposium / OIP / Conference). Topic is what "similar event" is judged on; type only says what shape it is.
1. **Import** — **BMD** uploads a CSV (.csv) attendee list (comma, semicolon or tab separated; must be UTF-8). Every row becomes an **Event Attendee**, previewed as New / Already known / Skipped before anything is written. People are recognised across uploads by name + company + email, so re-uploading a file refreshes them rather than duplicating them. **No Contact, Lead or Account is created, read, changed or deleted.**
2. **Create & propose** — BMD creates a Marketing Event and puts forward its guests from the imported pool. Events are shared: every BMD user adds their own batch (`Added By` is tracked per invitee).
3. **Approve** — Each BMD user submits their batch into the **standard Approval Process**, routed to their **manager**; each approver gets one aggregated email + bell notification and approves/rejects from the standard Approvals list (desktop or Salesforce Mobile App), with a full approval history on every invitee.
4. **Report** — When a batch is fully reviewed its submitter is notified, and the approved list is read and exported from the **Approved Invitees** reports (one event or every event, any date range, CSV or XLSX).
5. **Record who came** — after the event, an AM ticks the people who actually turned up. That is a separate fact from being approved, and it is what the **Attendee Event History** report reads: which events each person has actually shown up for, as the basis for suggesting a similar one.

**Two roles.** **BMD** proposes — steps 1–4 above — and the **AM** approves. R5 had left the AM
unreachable: it deleted the `Account__c` / `Account_Owner__c` fields that carried "whose customer
is this", so the only approver the routing could produce was the submitter's manager. **★R7
answers that** with a customer code (`cust_cd`) on the invitee and an `Approval_Route__c` table
mapping it to the owning AM and onward to the regional head — a chain, where every level must
agree and further levels cost rows rather than a deploy. **R7 is designed, not built**: see
[design.md → ★R7 Approval routing](design.md#r7-approval-routing--a-chain-not-a-rung) and the
[flow diagram](docs/business-process.md).

## Components

| Layer | Items |
|---|---|
| Objects | `Marketing_Event__c` (+3 roll-up counters, `Topic__c` for similarity), `Event_Attendee__c` (the imported person; free-text `Company__c`, `Unique_Key__c` for de-duplication), `Event_Invitee__c` (junction: event × attendee, unique per pair, `Attended__c`, and formulas reading both down to the attendee and up to the event) |
| Apex | `AttendeeImportController`, `InviteeSelectorController`, `EventNotificationService` + test classes |
| LWC | `importWizard` (app page/tab), `attendeeSelector` (event record page), `csvDownload` (shared download helper) |
| Declarative | **Approval Process** `Invitee_Approval` (routed by `Approver__c`), **3 reports** + 2 custom report types, record-triggered Flow `Invitee_Decision_Completion`, 3 validation rules |
| Config | Permission sets `Event_AM` / `Event_Approver` (`Event_AM` now describes BMD's job — rename pending), custom notification type, app + tabs + flexipages + layouts |

Screens 4 (approval) and 5 (export) carry no custom code: they are a standard Approval
Process and standard reports. See [design.md](design.md) for the R3 revision that made
that possible, and what it gave up.

## Prerequisites

- Salesforce CLI (`npm install -g @salesforce/cli`) on a machine that can reach the Sandbox.
- Sandbox user with permission to deploy metadata.
- Email deliverability set to "All Email" (Setup → Deliverability) if you want to demo the notification emails.
- A **Manager** set on each BMD user. As of R5 this is the *only* approver the routing has — without it, submitting is refused (by design, loudly). It is also the only place the approving AM can currently be named.

## Deploy

```bash
sf org login web --alias poc-sandbox --instance-url https://test.salesforce.com
sf project deploy start -o poc-sandbox
sf apex run test -o poc-sandbox --wait 10 --code-coverage
```

**The deploy is purely additive.** The target org holds real Account and Contact data; this
project adds three custom objects beside it and modifies no standard object, no layout and no
sharing setting. Nothing is deleted, so there are no destructive manifests and no data
migration — see [Part 1](DEPLOYMENT.md#part-1--deploy-to-sandbox) for exactly what lands and
what does not. A failed deploy rolls back whole.

Can't complete a browser login? [DEPLOYMENT.md](DEPLOYMENT.md#step-2-authenticate-to-the-sandbox)
covers device flow, auth URL, JWT and access-token logins.

## Quality checks

```bash
npm install
npm run gauntlet     # tests, coverage, lint, format, Apex static analysis, mutation
```

See [QUALITY.md](QUALITY.md) for what each layer proves, the anti-gaming rules, and the known gaps.

## Post-deploy setup (once, ~10 minutes)

1. **Activate the record page**: Setup → Object Manager → Marketing Event → Lightning Record Pages → *Marketing Event Record Page* → Activate → **Org Default** (desktop + phone).
2. **Assign permission sets**: `Event AM` to the **BMD** demo users, `Event Approver` to the approving demo users. `Event_AM` is named for the model that predates BMD — its contents are exactly BMD's job (import tab, selector, event create, reports); the rename is pending.
3. **Set a Manager on each BMD user** (Setup → Users). This is the whole of the approver routing; without it that user cannot submit anything.
4. **Turn off per-request approval emails** for approver users (Setup → Users → *Receive Approval Request Emails* → **Never**). This is **Option 1** from design.md: approvers hear once per submission from the aggregated notification instead of once per invitee. Skipping this step is not harmless — approvers get one email per row.
   *To switch to Option 2 instead:* leave the setting on, add an approval assignment email template to the `Invitee_Approval` process, and enable Setup → Process Automation Settings → **Email Approval Response** so approvers can reply "approve" from a phone. The two halves must move together, or approvers hear nothing at all.
5. **Share the report folder**: Reports → *Event Management* folder → Share with the BMD and approver users (deployed as Public/ReadOnly).
6. **Seed demo data**: `sf apex run --file scripts/seed-demo-data.apex -o poc-sandbox`
   It creates attendees and two events, and no Account, Contact or Lead — safe to run in an org that already has real ones.
7. Demo import file: `demo-data/FinTech_Summit_2026_Attendees.csv` (regenerate with `node scripts/generate-demo-csv.mjs`).
8. **Replace the `Topic__c` placeholder values** (Setup → Object Manager → Marketing Event → Topic) with the real taxonomy, and tag past events. Until this is done every historical event looks equally similar to every new one, and the recommendation the attendance history is *for* cannot work.

Every step above is manual on purpose: each one either touches org-wide configuration or
grants access to real users, and those are an admin's decisions rather than a deploy's. Note
what is *not* on the list — no Contact or Lead page-layout change, no Account Teams, no Lead
OWD check. The workflow reads none of those objects, so it asks nothing of them.

## Demo script (5 minutes)

1. As **BMD**: open the *Event Management* app → *Import Attendees* tab → upload the demo .csv → show the preview: new attendees, the ones the seed script already created coming back as *Already known*, and the skipped rows → Import. Point out the result line: no contact, lead or account was created, changed or deleted.
2. Still as BMD: open *Q3 2026 Customer Appreciation Gala* → **Add Attendees** tab → group-by-organisation selection → Add → **Submit My Invitees for Approval**. (Optionally repeat as a second BMD user.)
3. As the **approving manager** (desktop or the Salesforce Mobile App): open the bell notification, then **Approvals** → select the pending items → Approve (reject one for effect). Show the **Approval History** on a decided invitee, and that the Name and Organisation columns are populated — they read through to the attendee.
4. Back as BMD: show the completion email/bell and the roll-up counters, then open **Reports → Event Management → Approved Invitees — by Event**. Filter to one event or leave it across all events; set a `Decided At` range; **Export** as CSV or XLSX. *My Approved Invitees* is the same list scoped to your own batches.
5. Back as **AM**, on a past event: open the **All Invitees** tab, tick the people who actually turned up, **Save Attendance**. Point out that draft and rejected rows cannot be ticked at all.
6. Open any **Event Attendee** record and show the Event Invitees related list: every event that person has been put forward for, with the date, the type and whether they came. Then **Reports → Attendee Event History** — the same thing grouped by person, filtered to people who actually attended. That is the list a marketer picks a similar event from.

## Design decisions worth knowing

- **The import writes one object and reads no others.** Every imported person becomes an `Event_Attendee__c`. There is no matching against Contacts or Leads, so there is no ambiguity, no `Match_Basis__c`, and no chance of tagging the wrong person — and equally no link back to customer data. That trade is deliberate; see the price table in design.md.
- **An Account means a transacting customer** — and R5 satisfies that by never touching Account at all, rather than by working around it. Nothing in this project creates an Account, a Contact or a Lead.
- **De-duplication is `last|first|company|email`, normalised.** It is the whole of it. Two same-named people at one company with no email collapse into one attendee; one person whose email changed between two files becomes two. Both cases are in the demo file on purpose.
- **Approval routes to the submitter's manager**, resolved once at submit time and frozen. The Account Owner and Lead Owner rungs retired with the Account and the Lead — which is why the BMD/AM split has nothing to route on.
- **Attended is not the same as Approved.** Approval is permission to come; attendance is having come. Only the second is evidence of interest, so only the second feeds the history report. Nothing sets it automatically — an unmarked event has *no* attendance data rather than false attendance data.
- **Similarity is judged on `Topic__c`, not `Event_Type__c`.** Three type values say what shape an event is; recommending from them would just mean "another conference for conference-goers".
- **Status lives on the invitee, not the event** — several BMD users submit independent batches against one shared event; event-level state would deadlock. The event shows roll-up counts instead.
- Re-adding a **rejected** invitee resets the existing row to Draft (`Unique_Key__c` forbids duplicates).
- Aggregate notification conditions ("zero pending left per submitter") are computed **in Apex**; the record-triggered Flow is only the trigger.
- Status transitions are Approval Process field updates, which run in system context; `Status__c` stays FLS-read-only for users.

## Known PoC limits

- 500-row import cap.
- **Multi-level approval is designed but not built (★R7).** The deployed org stamps one approver, the submitter's manager. The AM → regional head chain, its `Approval_Route__c` table and its costs — chiefly that levels 2+ get no notification until a step-entry action is added — are in [design.md → ★R7](design.md#r7-approval-routing--a-chain-not-a-rung). Naming an AM as the BMD user's Manager is the interim demo path.
- **★R8 An attendee can be linked to a Contact, but nothing links them automatically.** `Event_Attendee__c.Contact__c` records that an imported person is also a Contact, and `Is_Known_Contact__c` makes "which of tonight's guests are already known to us?" reportable. The import still matches nobody against anything — the link is written by a separate reconciliation run, so until that runs the answer is "not established" rather than "no".
- **The manager is the only approver, until R7 is built.** The row now knows whose customer an invitee is — `Account_Manager__c`, snapshotted through the Contact link — but nothing routes to it yet. Until R7 ships, the Account Owner still does not see invitees to their own customers. **Open Question 15.**
- **Organisation is free text for anyone with no Contact behind them.** An invitee linked to an Account takes that Account's name; everyone else keeps the text the CSV gave, so "Acme Corp" and "ACME Corp." still group and report separately for exactly those rows.
- **Every proposer sees every attendee.** Per-user scoping went with the Account it was based on. Tightening `Event_Attendee__c`'s OWD is the production lever, but it needs another basis for scoping first.
- **A junk Email cell costs the address, not the person.** `Email__c` is a typed field; a value that is not an address is dropped, and the preview says so on that row.
- **No Lead Convert path.** An attendee who becomes a real customer is promoted by hand.
- **No recommendation logic.** R6 records attendance and tags events; a human reads the history report and decides. Building a score before any real event is tagged would fit it to placeholder data.
- **`Topic__c` ships with placeholder values.** Replace them and back-fill past events, or the history is there but nothing can be judged similar to anything. This is the one thing standing between the plumbing and the requirement being met.
- **You cannot filter *people* by attendance count.** `Event_Invitee__c` is a Lookup child, so no roll-up is possible; the report answers it by group but cannot hand you "everyone who attended 3+ events" as an actionable list. Open Question 18.
- **Attendance is only as good as the marking-up.** Nobody ticks the boxes, no history exists.
- **No download tracking.** The `Exported` status and `Exported_Count__c` retired with the custom exporter — a report cannot write back to the rows it exported.
- **The approved-invitee export is not sanitised against CSV formula injection.** That guard went with `EventExportController`; the standard report exporter does not do it. `c/csvDownload` still guards the import wizard's skipped-row download.
- `addAttendees` re-checks that the ids it is given exist, but the selectable list itself is bounded only by sharing.
- The attendee selector returns at most 2,000 attendees per event. It now says so when it truncates, but there is no paging — filter or search to reach the rest.
- No i18n; UI is English-only by design (US/EU user audience).
- Apex carries baselined PMD findings, several of them CRUD/FLS. The gate is "no new violations"; see [QUALITY.md](QUALITY.md#known-gaps-stated-plainly).
