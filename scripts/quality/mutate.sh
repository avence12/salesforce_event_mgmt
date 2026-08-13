#!/usr/bin/env bash
#
# Mutation spot-check for the LWC layer.
#
# Coverage says a line ran. It does not say an assertion would have noticed if
# that line were wrong. This applies a fixed set of small, plausible defects to
# the highest-risk logic and requires the suite to FAIL for each one. A mutant
# that survives is a hole: the line is covered but nothing asserts on it.
#
# There is no off-the-shelf mutation runner for LWC, and none at all for Apex,
# so the mutant list is curated rather than generated — chosen at the points
# where being wrong is expensive (formula-injection guard, CSV parsing, the
# de-duplication rule, the date-range gate).
#
# Usage: scripts/quality/mutate.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

LWC="force-app/main/default/lwc"

# Each mutant: "<file>|<literal find>|<literal replace>|<description>|<expectation>"
# expectation is `kill` (an assertion must catch it) or `equivalent` (the mutant
# provably cannot change behaviour, so surviving is correct and being killed
# would mean the surrounding code changed).
MUTANTS=(
  "$LWC/csvDownload/csvDownload.js|FORMULA_TRIGGERS.includes(text.charAt(0))|false|formula guard never fires|kill"
  "$LWC/csvDownload/csvDownload.js|const safe = guarded ? \`'\${text}\` : text;|const safe = text;|apostrophe prefix dropped|kill"
  "$LWC/csvDownload/csvDownload.js|safe.replace(/\"/g, '\"\"')|safe|embedded quotes not doubled|kill"
  "$LWC/csvDownload/csvDownload.js|UTF8_BOM + csv|csv|UTF-8 BOM dropped|kill"
  "$LWC/importWizard/importWizard.js|if (src[i + 1] === '\"') {|if (false) {|escaped quote handling removed|kill"
  "$LWC/importWizard/importWizard.js|rows.length > MAX_ROWS|false|row cap never enforced|kill"
  "$LWC/importWizard/importWizard.js|const key = [row.lastName, row.firstName, row.company, row.email]|const key = [row.lastName, row.firstName, row.email]|company drops out of the de-dup key, collapsing one person at two companies into one|kill"
  "$LWC/importWizard/importWizard.js|.map((v) => v.toLowerCase().trim().replace(/\\s+/g, ' '))|.map((v) => v)|de-dup key stops normalising, so casing and padding make one person two|kill"
  "$LWC/attendeeSelector/attendeeSelector.js|if (event.target.checked) next.add(event.target.dataset.id);|if (false) next.add(event.target.dataset.id);|selection never records a tick|kill"
  "$LWC/attendeeSelector/attendeeSelector.js|.filter((i) => i.canAttend && !this.attendedIds.has(i.inviteeId))|.filter((i) => !this.attendedIds.has(i.inviteeId))|unapproved rows are sent as not-attended, so the server decides what the UI should have|kill"
  "$LWC/attendeeSelector/attendeeSelector.js|return this.invitees.filter((i) => i.canAttend).length;|return this.invitees.length;|attendance is counted against every invitee instead of the approved ones|kill"
  "$LWC/attendeeSelector/attendeeSelector.js|const notAttendedIds = this.invitees|const notAttendedIds = [];  const _unused = this.invitees|absence is inferred server-side instead of sent, which would silently clear everyone past the row cap|kill"

  # Equivalent: dropping the CRLF skip makes '\r' and '\n' two separate
  # terminators, but the empty row that produces is ['']  — which
  # `rows.filter(r => r.length > 1 || r[0] !== '')` at the end of parseCsv
  # already discards. Verified identical output across CRLF-heavy inputs
  # including quoted fields with embedded CRLF. The i++ is defensive, not
  # load-bearing; no assertion can distinguish the two, and writing one that
  # appeared to would be testing nothing.
  "$LWC/importWizard/importWizard.js|if (c === '\\r' && src[i + 1] === '\\n') {|if (false) {|CRLF skip is redundant given the empty-row filter|equivalent"
)

pass=0; survived=0
declare -a SURVIVORS

for entry in "${MUTANTS[@]}"; do
    IFS='|' read -r file find replace desc expectation <<< "$entry"

    if ! grep -qF -- "$find" "$file"; then
        echo "  ERROR  mutant target not found in $(basename "$file"): $desc"
        echo "         (the code moved — update scripts/quality/mutate.sh)"
        survived=$((survived + 1))
        SURVIVORS+=("$desc [stale mutant]")
        continue
    fi

    cp "$file" "$file.mutbak"
    # Literal, one-occurrence replacement via python to avoid sed escaping.
    MUT_FILE="$file" MUT_FIND="$find" MUT_REPLACE="$replace" python3 - <<'PY'
import os
p = os.environ['MUT_FILE']
s = open(p, encoding='utf-8').read()
open(p, 'w', encoding='utf-8').write(s.replace(os.environ['MUT_FIND'], os.environ['MUT_REPLACE'], 1))
PY

    if npx sfdx-lwc-jest -- --ci --silent >/dev/null 2>&1; then
        # Suite still green: the mutant survived.
        if [[ "$expectation" == "equivalent" ]]; then
            echo "  survived  $desc (expected — equivalent mutant)"
            pass=$((pass + 1))
        else
            echo "  SURVIVED  $desc"
            survived=$((survived + 1))
            SURVIVORS+=("$desc")
        fi
    else
        if [[ "$expectation" == "equivalent" ]]; then
            echo "  KILLED    $desc"
            echo "            Expected this to be unobservable, but a test caught it."
            echo "            The surrounding code changed — re-check the justification."
            survived=$((survived + 1))
            SURVIVORS+=("$desc [equivalence claim is now stale]")
        else
            echo "  killed    $desc"
            pass=$((pass + 1))
        fi
    fi

    mv "$file.mutbak" "$file"
done

echo
echo "  ${pass} as expected, ${survived} unexpected, ${#MUTANTS[@]} total"

if [[ $survived -gt 0 ]]; then
    echo
    echo "  Unexpected results — code is covered but nothing asserts it is correct:"
    for s in "${SURVIVORS[@]}"; do echo "    - $s"; done
    exit 1
fi
echo "  Every injected defect behaved as expected."
