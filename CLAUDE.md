# Project notes

## The org has real data; this project's objects are new

The target org is a live org with existing **Account, Contact and other standard-object
data**. What this project adds is **new custom objects** — `Marketing_Event__c`,
`Event_Attendee__c`, `Event_Invitee__c` — which hold no records anywhere yet.

Those two halves pull in opposite directions, and both matter:

### Our own objects: no data, so no migration

Nothing in `force-app/main/default/objects` has ever been deployed and no record of ours
exists. **Do not design around data migration, backward compatibility, or upgrading an org
that holds an earlier revision of this project.**

- A field can be renamed, retyped or deleted outright. No two-phase "add the new one,
  migrate, drop the old one" dance.
- A restricted picklist's values can be replaced in place. The usual trap — a restricted
  picklist cannot lose a value that records still hold — cannot bite, because no record of
  ours holds anything.
- An object can be deleted in the same change that replaces it.
- No pre-deploy or post-deploy data scripts for our objects, and no destructive-changes
  manifests written to clean up what an earlier revision left behind.
- The revision history in `design.md` (R2 → R6) records how the design *thinking* evolved,
  not anything that shipped. Keep the reasoning — it explains why the current shape is what
  it is — but do not treat earlier revisions as deployed state to migrate from.

If a change looks like it needs a migration of our data, that is a signal the change can
simply be made directly.

### The org's data: do not touch it

The flip side is the real constraint. Account and Contact hold live business data this project
does not own. **The workflow never writes it** — no Account, Contact or Lead is created,
updated or deleted, anywhere, by any code path. That is not stylistic tidiness; it is what
makes the deploy safe to run against a populated org, and it is asserted in
`AttendeeImportControllerTest.importNeverTouchesContactsLeadsOrAccounts` rather than merely
intended. Treat it as an invariant, not a preference.

**Reading is a weaker rule, and R8 is where the two parted company.** Until R8 the workflow
also read nothing — the model contained no standard object at all, which made the no-write
guarantee true by construction rather than by discipline. R8 reintroduced two references,
deliberately: `Event_Attendee__c.Contact__c` records that an imported person also exists as a
Contact, and the invitee snapshots a company from `Contact.Account`. Reading is therefore
allowed where a decision has been recorded for it; writing is not, at all, ever. Three rules
keep that boundary honest and none of them is optional:

- **The import still reads nothing.** Screen 1 matches no CSV row against Contact, Lead or
  Account. The Contact link is populated by a separate reconciliation step an admin runs.
- **No lookup to a standard object may use `deleteConstraint Restrict`.** Our record must never
  be able to block the org from deleting its own Contact or Account. `SetNull` always.
- **No permission on a standard object ships in this repo.** `Event_AM` and `Event_Approver`
  still grant nothing on Account, Contact or Lead. Apex can read what it needs for a snapshot
  without those grants; a *user* seeing the linked record needs Read, and that grant is an
  admin's decision in the post-deploy checklist. Design the UI so the useful half of the answer
  survives without it — `Is_Known_Contact__c` is the pattern.

**User is a narrower case of the same rule, not an exception to it.** Every record's `OwnerId`
and `CreatedById`, the manager-routed approval and the approval chain design's
`Approval_Route__c.Approver__c` all point at a User — that reference is unavoidable and is
exactly what makes routing work. What must never happen is a User record being created,
updated or deleted. `EventWorkflowTest.submitAndApproveNeverModifyUsers` asserts it across
submit and decide; the only place a User is ever written is test setup building a manager
hierarchy fixture, never a code path that runs against the real org.

Being a good neighbour in a populated org also means: never ship a layout, record type,
picklist change or sharing setting for a standard object, and never assume a Setup-level
toggle can be flipped org-wide. Anything the feature needs from outside its own objects
belongs in the post-deploy checklist as a manual step, so an admin decides.

**A deploy of this project is purely additive to that org.** Deployment guidance should say
so plainly, and should not read as though it were upgrading a previous release.

## Working agreements

- The user writes in Traditional Chinese; reply in Traditional Chinese. Code, comments,
  metadata descriptions, commit messages and all UI copy stay in **English** — the AM audience
  is US/EU.
- State the cost of a design decision plainly rather than only its benefit. Open questions in
  `design.md` are for things a business has to answer, not for things that can be looked up.
- Verify rather than assert: run the tests, parse the mermaid, grep for stale references. Say
  explicitly what could not be verified here — Apex tests and any deploy need a real org.

## Commands

```bash
npm test                    # LWC jest suite
npm run lint                # ESLint
npm run prettier:verify     # format check
scripts/quality/mutate.sh   # mutation testing
npm run gauntlet            # all of the above plus PMD
```
