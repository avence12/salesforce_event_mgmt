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
3. **Approve** — Each BMD user submits their batch into the **standard Approval Process**, routed up a **★R9 multi-level chain**: the **Account Owner** of the customer each guest belongs to, then that owner's manager, then theirs, stopping early at the first **Regional Head**. Every level must agree; a rejection at any level ends the request. Each approver gets one aggregated email + bell notification when the batch reaches *their* level, and decides from **★R8 Approvals by Company** on the event page — their pending invitees grouped by the company each was invited as, so one tick selects a whole company and one button decides it, with per-person veto still available. The standard Approvals list and the Salesforce Mobile App still work as before; what the component adds is the grouping, which the standard list cannot do. Full approval history on every invitee either way.
4. **Report** — When a batch is fully reviewed its submitter is notified, and the approved list is read and exported from the **Approved Invitees** reports (one event or every event, any date range, CSV or XLSX).
5. **Record who came** — after the event, an AM ticks the people who actually turned up. That is a separate fact from being approved, and it is what the **Attendee Event History** report reads: which events each person has actually shown up for, as the basis for suggesting a similar one.

**Two roles.** **BMD** proposes — steps 1–4 above — and the **AM** approves. R5 had left the AM
unreachable: it deleted the fields that carried "whose customer is this", so the only approver
the routing could produce was the submitter's manager. **★R9 builds the chain that answers it**,
and builds it the way `requirement.md` defines rather than the way ★R7 designed it: routing walks
the **org chart** from the Account Owner upward and stops at a Regional Head, so there is no
`Approval_Route__c` table. What that trades away is stated plainly in
[design.md → ★R9 Approval routing](design.md#r9-approval-routing--the-chain-that-was-built):
the business can no longer edit a chain as data — changing who signs means changing the org chart
or a title on it. See also the [flow diagram](docs/business-process.md).

## Components

| Layer | Items |
|---|---|
| Objects | `Marketing_Event__c` (+3 roll-up counters, `Topic__c` for similarity), `Event_Attendee__c` (the imported person; free-text `Company__c`, `Unique_Key__c` for de-duplication), `Event_Invitee__c` (junction: event × attendee, unique per pair, `Attended__c`, and formulas reading both down to the attendee and up to the event) |
| Apex | `AttendeeImportController`, `InviteeSelectorController`, `InviteeApprovalController`, **★R9 `ApprovalChainService`** (the whole routing rule), `EventNotificationService`, `ApprovalLevelNotifier` + test classes |
| LWC | `importWizard` (app page/tab), `attendeeSelector` (event record page), `csvDownload` (shared download helper) |
| Declarative | **Approval Process** `Invitee_Approval` — ★R9 **five steps**, each addressed to its own `Approver_N__c` and skipped when that level is blank — **3 reports** + 2 custom report types, record-triggered Flows `Invitee_Decision_Completion` and ★R9 `Invitee_Level_Advanced`, 3 validation rules |
| Config | Permission sets `Event_AM` / `Event_Approver` (`Event_AM` now describes BMD's job — rename pending), ★R9 `Approval_Chain_Setting__mdt` (regional-head titles, level cap), custom notification type, app + tabs + flexipages + layouts |

Screens 4 (approval) and 5 (export) carry no custom code: they are a standard Approval
Process and standard reports. See [design.md](design.md) for the R3 revision that made
that possible, and what it gave up.

## Prerequisites

- Salesforce CLI (`npm install -g @salesforce/cli`) on a machine that can reach the Sandbox.
- Sandbox user with permission to deploy metadata.
- Email deliverability set to "All Email" (Setup → Deliverability) if you want to demo the notification emails.
- ★R9 **A reporting line, and customers with owners.** Routing starts at the Account Owner of the
  customer a guest belongs to, so three things must be true before anything can be submitted:
  the attendee is linked to a Contact (`Event_Attendee__c.Contact__c`, set by reconciliation),
  that Contact's Account has an owner, and that owner has a `ManagerId` if the chain is to climb.
  A **Regional Head** is recognised by `User.Title` containing a marker from
  `Approval_Chain_Setting__mdt`. Missing any of it does not degrade quietly — the submit is
  refused with a named error. The BMD user's own Manager is no longer part of routing at all.

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
3. **★R9 Set up the approval chain** (Setup → Users, and your Account data). Routing starts at the Account Owner, so: give each demo Account an owner, set `ManagerId` up the reporting line above them, and put the regional-head marker in the `Title` of whoever ends the chain (the marker itself is `Approval_Chain_Setting__mdt` → *Default* → *Regional Head Titles*, shipped as `Regional Head`; the level cap is beside it, shipped as 2). The BMD user's own Manager is no longer used by routing.
   *A guest who belongs to no customer cannot be submitted at all* — see step 9.
4. **Turn off per-request approval emails** for approver users (Setup → Users → *Receive Approval Request Emails* → **Never**). This is **Option 1** from design.md: approvers hear once per submission from the aggregated notification instead of once per invitee. Skipping this step is not harmless — approvers get one email per row.
   *To switch to Option 2 instead:* leave the setting on, add an approval assignment email template to the `Invitee_Approval` process, and enable Setup → Process Automation Settings → **Email Approval Response** so approvers can reply "approve" from a phone. The two halves must move together, or approvers hear nothing at all.
5. **Share the report folder**: Reports → *Event Management* folder → Share with the BMD and approver users (deployed as Public/ReadOnly).
6. **Seed demo data**: `sf apex run --file scripts/seed-demo-data.apex -o poc-sandbox`
   It creates attendees and two events, and no Account, Contact or Lead — safe to run in an org that already has real ones. **★R9 It therefore cannot make anything submittable on its own**: link a few seeded attendees to Contacts under owned Accounts by hand (`Event_Attendee__c.Contact__c`) before demonstrating the approval chain.
7. Demo import file: `demo-data/FinTech_Summit_2026_Attendees.csv` (regenerate with `node scripts/generate-demo-csv.mjs`).
8. **Replace the `Topic__c` placeholder values** (Setup → Object Manager → Marketing Event → Topic) with the real taxonomy, and tag past events. Until this is done every historical event looks equally similar to every new one, and the recommendation the attendance history is *for* cannot work.
9. **★R9 Decide where non-customer guests belong** (Open Question 21). Professors, press and anyone else who is nobody's customer have no Account Owner and therefore no approval chain, so the submit refuses them by design. The business's answer is an Account kept for exactly those guests, whose owner — named when it is created — becomes their level 1; the reconciliation then links those attendees to Contacts under it. **This repo does not and will not create that Account:** no code here writes to Account, Contact or Lead, which is the invariant the tests assert. It is a deliberate admin decision, including what to call it so that no report mistakes it for a real customer.

Every step above is manual on purpose: each one either touches org-wide configuration or
grants access to real users, and those are an admin's decisions rather than a deploy's. Note
what is *not* on the list — no Contact or Lead page-layout change, no Account Teams, no Lead
OWD check. The workflow reads none of those objects, so it asks nothing of them.

## Demo script (5 minutes)

1. As **BMD**: open the *Event Management* app → *Import Attendees* tab → upload the demo .csv → show the preview: new attendees, the ones the seed script already created coming back as *Already known*, and the skipped rows → Import. Point out the result line: no contact, lead or account was created, changed or deleted.
2. Still as BMD: open *Q3 2026 Customer Appreciation Gala* → **Add Attendees** tab → group-by-organisation selection → Add → **Submit My Invitees for Approval**. (Optionally repeat as a second BMD user.)
3. As the **Account Owner** of one of those customers (desktop or the Salesforce Mobile App): open the bell notification, then the event's **Approvals by Company** card. Each row shows *Level 1 of 3*. Tick one company → *Approve 3*. Then untick one person in the next company and approve the rest, to show that per-company bulk and per-person veto are the same mechanism. Show the **Approval History** on a decided invitee.
   3a. **★R9 Nothing is approved yet** — log in as the owner's manager and show the same rows, now reading *Level 2 of 3*, plus the notification they received when level 1 finished. Approve, then repeat as the **Regional Head**: only that last approval flips `Status__c` to Approved and tells the BMD user. Before level 1 signs, log in as the level-2 approver and show the card **empty** — being named in the chain is not the same as it being your turn.
   3b. **★R9 Show a two-level chain beside the three-level one**: a customer whose Account Owner *is* the Regional Head is approved after one signature, on the same event. And try submitting a guest with no Contact behind them — the error names them, and nothing in the batch moves.
4. Back as BMD: show the completion email/bell and the roll-up counters, then open **Reports → Event Management → Approved Invitees — by Event**. Filter to one event or leave it across all events; set a `Decided At` range; **Export** as CSV or XLSX. *My Approved Invitees* is the same list scoped to your own batches.
5. Back as **AM**, on a past event: open the **All Invitees** tab, tick the people who actually turned up, **Save Attendance**. Point out that draft and rejected rows cannot be ticked at all.
6. Open any **Event Attendee** record and show the Event Invitees related list: every event that person has been put forward for, with the date, the type and whether they came. Then **Reports → Attendee Event History** — the same thing grouped by person, filtered to people who actually attended. That is the list a marketer picks a similar event from.

## Design decisions worth knowing

- **The import writes one object and reads no others.** Every imported person becomes an `Event_Attendee__c`. There is no matching against Contacts or Leads, so there is no ambiguity, no `Match_Basis__c`, and no chance of tagging the wrong person — and equally no link back to customer data. That trade is deliberate; see the price table in design.md.
- **An Account means a transacting customer** — and R5 satisfies that by never touching Account at all, rather than by working around it. Nothing in this project creates an Account, a Contact or a Lead.
- **De-duplication is `last|first|company|email`, normalised.** It is the whole of it. Two same-named people at one company with no email collapse into one attendee; one person whose email changed between two files becomes two. Both cases are in the demo file on purpose.
- **★R9 Approval routes up a chain, resolved once at submit time and frozen.** Account Owner → their manager → theirs, capped at two levels above the owner and ending early at the first Regional Head. Freezing matters more with three levels than it did with one: a reorganisation halfway up must not reroute an item somebody is already looking at. The submitter is dropped wherever they appear, so an AM inviting their own customer never approves themselves — and the chain gets *shorter* rather than sliding up to refill the gap.
- **Attended is not the same as Approved.** Approval is permission to come; attendance is having come. Only the second is evidence of interest, so only the second feeds the history report. Nothing sets it automatically — an unmarked event has *no* attendance data rather than false attendance data.
- **Similarity is judged on `Topic__c`, not `Event_Type__c`.** Three type values say what shape an event is; recommending from them would just mean "another conference for conference-goers".
- **Status lives on the invitee, not the event** — several BMD users submit independent batches against one shared event; event-level state would deadlock. The event shows roll-up counts instead.
- Re-adding a **rejected** invitee resets the existing row to Draft (`Unique_Key__c` forbids duplicates).
- Aggregate notification conditions ("zero pending left per submitter") are computed **in Apex**; the record-triggered Flow is only the trigger.
- Status transitions are Approval Process field updates, which run in system context; `Status__c` stays FLS-read-only for users.

## Known PoC limits

- 500-row import cap.
- **★R9 The chain is only as good as the org chart.** It walks `User.ManagerId` and stops at a `User.Title` marker, both of which are the org's own data. A vacant post, a stale reporting line or a blank title does not error — it makes a chain that stalls or that quietly runs one level longer than intended. `Approval_Route__c` (★R7) was the design that would have insulated the business from that, and it was deliberately not built; see [design.md → ★R9](design.md#r9-approval-routing--the-chain-that-was-built).
- **★R9 A guest with no customer cannot be submitted.** Routing needs an Account Owner. Post-deploy step 9 is the remedy and it is a data one; until it is done, non-customer guests can be added to an event and go no further.
- **★R9 Two pieces of approval-process behaviour are unverified against a real org**: that a step whose approver field is blank is *skipped* rather than final-approving early, and that a step's approval action firing a field update in turn fires the record-triggered Flow that notifies the next level. Both are argued in design.md and neither can be proven from this repo. The second fails quietly — the upper levels simply never hear — so test it by watching for the level-2 email, not by reading the record.
- **★R8 An attendee can be linked to a Contact, but nothing links them automatically.** `Event_Attendee__c.Contact__c` records that an imported person is also a Contact, and `Is_Known_Contact__c` makes "which of tonight's guests are already known to us?" reportable. The import still matches nobody against anything — the link is written by a separate reconciliation run, so until that runs the answer is "not established" rather than "no".
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
