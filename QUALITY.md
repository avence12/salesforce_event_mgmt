# Quality Gate

One command runs every automated check this project has:

```bash
npm install          # once
npm run gauntlet     # or: scripts/quality/gauntlet.sh
```

The approach is borrowed from [old-coder](https://github.com/AmazingAng/old-coder): instead of
reviewing generated code line by line, you agree the *specification* up front and then read an
*evidence report* afterwards. That only works if the evidence is trustworthy, which is what the
layers below are for.

**The one rule that makes the rest work: a layer that did not run is never reported as passing.**
The gauntlet prints `SKIP` with a reason and counts it separately, because "unknown" and "green"
are different answers.

---

## The layers

| Layer | What it proves | Runs where |
|---|---|---|
| **LWC unit tests + coverage** | Behaviour is asserted, and the assertion count did not quietly drop | local |
| **ESLint** | No LWC anti-patterns (async in components, document queries, wire misuse) | local |
| **Prettier** | Formatting is not a review topic | local |
| **PMD** | No *new* Apex static-analysis violations | local (needs PMD installed) |
| **Mutation spot-check** | The tests would actually *notice* a defect | local |
| **Suite health** | No focused tests; the suite passes in randomised order | local |
| **Apex tests** | Apex behaviour + the 75% org coverage bar | **org-side only** |
| **Deploy validation** | Metadata compiles and resolves | **org-side only** |

The last two need `--org <alias>`; they cannot be faked locally, because Salesforce computes both
inside the org (see [DEPLOYMENT.md](DEPLOYMENT.md) Part 3).

```bash
scripts/quality/gauntlet.sh --org poc-sandbox    # all eight layers
SKIP_MUTATION=1 scripts/quality/gauntlet.sh      # skip the slow layer while iterating
```

---

## Why coverage alone is not evidence

Coverage says a line *ran*. It does not say an assertion would have failed had that line been
wrong. A test that calls a function and asserts nothing produces 100% coverage and zero signal.

`scripts/quality/mutate.sh` closes that gap by injecting small, plausible defects into the
highest-risk logic and requiring the suite to go red for each one:

```
killed    formula guard never fires
killed    apostrophe prefix dropped
killed    embedded quotes not doubled
killed    UTF-8 BOM dropped
killed    escaped quote handling removed
killed    row cap never enforced
killed    de-dup becomes case sensitive
killed    inverted date range accepted
survived  CRLF skip is redundant given the empty-row filter (expected — equivalent mutant)
```

The mutant list is curated, not generated — there is no mutation runner for LWC, and none at all
for Apex. It targets the places where being wrong is expensive: the CSV formula-injection guard,
the parser, the de-duplication rule, and the date-range gate.

**Equivalent mutants are declared, not deleted.** The surviving one above is marked `equivalent`
because dropping the CRLF skip provably cannot change the output — the empty row it creates is
already discarded by the filter at the end of `parseCsv`, verified across CRLF-heavy inputs
including quoted fields with embedded CRLF. If a future change makes that mutant killable, the
script fails and tells you the justification is stale. Writing a test that *appeared* to catch it
would be testing nothing.

---

## Anti-gaming rules

These are the rules that keep the evidence honest. They matter more than any individual number.

1. **Never weaken a test to reach green.** If a test fails, the code is wrong until proven otherwise.
2. **Never edit a test and the code it covers in the same step.** Change one, watch the other react.
3. **Never chase a coverage percentage with assertion-free tests.** The mutation layer exists to
   catch exactly this.
4. **Never report a layer that did not run.** `SKIP` is a valid outcome; silence is not.
5. **A failing gauntlet blocks completion.** Not "blocks merge pending discussion" — blocks.
6. **Suppress a static-analysis finding only at the site, with the reason.** A blanket exclusion
   hides the next real one.

---

## Calibrating effort

Not every change deserves the full ceremony.

| Tier | Example | What to run |
|---|---|---|
| **1 — trivial** | comment, rename, doc | `npm test && npm run lint` |
| **2 — normal** | a bug fix, a new field on the preview table | full gauntlet; a test that fails before the fix and passes after |
| **3 — high stakes** | anything touching approvals, exports, sharing, or the CSV writers | full gauntlet + a new mutant in `mutate.sh` covering the new branch |

Tier 3 is not academic here. The export path writes files that Excel opens, and the approval path
decides who sees whose contacts — both already have specific tests because both have specific ways
of going wrong.

---

## Current state

Run on the commit that introduced this file:

```
LWC tests      228 passing
LWC coverage   99.28% statements · 98.07% branches · 98.49% functions · 99.71% lines
ESLint         clean
Prettier       clean
PMD            no new violations (84 pre-existing, baselined)
Mutation       9/9 as expected
Apex tests     not run — needs an org
```

Re-run after the R3 revision (standard Approval Process + reports, Lead invitees):

```
LWC tests      174 passing   (54 fewer — the approvedExport and approvalConsole suites
                              went with their components; contactSelector gained a
                              Leads-tab suite)
ESLint         clean
Prettier       clean
PMD            not run — PMD is not installed in this environment
Mutation       9/9 as expected
Apex tests     not run — needs an org
```

**The PMD baseline is stale and must be re-recorded on the first machine that has PMD.**
It was pruned of the 11 findings belonging to the two deleted classes (84 → 73), but the
Lead DML added to `ContactImportController` and `InviteeSelectorController` will almost
certainly raise new `ApexCRUDViolation` findings that nobody has seen yet. Run
`scripts/quality/run-pmd.sh` and expect it to fail before it passes; if the new findings are
the same CRUD/FLS class as the existing ones, `--update` is the right response, and if they
are not, they are real.

### Known gaps, stated plainly

- **Apex has no local test layer.** Apex tests only run inside an org. Everything the gauntlet
  checks locally for Apex is static analysis. Run with `--org` before believing a change is safe.
- **84 baselined PMD violations.** PMD was adopted against an existing codebase, so the gate is
  "no new violations" rather than zero. The baseline is `scripts/quality/pmd-baseline.txt`;
  the bulk is 50 × `ApexAssertionsShouldIncludeMessage` (test assertions without messages) and
  26 × `ApexCRUDViolation`. The CRUD findings overlap the FLS gap already noted in
  [README.md](README.md) — they are real, not noise, and worth burning down.
- **No mutation testing for Apex.** No tool exists. Apex correctness rests on the two test classes
  and the org-side coverage bar.
- **The declarative half of the workflow has no local test at all.** Since R3, approval routing
  behaviour lives in an Approval Process, the status state machine lives in workflow field
  updates, and the export lives in two saved reports. `EventWorkflowTest` drives the approval
  process through `Approval.process()` and so covers the routing and the field updates *when run
  in an org* — but the reports, the report type and the record-triggered Flow are exercised by
  nothing. Moving code into configuration moved it out of reach of the test suite; that is a real
  cost of the standardisation, not a free win.
- **`importWizard.toast()` is dead code** — defined, never called, and the only reason
  `ShowToastEvent` is imported there. It is the one uncovered line in the LWC suite. Left in place
  rather than removed, because deleting it is a behaviour-neutral change that belongs in its own
  commit.

---

## Working on the code

```bash
npm test                    # watch-free single run
npm run test:watch          # while writing a component
npm run test:coverage       # with the coverage thresholds enforced
npm run lint                # ESLint
npm run prettier            # format in place
npm run pmd                 # Apex static analysis vs the baseline
scripts/quality/run-pmd.sh --full     # every current PMD finding, with line numbers
scripts/quality/run-pmd.sh --update   # re-baseline (only after fixing things)
```

### Installing PMD

PMD is not on npm and is ~70 MB, so it is not vendored. The gauntlet finds it via `$PMD_HOME`,
`pmd` on `PATH`, or the `sf scanner` plugin — and skips loudly if none is present.

```bash
# option A — PMD directly
export PMD_HOME=/path/to/pmd-bin-7.7.0        # from https://github.com/pmd/pmd/releases

# option B — via the Salesforce CLI plugin, which bundles PMD
sf plugins install @salesforce/sfdx-scanner
```

### Writing LWC tests

Two things about this project's setup are worth knowing before you write a spec.

**Mock each Apex method individually.** Do *not* add a catch-all `moduleNameMapper` for
`@salesforce/apex/*`. Every Apex import would resolve to the same module — and therefore the same
`jest.fn()` — so stubbing one method silently rebinds every other method in the component.
`@lwc/jest-transformer` already gives each import its own mock; opt in per method:

```js
jest.mock('@salesforce/apex/MyController.myMethod', () => ({ default: jest.fn() }), {
    virtual: true
});
```

**Drive components through their real entry points.** LWC only exposes `@api` members on the host
element, so internal methods are unreachable — and that is a feature. The `importWizard` specs feed
a real `File` to the file input and assert on the rows the component sends to Apex; that exercises
the decoder, the delimiter sniffer, the parser and the de-duplication in one path, the same way a
user would. Two jsdom quirks the helpers already handle: `TextEncoder` needs the polyfill in
`force-app/test/jest-setup.js`, and jsdom clears `event.target` once dispatch returns, so an async
handler that touches it after an `await` needs the target pinned on the event.
