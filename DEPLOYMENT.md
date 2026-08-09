# Deployment Guide

How to deploy this PoC to a **Sandbox**, and the recommended paths to **Production** under a strict network-isolation policy (developer machines cannot reach Salesforce orgs directly).

> Key fact: a Salesforce deployment happens between *the machine running the `sf` CLI* and the Salesforce API — or, with Change Sets / DevOps Center, entirely **cloud-to-cloud inside Salesforce**. Your laptop never needs to reach Production.

**Contents**

| Part | |
|---|---|
| [1 — Deploy to Sandbox](#part-1--deploy-to-sandbox) | The procedure, start to finish |
| [2 — Paths to Production](#part-2--paths-to-production-network-isolated-environments) | Three options under network isolation |
| [3 — How a deploy actually works](#part-3--how-a-deploy-actually-works) | Mechanics: stages, async jobs, rollback, tests |
| [4 — Deleting metadata](#part-4--deleting-metadata-a-deploy-is-an-upsert) | Why `git rm` does not remove anything |
| [5 — Troubleshooting](#part-5--troubleshooting) | Symptom → actual cause → fix |

---

## Part 1 — Deploy to Sandbox

Run these steps on a machine that **can** reach the Sandbox (corporate workstation, VDI, or an approved jump host).

### Step 0: Get the code into the corporate environment

Pick whichever your isolation policy allows:

- **A. Corporate machine can reach GitHub:**
  ```bash
  git clone git@github.com:avence12/salesforce_event_mgmt.git
  ```
- **B. It cannot** — create a git bundle on the outside machine and transfer it through an approved file-transfer channel:
  ```bash
  git bundle create salesforce_event_mgmt.bundle --all   # run in the repo
  ```
  Then on the corporate machine:
  ```bash
  git clone salesforce_event_mgmt.bundle salesforce_event_mgmt
  ```
  A bundle preserves full git history and supports incremental updates later (`git fetch <bundle>`), unlike a zip.

### Step 1: Install the Salesforce CLI

```bash
npm install -g @salesforce/cli
```

If npm is blocked, use the offline installers from developer.salesforce.com/tools/salesforcecli.

### Step 2: Authenticate to the Sandbox

`sf org login web` needs a local browser that can complete an OAuth redirect back to a `localhost` port the CLI opens. That fails on a headless box, a jump host with no GUI, or a workstation where corporate proxy/firewall rules block the loopback callback. If that's your situation, use one of the alternatives below instead — pick the first one that fits.

#### Option A: Device flow — no local browser, no callback port

Prints a short code; you approve it from *any* browser on *any* machine (your phone, another PC) — nothing needs to reach back to the CLI machine.

```bash
sf org login device --alias poc-sandbox --instance-url https://test.salesforce.com
```

The CLI prints a URL and a one-time code. Open the URL anywhere, enter the code, log in, approve. The CLI polls in the background and picks up the session automatically. This is the right default for a browser-less jump host or CI worker that still has *someone* around to click "approve" once.

#### Option B: Auth URL — authenticate once elsewhere, carry the session over

Log in normally on a machine that *can* do the web flow (your laptop), export the resulting session as a single opaque URL, then import it on the restricted machine. No credentials or secrets appear in the file itself beyond the URL string, but treat it as a bearer credential — transfer it over an approved channel and delete it after import.

```bash
# On a machine that CAN complete the web flow:
sf org login web --alias poc-sandbox --instance-url https://test.salesforce.com
sf org display --target-org poc-sandbox --verbose --json \
  | grep sfdxAuthUrl > poc-sandbox.authurl   # contains force://...

# Transfer poc-sandbox.authurl to the restricted machine, then:
sf org login sfdx-url --sfdx-url-file poc-sandbox.authurl --alias poc-sandbox
rm poc-sandbox.authurl   # it's a live credential — don't leave it on disk
```

Good for a one-off "get this specific sandbox usable on this specific locked-down box" without setting up a connected app.

#### Option C: JWT Bearer Flow — fully non-interactive, best for repeat/unattended use

No browser anywhere, ever, once set up. Needs a one-time connected app + certificate setup in the org (an admin can do this from any machine with browser access — it does not have to be the restricted one), then every future login on the restricted machine is fully scripted:

```bash
# One-time setup (see connected app + cert instructions in Part 2, Option 3):
sf org login jwt \
  --client-id <connected-app-consumer-key> \
  --jwt-key-file server.key \
  --username you@example.com.poc-sandbox \
  --instance-url https://test.salesforce.com \
  --alias poc-sandbox
```

This is the same mechanism recommended for CI runners in [Part 2, Option 3](#option-3-in-network-cicd--most-mature-needs-it-support) — worth setting up once if you'll be re-authenticating to this sandbox repeatedly, since after that there's no browser, device code, or file transfer involved at all.

#### Option D: Session ID / access token — quick one-off, short-lived

If you (or an admin) already have a valid session ID from a logged-in browser tab (Setup → search "Sessions", or grab it from the browser's dev tools while logged in), you can hand it to the CLI directly. It expires with the session, so it's only useful for a quick, immediate task, not for scripting:

```bash
sf org login access-token --instance-url https://test.salesforce.com --alias poc-sandbox
# prompts for the access token interactively
```

| Option | Needs a browser at all? | Setup effort | Good for |
|---|---|---|---|
| A. Device flow | Yes, but on any other device | None | One-off login on a headless/jump-host machine |
| B. Auth URL | Yes, once, elsewhere | None | Moving one existing session to a locked-down box |
| C. JWT Bearer | No, never | Connected app + cert (one-time, by an admin) | Repeated logins, CI, unattended jobs |
| D. Access token | Yes, to obtain the token | None | Quick, short-lived, one-off use |

### Step 3: One-time org prechecks (Setup UI)

1. Email deliverability set to "All Email" (Setup → Deliverability) — only needed to demo the notification emails.

### Step 4: Validate, then deploy

Validate first (compiles Apex and checks metadata without changing the org):

```bash
sf project deploy start -o poc-sandbox --dry-run
```

Fix any errors it reports, then deploy and run tests:

```bash
sf project deploy start -o poc-sandbox
sf apex run test -o poc-sandbox --wait 10 --code-coverage
```

### Step 5: Post-deploy setup (~5 minutes)

1. **Activate the record page**: Setup → Object Manager → Marketing Event → Lightning Record Pages → *Marketing Event Record Page* → Activate → **Org Default** (Desktop and Phone).
2. **Assign permission sets**: `Event AM` to the AM demo users, `Event Approver` to the Account Owner demo users.
3. **Seed demo data** — edit the two owner usernames at the top of the script, then:
   ```bash
   sf apex run --file scripts/seed-demo-data.apex -o poc-sandbox
   ```
4. Demo import file: `demo-data/FinTech_Summit_2026_Attendees.csv`. Follow the 5-minute demo script in [README.md](README.md).

---

## Part 2 — Paths to Production (network-isolated environments)

Three options, ordered by isolation-friendliness:

### Option 1: Change Sets — zero local connectivity (recommended first)

Deployment traffic is entirely **Salesforce cloud-to-cloud** (Sandbox → Production); no machine outside Salesforce participates.

1. Deploy the PoC to a sandbox **created from Production** (they share a deployment connection).
2. In the sandbox: Setup → Outbound Change Sets → add all components → Upload to Production.
3. In Production: Setup → Inbound Change Sets → **Validate** (runs tests) → review → **Deploy**.

*Pros*: admins need only a browser; auditable in the Setup UI; no API allow-listing.
*Cons*: manual clicking; tedious for large component lists; a few metadata types unsupported (everything in this PoC — objects, Apex, LWC, flexipages, permission sets — is supported).

Best choice for the first production deployment of this PoC.

### Option 2: Salesforce DevOps Center — official, free, runs on Salesforce

DevOps Center is a Salesforce-hosted application: the pipeline (dev sandbox → UAT → Production) executes **inside the Salesforce cloud** — no CI runner needed. It integrates with corporate Git (e.g., GitHub Enterprise). The right medium-term path if this feature keeps evolving after the PoC.

### Option 3: In-network CI/CD — most mature, needs IT support

Code lives in the internal Git; a CI runner (Jenkins / GitLab CI) in a network segment allow-listed for the Production API runs:

```bash
sf project deploy start -o prod --test-level RunLocalTests
```

Authenticate the runner with the **JWT Bearer Flow** (connected app + certificate — non-interactive, suited to unattended jobs). Developers only push code and open PRs; nobody's laptop ever touches Production. Commercial equivalents: Gearset, Copado. The long-term answer once multiple Salesforce projects share the pipeline.

### Pre-production checklist (whichever path you choose)

- **75% Apex test coverage** is a hard Salesforce requirement for production deploys — the two test classes in this repo exist for that; confirm the `--code-coverage` numbers in sandbox first.
- Close the known PoC hardening gaps (see "Known PoC limits" in [README.md](README.md)): server-side account-scope verification in `addInvitees`, bulk-volume testing, a full FLS review.
- Use **Validate + Quick Deploy**: validate against Production ahead of time (runs tests, changes nothing), then one-click quick-deploy inside the release window — cuts deployment risk to minutes. See [Part 3](#validate-deploy-quick-deploy) for the mechanics.

**Recommendation**: Change Sets for the demo/short term → DevOps Center if the PoC is productized → in-network CI/CD at scale.

---

## Part 3 — How a deploy actually works

Worth reading once, because three of the most common deployment surprises follow directly from it: why a CLI timeout does not mean the deploy failed, why a half-applied deploy never happens, and why deleting a file from the repo leaves the component sitting in the org.

A deploy is **not** a file copy. It is one API call that hands a bundle of metadata to the org; the *org* then compiles it, validates it, runs the tests, and decides to accept or reject the whole thing. Your machine only starts the job.

```mermaid
flowchart LR
  subgraph LOCAL["Your machine / CI runner"]
    direction TB
    A["force-app/<br/>source format"] --> B["sf CLI<br/>convert to metadata format, zip"]
  end

  subgraph CLOUD["Salesforce cloud — inside the org"]
    direction TB
    C["Receive zip<br/>create deploy job"] --> D["Parse metadata<br/>compile Apex and LWC"]
    D --> E["Run Apex tests per testLevel"]
    E --> F{"All passed?"}
    F -- Yes --> G["Commit: components written"]
    F -- No --> H["Roll back: whole deploy discarded"]
  end

  B -- "HTTPS · Metadata API deploy()" --> C
```

Only the middle arrow crosses a network boundary. Everything to its right happens inside Salesforce — which is precisely why Change Sets and DevOps Center can deploy to Production without any machine of yours reaching it.

### The seven stages

1. **Read `sfdx-project.json`** *(local)* — `packageDirectories` decides what gets packaged (here: `force-app`), and `sourceApiVersion` (61.0) tells the org which Metadata API semantics to read your components with.
2. **Source format → metadata format** *(local)* — the repo layout is split up for git's benefit (one file per custom field, for instance). The CLI reassembles it into the shape the Metadata API expects and generates a `package.xml` listing every component.
3. **Zip and upload** *(local → cloud)* — sent via the Metadata API `deploy()` call along with `checkOnly` and `testLevel`. This is the only step that crosses the network boundary.
4. **Job created, id returned** *(cloud)* — the org does not wait for completion. It queues the work and returns a job id (`0Af…`) immediately; the CLI then polls it. **A dropped connection does not cancel the deploy.**
5. **Parse and compile** *(cloud)* — Apex compiles, LWC bundles, field types and references are checked, permission sets are verified against the fields they grant. Dependency order is Salesforce's problem, not yours: objects and the Apex referencing them can go in the same deploy.
6. **Run Apex tests** *(cloud)* — per `testLevel`. Sandbox runs none by default; Production always runs them when Apex is included.
7. **Commit or roll back** *(cloud)* — **transactional and all-or-nothing.** One failed component or one failed test discards the entire deploy and the org returns to its previous state.

### It is an asynchronous job

The CLI looks like it is blocking; it is actually polling and redrawing a progress bar.

```mermaid
sequenceDiagram
  autonumber
  participant CLI as sf CLI on your machine
  participant API as Metadata API
  participant ORG as Org execution engine

  CLI->>CLI: convert source to metadata, zip
  CLI->>API: deploy(zip, checkOnly, testLevel)
  API-->>CLI: job id 0Af... returned immediately
  Note over CLI,API: the connection may drop here;<br/>the job keeps running inside the org

  loop CLI polls every few seconds
    CLI->>API: check deploy status(job id)
    API-->>CLI: Pending / InProgress + components completed
  end

  ORG->>ORG: compile, validate, run tests
  ORG-->>API: result
  API-->>CLI: Succeeded / Failed + component errors + coverage
```

So a `--wait` timeout means "stopped watching", not "failed". Reconnect rather than re-running blindly:

```bash
sf project deploy report --job-id 0Af…    # what actually happened
sf project deploy resume --job-id 0Af…    # reattach to a running deploy
sf project deploy cancel --job-id 0Af…    # stop one that has not finished
```

### Job states and the rollback guarantee

```mermaid
stateDiagram-v2
  direction LR
  [*] --> Pending: deploy request accepted
  Pending --> InProgress: compile and validate
  InProgress --> Succeeded: every component ok, tests met the bar
  InProgress --> Failed: any component or test failed, whole deploy rolled back
  InProgress --> Canceling: cancel requested
  Canceling --> Canceled
  Succeeded --> [*]
  Failed --> [*]
  Canceled --> [*]
```

Only **Succeeded** changes the org. Failed and Canceled both guarantee a return to the pre-deploy state.

> One boundary on that guarantee: rollback covers **metadata**. It does not undo **data** written during the deploy by triggers or post-install logic. Irrelevant to this PoC, but worth knowing before a deploy with data side effects.

### Validate, deploy, quick deploy

All three run the *same* validation and tests. The only differences are the `checkOnly` flag and whether a previous validation result is reused. The value is being able to move the slow part — running the full test suite — outside the release window.

```bash
# 1. Validate ahead of time: full compile + tests, org untouched
sf project deploy start -o poc-sandbox --dry-run

# 2. Inside the release window: apply the already-validated result, tests not re-run
sf project deploy quick --use-most-recent -o poc-sandbox

# …or do both at once, which is what Part 1 Step 4 does for the sandbox
sf project deploy start -o poc-sandbox
```

Salesforce keeps a successful validation available for quick deploy for a limited window (10 days at the time of writing); past that, validate again.

### Test levels and the 75% bar

| Level | Runs | When |
|---|---|---|
| `NoTestRun` | nothing | Sandbox default. Fast iteration; Production rejects it. |
| `RunSpecifiedTests` | only the classes you name | Partial deploys in large orgs. Still subject to the coverage bar. |
| `RunLocalTests` | every test outside managed packages | **The de facto Production standard** — what a production deploy containing Apex falls back to. |
| `RunAllTestsInOrg` | everything, managed packages included | Most conservative and slowest. Full regression before a major upgrade. |

Two hard gates on Production, both computed **org-side** — local numbers do not count:

- **75% org-wide Apex coverage.** Below it, the whole deploy fails.
- **Every trigger needs at least one covered line.** Zero is not allowed.

```bash
sf apex run test -o poc-sandbox --wait 10 --code-coverage

sf project deploy start -o prod --test-level RunLocalTests

sf project deploy start -o prod --test-level RunSpecifiedTests \
  --tests ContactImportControllerTest --tests EventWorkflowTest
```

---

## Part 4 — Deleting metadata (a deploy is an upsert)

The counterintuitive one, and the reason orgs accumulate dead components: **removing a component from the repo does not remove it from the org.** A deploy means "make sure these components exist and look like this" — never "make the org match this directory".

This repo has a live example. When the contact import moved from `.xlsx` to `.csv`, the 861 KB `sheetjs` static resource was deleted from source — but it is **still present in every sandbox it was previously deployed to**.

```mermaid
flowchart TB
  subgraph EXPECTED["What people expect"]
    W1["git rm sheetjs.js"] --> W2["sf project deploy start"] --> W3["sheetjs gone from the org"]
  end

  subgraph ACTUAL["What happens"]
    R1["git rm sheetjs.js"] --> R2["sf project deploy start"]
    R2 --> R3["package.xml no longer lists sheetjs,<br/>so the org is never told to delete it"]
    R3 --> R4["sheetjs untouched in the org"]
  end

  subgraph CORRECT["What actually removes it"]
    F1["destructiveChangesPost.xml<br/>naming StaticResource: sheetjs"] --> F2["plus a package.xml"]
    F2 --> F3["deploy start --post-destructive-changes"] --> F4["sheetjs removed from the org"]
  end
```

Deletions must be **declared**. `destructiveChangesPre.xml` runs *before* the rest of the deploy, `destructiveChangesPost.xml` *after* — use Post when removing something that may still be referenced until the new components land.

```xml
<!-- manifest/destructiveChangesPost.xml -->
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <types>
        <members>sheetjs</members>
        <name>StaticResource</name>
    </types>
</Package>
```

```xml
<!-- manifest/package.xml — must exist, may list no components -->
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <version>61.0</version>
</Package>
```

```bash
# Validate first — deletions cannot be undone
sf project deploy start -o poc-sandbox --dry-run \
  --manifest manifest/package.xml \
  --post-destructive-changes manifest/destructiveChangesPost.xml

# Then apply
sf project deploy start -o poc-sandbox \
  --manifest manifest/package.xml \
  --post-destructive-changes manifest/destructiveChangesPost.xml
```

For this PoC the leftover `sheetjs` is harmless dead weight — `importWizard` no longer references it in any way. Clean it up with the above when convenient; leaving it costs nothing but storage.

---

## Part 5 — Troubleshooting

| Symptom | Actual cause | Fix |
|---|---|---|
| Coverage below 75% fails the whole deploy | the number is computed org-side, not from your local run | confirm with `--code-coverage` in the sandbox before going to Production |
| A component you deleted is still in the org | a deploy is an upsert, not a sync | declare it in destructiveChanges — [Part 4](#part-4--deleting-metadata-a-deploy-is-an-upsert) |
| Permission set fails with "field does not exist" | it grants a field that is not in this deploy's scope | include the field in the deploy, or drop the entry |
| CLI timed out; unclear whether anything applied | deploys are async — a timeout only stops the waiting | `sf project deploy report --job-id` before re-running anything |
| Record page deployed but users cannot see it | the FlexiPage deployed; **activation is not metadata** | activate as Org Default in Setup — Part 1, Step 5 |
| Works in sandbox, fails in Production | Production forces tests; sandbox runs none by default | `--dry-run` against Production before the release window |
| `INVALID_CROSS_REFERENCE_KEY` on a flexipage | it references a component or tab not yet in the org | deploy the whole package together rather than a subset |
| `sf org login web` hangs or errors with no browser / connection refused | no local browser, or a proxy/firewall blocks the `localhost` OAuth callback | use device flow, auth URL, JWT, or access-token login instead — [Part 1, Step 2](#step-2-authenticate-to-the-sandbox) |

---

## Part 6 — R3 upgrade checklist

R3 replaced the approval console with a standard **Approval Process** and the export
screens with **reports**, and made invitees point at either a Contact or a **Lead**.
Work top to bottom; the ordering is load-bearing in sections B–D.

**Two paths.** On a **fresh org**, skip section B entirely and skip step D7 — there is
nothing to migrate. On an org that **already has R2**, every step applies, and section B
is not optional: R3 removes a value from a restricted picklist that existing records sit on.

### A. Before touching an org

- [ ] `git pull` the branch and confirm you are on the R3 commit (`git log --oneline -1`)
- [ ] `npm install && npm test` — 174 LWC tests pass
- [ ] `npm run lint` and `npx prettier --check "force-app/**/*.{js,cls}"` — clean
- [ ] `scripts/quality/run-pmd.sh` — **expect this to fail the first time.** The baseline was pruned of the deleted classes but never re-recorded against the new Lead DML. Read the new findings: if they are the same CRUD/FLS class as the existing ones, `--update`; if they are not, they are real. See [QUALITY.md](QUALITY.md)
- [ ] Read the *Known PoC limits* in [README.md](README.md) — two capabilities are gone on purpose (download tracking; formula-injection sanitising on the approved-list export)

### B. Pre-deploy data migration — existing orgs only

- [ ] Note the current counts, so you can prove the migration did what it claims:
  ```bash
  sf data query -o poc-sandbox \
    -q "SELECT Status__c, COUNT(Id) FROM Event_Invitee__c GROUP BY Status__c"
  ```
- [ ] Move every `Exported` invitee to `Approved` — **a restricted picklist cannot lose a value that records still hold**, so this must happen before the deploy, not after:
  ```bash
  sf apex run --file scripts/r3-pre-deploy.apex -o poc-sandbox
  ```
- [ ] Re-run the count query and confirm `Exported` is now zero
- [ ] Note how many rows are `Pending Approval` — section D7 adopts exactly those

### C. Deploy — fresh org

Nothing to delete, so no manifests: naming a component that does not exist in the org can
fail the whole deploy.

- [ ] Validate — compiles the Apex and checks the metadata without touching the org:
  ```bash
  sf project deploy start -o poc-sandbox --dry-run
  ```
- [ ] Deploy, once the dry run is clean:
  ```bash
  sf project deploy start -o poc-sandbox
  ```
- [ ] `sf apex run test -o poc-sandbox --wait 10 --code-coverage` — the first org-side run of the R3 Apex

Then skip to section D.

### C-upgrade. Deploy — existing R2 org

- [ ] **Validate first.** Deletions cannot be undone, and this deploy contains six:
  ```bash
  sf project deploy start -o poc-sandbox --dry-run \
    --manifest manifest/package.xml \
    --pre-destructive-changes manifest/destructiveChangesPre.xml \
    --post-destructive-changes manifest/destructiveChangesPost.xml
  ```
- [ ] Deploy for real once the dry run is clean:
  ```bash
  sf project deploy start -o poc-sandbox \
    --manifest manifest/package.xml \
    --pre-destructive-changes manifest/destructiveChangesPre.xml \
    --post-destructive-changes manifest/destructiveChangesPost.xml
  ```
- [ ] `sf apex run test -o poc-sandbox --wait 10 --code-coverage` — **the first org-side run of the R3 Apex.** `EventWorkflowTest` drives `Approval.process()` for real; if the approval process or its field updates are wrong, this is where it shows

> **Why the manifests.** A deploy is an upsert: deleting a component from source does
> not delete it from the org ([Part 4](#part-4--deleting-metadata-a-deploy-is-an-upsert)).
> Without them a sandbox keeps a dead *Approved Exports* tab and two orphaned Apex
> classes. The split matters too — `Exported_Count__c` is a roll-up filtering on
> `Status__c = 'Exported'`, so it must go **before** the payload that removes that
> picklist value; everything else is still referenced by metadata the payload rewrites,
> so it must go **after**.

### D. Post-deploy configuration

Steps 1–6 are also in [README.md](README.md); step 7 is upgrade-only.

- [ ] **1. Activate the record page** — Setup → Object Manager → Marketing Event → Lightning Record Pages → *Marketing Event Record Page* → Activate → **Org Default** (Desktop *and* Phone)
- [ ] **2. Assign permission sets** — `Event AM` to AMs, `Event Approver` to approvers
- [ ] **3. Set a Manager on every AM user** (Setup → Users). This is the last rung of the approver ladder. Without it, submitting a self-owned lead is refused — by design, and loudly
- [ ] **4. Turn off per-request approval emails** for approvers (Setup → Users → *Receive Approval Request Emails* → **Never**). This is **Option 1**: one aggregated email per submission instead of one per invitee. Skipping it is not harmless — a 40-row batch sends 40 emails
- [ ] **5. Check the Lead OWD** (Setup → Sharing Settings). Under Private, an approver may not see the Lead behind an invitee they are approving and the name/organisation columns render blank. The PoC assumes **Public Read Only**
- [ ] **6. Share the report folder** — Reports → *Event Management* → share with AM and approver users
- [ ] **7. Adopt the pre-R3 pending invitees** — existing orgs only:
  ```bash
  sf apex run --file scripts/r3-post-deploy.apex -o poc-sandbox
  ```
  Rows with an `Account_Owner__c` snapshot get it as their `Approver__c` and enter the
  approval process; rows without one go back to Draft for the AM to resubmit. Skipping
  this leaves them pending forever with nobody holding a work item
- [ ] **8. Seed demo data** (fresh demo orgs) — set the owner usernames at the top of the script first:
  ```bash
  sf apex run --file scripts/seed-demo-data.apex -o poc-sandbox
  ```

### E. Verify — the two assumptions that were never testable from the repo

Do these before demoing anything. A bad answer to the first changes the Screen 4 design.

- [ ] **Mass approve/reject at scale.** Submit ~40 invitees to one approver, open their Approvals list, and try to select and approve them in one action. If it turns out to be one-at-a-time in this org's release, switch to **Option 2**: add an approval assignment email template to `Invitee_Approval`, re-enable *Receive Approval Request Emails*, and enable Setup → Process Automation Settings → **Email Approval Response** so approvers can reply "approve" from a phone. Both halves must move together, or approvers hear nothing at all
- [ ] **The approval-email setting's real name and options** — confirm D4's wording against the org's UI

### F. Verify — the workflow end to end

- [ ] Import the demo CSV. The preview shows **New Contact** and **New Lead** as separate tiles; after Apply, the Account row count is **unchanged** — no import may ever create an Account
- [ ] Add contacts from *Add Contacts*, submit; the approver is the Account Owner
- [ ] Add a lead you own from *Add Leads*, submit; **the approver is your manager, not you.** This is the one that would look identical to success if it were broken — check the `Approver__c` field on the record, not just that the submit succeeded
- [ ] With no Manager on your user, submitting a self-owned lead fails with a named error and **nothing moves** — no half-submitted batch
- [ ] Approve on desktop, reject one, and check the **Approval History** related list on a decided invitee
- [ ] An `Event Approver` user can see a Lead invitee's name and organisation on the approval request (this is the Lead OWD check paying off)
- [ ] Both AMs get the completion email once their batch has zero pending rows left
- [ ] Reports → *Event Management* → *Approved Invitees — by Event* lists Contact and Lead invitees together, with `Invitee Type` telling them apart; export as CSV and open it in desktop Excel
- [ ] Narrow the report's `Decided At` filter to the approval day — same rows; shift it a day — none
- [ ] Confirm the *Approved Exports* tab is **gone** from the app (this is the destructive manifest paying off)

### G. If it goes wrong

- [ ] A failed deploy rolls back in full — the org is untouched, so fix and re-run ([Part 3](#part-3--how-a-deploy-actually-works))
- [ ] **A successful deploy does not roll back**, and the destructive half is irreversible. Recovering the deleted components means redeploying them from the pre-R3 commit (`git show 032fce9`), and `Exported_Count__c` would come back empty — a roll-up recalculates from current data, and section B has already moved every Exported row to Approved
- [ ] So: dry-run in a scratch or throwaway sandbox before running section C anywhere that matters
