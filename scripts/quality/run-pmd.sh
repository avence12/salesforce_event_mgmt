#!/usr/bin/env bash
#
# Apex static analysis.
#
# PMD is not vendored into the repo (the distribution is ~70 MB) and is not on
# npm, so this locates an existing install. Under the network-isolation policy
# this project targets, an offline PMD install is the expected setup — see
# DEPLOYMENT.md.
#
# Resolution order:
#   1. $PMD_HOME/bin/pmd
#   2. `pmd` on PATH
#   3. `sf scanner` (Salesforce Code Analyzer plugin, which bundles PMD)
#
# The gate is "no NEW violations": current output is compared against
# scripts/quality/pmd-baseline.txt, which records what the codebase already had
# when PMD was adopted. New findings fail; pre-existing ones are reported as a
# standing debt count so they stay visible instead of being silently accepted.
#
# Usage:
#   scripts/quality/run-pmd.sh              # check against the baseline
#   scripts/quality/run-pmd.sh --update     # re-record the baseline
#   scripts/quality/run-pmd.sh --full       # print every current violation

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RULESET="$REPO_ROOT/scripts/quality/pmd-ruleset.xml"
BASELINE="$REPO_ROOT/scripts/quality/pmd-baseline.txt"
SOURCES="$REPO_ROOT/force-app/main/default/classes"

MODE="check"
case "${1:-}" in
    --update) MODE="update" ;;
    --full)   MODE="full" ;;
    "")       ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
esac

find_pmd() {
    if [[ -n "${PMD_HOME:-}" && -x "$PMD_HOME/bin/pmd" ]]; then
        echo "$PMD_HOME/bin/pmd"
    elif command -v pmd >/dev/null 2>&1; then
        command -v pmd
    fi
}

PMD_BIN="$(find_pmd)"

if [[ -z "$PMD_BIN" ]]; then
    if command -v sf >/dev/null 2>&1 && sf scanner --help >/dev/null 2>&1; then
        echo "pmd: using 'sf scanner' (bundled PMD)"
        sf scanner run --target "$SOURCES" --pmdconfig "$RULESET" --format table
        exit $?
    fi
    # Never claim a layer passed when it did not run.
    echo "pmd: SKIPPED — PMD not found."
    echo "     Install it and re-run, or set PMD_HOME:"
    echo "       https://github.com/pmd/pmd/releases  (unzip, then export PMD_HOME=/path/to/pmd-bin-<version>)"
    echo "       or: sf plugins install @salesforce/sfdx-scanner"
    exit 3
fi

# Normalised to "relative/path<TAB>RULE", one line per violation, duplicates
# kept. Line numbers are deliberately excluded: with them, inserting a line at
# the top of a file shifts every violation below it and the whole file reads as
# new. Counting (file, rule) pairs instead means the gate reacts to an added
# violation, not to code moving.
raw_report() {
    "$PMD_BIN" check -R "$RULESET" -d "$SOURCES" -f text --no-cache 2>/dev/null || true
}

current="$(
    raw_report \
        | sed "s|^$REPO_ROOT/||" \
        | awk -F'\t' 'NF>1 { sub(/:[0-9]+:$/, "", $1); print $1 "\t" $2 }' \
        | sed 's/\t\+/\t/g' \
        | sort
)"

if [[ "$MODE" == "full" ]]; then
    raw_report | sed "s|^$REPO_ROOT/||"
    exit 0
fi

if [[ "$MODE" == "update" ]]; then
    printf '%s\n' "$current" | grep -c . >/dev/null 2>&1 || current=""
    printf '%s\n' "$current" > "$BASELINE"
    echo "pmd: baseline updated — $(grep -c . "$BASELINE" || true) violation(s) recorded"
    exit 0
fi

[[ -f "$BASELINE" ]] || { echo "pmd: no baseline; run with --update first" >&2; exit 2; }

# comm on two sorted multisets: a rule that fires 4 times where the baseline
# recorded 3 leaves exactly one line in column 1.
new_findings="$(comm -23 <(printf '%s\n' "$current") <(sort "$BASELINE"))"
new_count="$(printf '%s' "$new_findings" | grep -c . || true)"
baseline_count="$(grep -c . "$BASELINE" || true)"

if [[ "$new_count" -gt 0 ]]; then
    echo "pmd: FAIL — $new_count new violation(s):"
    printf '%s\n' "$new_findings" | sed 's/^/    /'
    echo
    echo "    Run --full to see them with line numbers."
    echo "    Fix them, or if a finding is a false positive, suppress it at the site"
    echo "    with @SuppressWarnings('PMD.RuleName') and a comment saying why."
    exit 1
fi

echo "pmd: PASS — no new violations (${baseline_count} pre-existing, see $(basename "$BASELINE"))"
