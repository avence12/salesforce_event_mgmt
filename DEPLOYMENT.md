# Deployment Guide

How to deploy this PoC to a **Sandbox**, and the recommended paths to **Production** under a strict network-isolation policy (developer machines cannot reach Salesforce orgs directly).

> Key fact: a Salesforce deployment happens between *the machine running the `sf` CLI* and the Salesforce API — or, with Change Sets / DevOps Center, entirely **cloud-to-cloud inside Salesforce**. Your laptop never needs to reach Production.

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

```bash
sf org login web --alias poc-sandbox --instance-url https://test.salesforce.com
```

On a browser-less jump host, use the device flow instead — it prints a code you enter from any intranet browser:

```bash
sf org login device --alias poc-sandbox --instance-url https://test.salesforce.com
```

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
- Use **Validate + Quick Deploy**: validate against Production ahead of time (runs tests, changes nothing), then one-click quick-deploy inside the release window — cuts deployment risk to minutes.

**Recommendation**: Change Sets for the demo/short term → DevOps Center if the PoC is productized → in-network CI/CD at scale.
