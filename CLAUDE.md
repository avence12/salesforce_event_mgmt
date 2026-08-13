# Project notes

## This is a greenfield project — there is no data to migrate

Nothing has ever been deployed to a production org, and there are no existing records
anywhere. **Do not design around data migration, backward compatibility, or upgrading an
org that holds an earlier revision.**

Concretely, this means:

- A field can be renamed, retyped or deleted outright. No two-phase "add the new one, migrate,
  drop the old one" dance.
- A restricted picklist's values can be replaced in place. The usual trap — a restricted
  picklist cannot lose a value that records still hold — cannot bite, because no record holds
  anything.
- An object can be deleted in the same change that replaces it.
- No pre-deploy or post-deploy data scripts. No destructive-changes manifests written to clean
  up what an earlier revision left in an org.
- Deployment guidance should describe deploying to a **fresh** org, not upgrading one.

The revision history in `design.md` (R2 → R6) is a record of how the design *thinking*
evolved, not of anything that shipped. Keep the reasoning — it explains why the current shape
is what it is — but do not treat earlier revisions as deployed state that has to be reached
from.

If a change looks like it needs a migration, that is a signal the change can simply be made
directly.

## Working agreements

- The user writes in Traditional Chinese; reply in Traditional Chinese. Code, comments,
  metadata descriptions, commit messages and all UI copy stay in **English** — the AM audience
  is US/EU.
- State the cost of a design decision plainly rather than only its benefit. Open questions in
  `design.md` are for things a business has to answer, not for things that can be looked up.
- Verify rather than assert: run the tests, parse the mermaid, grep for stale references. Say
  explicitly what could not be verified here (Apex tests and any deploy need a real org).

## Commands

```bash
npm test                    # LWC jest suite
npm run lint                # ESLint
npm run prettier:verify     # format check
scripts/quality/mutate.sh   # mutation testing
npm run gauntlet            # all of the above plus PMD
```
