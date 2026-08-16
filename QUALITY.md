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

**R4 update:** `ContactImportControllerTest` was rewritten around the negative assertions —
*no Contact created, updated or deleted* and *no Account created*. Those are the requirement
itself rather than a detail of it, so they assert on `LastModifiedDate` and row counts rather
than on the controller's own return values: a controller that lies about what it did cannot
make them pass.

Re-run after the R5 revision (`Event_Attendee__c`; the import touches no standard object):

```
LWC tests      167 passing   (7 fewer — contactSelector's two-tab suite became
                              attendeeSelector's one-tab suite, and the importWizard
                              specs lost the Event-column and ambiguity cases)
ESLint         clean
Prettier       clean
PMD            not run — PMD is not installed in this environment
Mutation       not run — needs a local run; two mutants were repointed, see below
Apex tests     not run — needs an org
```

**R5 update — the negative assertions got wider, not weaker.**
`AttendeeImportControllerTest.importNeverTouchesContactsLeadsOrAccounts` now covers three
standard objects rather than two, and it seeds a Contact and a Lead that the uploaded file
deliberately names with contradictory data, so "we walked past them" is asserted rather than
assumed. A second test, `anExistingContactIsImportedAsAnAttendeeAnyway`, pins the behaviour
that looks like a bug and is the design: it exists so that reintroducing Contact matching
breaks a test instead of passing quietly.

Re-run after the ★R9 revision (the multi-level approval chain):

```
LWC tests      203 passing   (5 more — the submit toast's chain sentence, and the
                              approver's "Level 2 of 3" badge with its single-level case)
ESLint         clean
Prettier       clean
PMD            not run — PMD is not installed in this environment
Mutation       13/13 as expected
Apex tests     not run — needs an org
```

**★R9 update — the Apex tests grew a class and both existing ones grew a fixture.**
`ApprovalChainServiceTest` tests the routing rule away from the workflow that uses it, against
two deliberately different org charts: one ending in a Regional Head with somebody above them,
which is the only way to prove the chain *stops* rather than merely running out, and one of four
plain untitled managers, which is the only way to prove the level cap and the submitter exclusion
without a Regional Head quietly ending the walk first. Every test sets the configuration
explicitly rather than reading the shipped `Default` record — otherwise they would be asserting
what an administrator last typed into Setup.

`EventWorkflowTest` and `InviteeApprovalControllerTest` now build an org chart and customers with
owners, because that is what a chain is made of. Two consequences worth knowing before reading
them:

- **The "nothing was written to the org's data" assertions changed shape, not strength.** They
  used to count Accounts and Contacts to zero; a fixture that *has* both means they now compare
  `LastModifiedDate` and row counts before and after. That is the stronger form — counting to
  zero cannot catch a modification, only a creation.
- **Approvals are driven through whoever the platform says holds the work item**, never through a
  named user the test picked. A test that names its own approver would pass even if the routing
  sent the item somewhere else entirely, which is precisely the defect a chain makes easy.

The two things these tests cannot reach are in design.md's *★R9 What still needs an org*: whether
a step past the end of a chain is skipped rather than final-approving, and whether a step's
approval action fires the flow that notifies the next level. Both are approval-process behaviour
and neither exists outside an org.

Two mutants in `scripts/quality/mutate.sh` were repointed rather than deleted. The Event
component of the de-dup key no longer exists, so the mutant that removed it was replaced by
one that removes **company** — the same class of defect against the key R5 actually relies
on — plus a new one that strips the key's normalisation, because case and whitespace folding
is now the difference between one attendee and two. The selector mutant moved with the
renamed component.

**The PMD baseline is stale and must be re-recorded on the first machine that has PMD.**
It has been pruned of the 18 findings belonging to `ContactImportController` and its test
(73 → 55), but `AttendeeImportController` and the reworked `InviteeSelectorController` have
never been scanned. Run `scripts/quality/run-pmd.sh` and expect it to fail before it passes;
if the new findings are the same CRUD/FLS class as the existing ones, `--update` is the right
response, and if they are not, they are real. Note that the CRUD/FLS surface *shrank* in R5 —
the Apex now touches one custom object instead of Contact, Lead and two custom objects — so a
large new crop of CRUD findings would itself be worth reading twice.

Re-run after the R6 revision (attendance + event topics):

```
LWC tests      181 passing   (14 more — the attendance column, its dirty tracking,
                              and the both-lists-explicit contract)
ESLint         clean
Prettier       clean
PMD            not run — PMD is not installed in this environment
Mutation       13/13 as expected (2 new mutants, see below)
Apex tests     not run — needs an org
```

**R6 update — the two mutants worth having.** Attendance saving has one contract that is easy
to get wrong and invisible when you do: the client sends *both* the attended and the
not-attended list, rather than sending the ticked ones and letting the server infer absence.
Inferring would silently clear attendance for everybody past the 2,000-row cap the invitee
list is capped at — a bug that only appears on large events and looks like data loss, not like
a defect. One mutant replaces the not-attended list with an empty array; another drops the
`canAttend` filter so unapproved rows get sent. Both are killed. A third checks that the
summary counts against approved invitees rather than all of them.

The Apex side carries the same contract and is tested for it in `EventWorkflowTest`, including
the case that matters most: an id belonging to a *different* event must not be writable through
this event's save. `Attended_Requires_Approved` is asserted twice on purpose — once through the
controller, which reports the skipped row rather than failing the batch, and once with a direct
DML that must be refused by the database. A guard that only exists in Apex is a guard that
disappears the first time somebody uses Data Loader.

### Known gaps, stated plainly

- **Apex has no local test layer.** Apex tests only run inside an org. Everything the gauntlet
  checks locally for Apex is static analysis. Run with `--org` before believing a change is safe.
- **55 baselined PMD violations, and the count is not trustworthy right now.** PMD was adopted
  against an existing codebase, so the gate is "no new violations" rather than zero. The baseline
  is `scripts/quality/pmd-baseline.txt`. R5 pruned the 18 entries belonging to the deleted
  `ContactImportController` and its test, but nothing has scanned the classes that replaced them
  — so 55 is "what survived a deletion", not "what the code currently produces". Re-record it on
  the first machine with PMD installed. The CRUD findings overlap the FLS gap already noted in
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
- **★R6 Attendance data is only as good as the marking-up.** Nothing sets `Attended__c`
  automatically, and no test can cover an AM forgetting to tick the boxes. The design chose that
  over inferring attendance from approval, because false attendance data is worse than none —
  but it means the *Attendee Event History* report is empty until somebody does the work, and
  there is no signal distinguishing "nobody came" from "nobody marked it up".
- **★R6 `Topic__c` ships with placeholder values, and no test can catch that.** The taxonomy is
  a business decision; until it is replaced and past events are back-filled, every similarity
  judgement the R6 work exists to support is noise. This is a data gap, not a code gap, which is
  exactly why it needs saying here — the whole suite goes green with it unaddressed.
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
