# Salesforce Event Management PoC

Invite-and-approve workflow for marketing events, built on existing **Account** and **Contact** data —
plus **Leads** for guests with no customer relationship, because an Account means a transacting customer.
Design doc: [design.md](design.md) · Requirements: [requirement.md](requirement.md) ·
End-to-end flow diagram: [docs/business-process.md](docs/business-process.md)

## What it does

1. **Import** — **BMD** uploads a CSV (.csv) attendee list carrying an **Event** column (comma, semicolon or tab separated; must be UTF-8). Each row is matched to someone already in the org by **name, then company, then email**, with a preview (Matched / Matched lead / New lead / Ambiguous / Skipped) before anything is applied. Matched people get an **event history** row. **No Contact is created, changed or deleted, and no Account is created** — the only records the import writes are event history and Leads for people who match nobody.
2. **Create & propose** — BMD creates a Marketing Event and puts forward its guests: **Contacts** from the accounts they belong to, and **Leads** BMD owns (professors, speakers, press — guests with no customer relationship). Events are shared: every BMD user adds their own batch (`Added By` is tracked per invitee).
3. **Approve** — Each BMD user submits their batch into the **standard Approval Process**, which routes each customer Contact to **the AM who owns its account** and each Lead to the submitter's manager. Approvers get one aggregated email + bell notification and approve/reject from the standard Approvals list (desktop or Salesforce Mobile App), with a full approval history on every invitee.
4. **Report** — When a batch is fully reviewed its submitter is notified, and the approved list is read and exported from the **Approved Invitees** reports (one event or every event, any date range, CSV or XLSX).

**Two roles.** **BMD** proposes — steps 1, 2, 3 and 4 above. The **AM** approves, signing off the guests from accounts they own. The split is documented in [docs/business-process.md](docs/business-process.md) and **is not yet deployable**: the contact selector still scopes to accounts the *running user* owns, which a BMD user does not have. See [what it still needs](docs/business-process.md#what-the-bmd-split-still-needs).

## Components

| Layer | Items |
|---|---|
| Objects | `Marketing_Event__c` (+3 roll-up counters), `Event_Invitee__c` (junction onto **either** a Contact or a Lead, unique per event+invitee, 5 `Invitee_*__c` formula fields that read correctly for both), `Event_History__c` (attendance log, same two-headed shape) |
| Apex | `ContactImportController`, `InviteeSelectorController`, `EventNotificationService` + test classes |
| LWC | `importWizard` (app page/tab), `contactSelector` (event record page), `csvDownload` (shared download helper) |
| Declarative | **Approval Process** `Invitee_Approval` (routed by `Approver__c`), **2 reports** + custom report type, record-triggered Flow `Invitee_Decision_Completion`, 2 validation rules |
| Config | Permission sets `Event_AM` / `Event_Approver` (`Event_AM` now describes BMD's job — rename pending), custom notification type, app + tabs + flexipages + layouts |

Screens 4 (approval) and 5 (export) carry no custom code: they are a standard Approval
Process and standard reports. See [design.md](design.md) for the R3 revision that made
that possible, and what it gave up.

## Prerequisites

- Salesforce CLI (`npm install -g @salesforce/cli`) on a machine that can reach the Sandbox.
- Sandbox user with permission to deploy metadata.
- Email deliverability set to "All Email" (Setup → Deliverability) if you want to demo the notification emails.
- **Account Teams enabled, with the proposing users added to the demo accounts' teams.** The contact selector scopes to accounts the running user owns *or is on the team of*, and a BMD user owns none — so without this the *Add Contacts* tab is empty. Optional only while one person plays both roles.
- A **Manager** set on each proposing user — the last rung of the approver ladder. Under the BMD model every imported Lead reaches that rung, so without it no Lead invitee can be submitted at all (refused by design, loudly).

## Deploy

```bash
sf org login web --alias poc-sandbox --instance-url https://test.salesforce.com
sf project deploy start -o poc-sandbox
sf apex run test -o poc-sandbox --wait 10 --code-coverage
```

**Upgrading an org that already has the pre-R3 build?** Use the
[R3 upgrade checklist](DEPLOYMENT.md#part-6--r3-upgrade-checklist) instead — R3 deletes
components and removes a restricted picklist value, so it needs the destructive manifests
in `manifest/` and a data migration on either side of the deploy.

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
2. **Assign permission sets**: `Event AM` to the **BMD** demo users, `Event Approver` to the AM demo users who will approve. `Event AM` is named for the old model — its contents are exactly BMD's job (import tab, selector, event create, reports); the rename to `Event_BMD` is pending ([why](docs/business-process.md#what-the-bmd-split-still-needs)).
3. **Set a Manager on each BMD user** (Setup → Users). This is the last rung of the approver ladder, and under the BMD model every imported Lead lands on it; without a Manager, no Lead invitee can be submitted.
4. **Turn off per-request approval emails** for approver users (Setup → Users → *Receive Approval Request Emails* → **Never**). This is **Option 1** from design.md: approvers hear once per submission from the aggregated notification instead of once per invitee. Skipping this step is not harmless — approvers get one email per row.
   *To switch to Option 2 instead:* leave the setting on, add an approval assignment email template to the `Invitee_Approval` process, and enable Setup → Process Automation Settings → **Email Approval Response** so approvers can reply "approve" from a phone. The two halves must move together, or approvers hear nothing at all.
5. **Check the Lead OWD** (Setup → Sharing Settings). Under a Private Lead OWD an approver may not see the Lead behind an invitee they are approving, and the name/organisation columns render blank. PoC assumes Public Read Only.
6. **Share the report folder**: Reports → *Event Management* folder → Share with the BMD and AM users (deployed as Public/ReadOnly).
7. **Add the Event History related list** to the Contact and Lead page layouts (Setup → Object Manager → Contact / Lead → Page Layouts). Not shipped as metadata on purpose — a layout deploy would overwrite the org's own. Until this is done the attendance data exists and is reportable but does not appear on the record.
8. **Seed demo data**: edit the two owner usernames at the top of `scripts/seed-demo-data.apex`, then
   `sf apex run --file scripts/seed-demo-data.apex -o poc-sandbox`
9. Demo import file: `demo-data/FinTech_Summit_2026_Attendees.csv` (regenerate with `node scripts/generate-demo-csv.mjs`).

## Demo script (5 minutes)

1. As **BMD**: open the *Event Management* app → *Import Contacts* tab → upload the demo .csv → show the preview: matched contacts, matched leads, new leads, and the two **Marie Duponts** the import refuses to guess between → Apply. Point out the result line: no contact was created, changed or deleted.
2. Still as BMD: open *Q3 2026 Customer Appreciation Gala* → **Add Contacts** tab → group-by-account selection → Add → **Submit My Invitees for Approval**. Point out that each account's guests route to *that account's AM*. (Optionally repeat as a second BMD user.)
3. Still as BMD: switch to the **Add Leads** tab, add two professors, submit. Point out that they route to *your manager*, not to you — you imported those Leads, so you own them, and the ladder refuses to let you approve your own proposal.
4. As the **AM / Account Owner** (desktop or the Salesforce Mobile App): open the bell notification, then **Approvals** → select the pending items → Approve (reject one for effect). Show the **Approval History** on a decided invitee.
5. Back as BMD: show the completion email/bell and the roll-up counters, then open **Reports → Event Management → Approved Invitees — by Event**. Filter to one event or leave it across all events; set a `Decided At` range; **Export** as CSV or XLSX. *My Approved Invitees* is the same list scoped to your own batches.

## Design decisions worth knowing

- **The import never writes to Contact.** It matches, and records attendance as an `Event_History__c` child row. Matching is a name → company → email cascade where an empty narrowing step is *skipped* (a stale company should not erase someone who changed jobs), and where "could not tell" writes nothing rather than guessing. `Match_Basis__c` records how each tag was reached, because a name-first match can be wrong.
- **An Account means a transacting customer.** Guests without one are **Leads**, never Contacts with a blank Account — such a "private contact" is invisible to everyone but its owner, which a shared event cannot use. Nothing in this project creates an Account.
- **Approval routes through `Approver__c`**, resolved once at submit time: Account Owner → Lead Owner (unless the submitter owns that lead) → the submitter's manager. Under the BMD model rung 1 carries the customer Contacts to their AM, and rung 2 never fires — BMD owns what it imported — so Leads fall to BMD's manager. The exclusion matters: without it BMD would approve the guests it just proposed.
- **Status lives on the invitee, not the event** — several BMD users submit independent batches against one shared event; event-level state would deadlock. The event shows roll-up counts instead.
- Re-adding a **rejected** invitee resets the existing row to Draft (`Unique_Key__c` forbids duplicates).
- Aggregate notification conditions ("one per distinct approver", "zero pending left per submitter") are computed **in Apex**; the record-triggered Flow is only the trigger.
- Status transitions are Approval Process field updates, which run in system context; `Status__c` stays FLS-read-only for users.

## Known PoC limits

- **The BMD/AM role split is documented but not built.** BMD proposes and the AM approves, but
  the contact selector still assumes the proposer is an Account Owner: `getSelectableContacts`
  narrows to accounts the running user owns or is on the team of, and a BMD user owns none — so
  the *Add Contacts* tab comes back empty. Account Team membership is a config-only workaround
  that does not scale; the real fix is a second scope for proposers, which pairs with the
  `addInvitees` server-side re-verification item below. The Lead half already works, because BMD
  owns what BMD imports. Detail in
  [docs/business-process.md](docs/business-process.md#what-the-bmd-split-still-needs).
- 500-row import cap. Ambiguous matches are listed for manual handling, never guessed at.
- **A name-first match can tag the wrong person** when a single Contact matches a name that belongs to someone else. Accepted because a tag is append-only history that changes no Contact field and drives no action — see Open Question 12 in design.md, including the condition under which that acceptance expires.
- **Event history is invisible on the record until an admin adds the related list** to the Contact and Lead layouts. This project does not ship those layouts: overwriting the org's own Contact layout would damage something outside its scope.
- **No download tracking.** The `Exported` status and `Exported_Count__c` retired with the custom exporter — a report cannot write back to the rows it exported.
- **The approved-invitee export is not sanitised against CSV formula injection.** That guard went with `EventExportController`; the standard report exporter does not do it. `c/csvDownload` still guards the import wizard's manual-review download.
- Lead scoping in the selector is *ownership only* — Lead has no team object.
- `addInvitees` trusts the client-side account scoping (server re-verification is a production hardening item).
- The contact selector returns at most 2,000 contacts per event. It now says so when it truncates,
  but there is no paging — filter or search to reach the rest.
- No i18n; UI is English-only by design (US/EU user audience).
- Apex carries 84 baselined PMD findings — 26 of them CRUD/FLS, overlapping the hardening item
  above. The gate is "no new violations"; see [QUALITY.md](QUALITY.md#known-gaps-stated-plainly).
