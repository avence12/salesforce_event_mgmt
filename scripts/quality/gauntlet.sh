#!/usr/bin/env bash
#
# The gauntlet: every automated check this project can run, in one command.
#
# Each layer reports PASS, FAIL or SKIPPED-with-a-reason. A layer that could not
# run is never reported as passing — a skip is a hole in the evidence and is
# printed as such, so the summary reflects what was actually verified.
#
# Usage:
#   scripts/quality/gauntlet.sh              # everything runnable locally
#   scripts/quality/gauntlet.sh --org <alias>  # also run Apex tests in that org
#
# Exit code is 0 only if no layer failed. Skips do not fail the run, but they
# are counted and listed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

ORG_ALIAS=""
if [[ "${1:-}" == "--org" ]]; then
    ORG_ALIAS="${2:-}"
    [[ -n "$ORG_ALIAS" ]] || { echo "--org needs an alias" >&2; exit 2; }
fi

PASSED=(); FAILED=(); SKIPPED=()

hr() { printf '\n\033[1m── %s\033[0m\n' "$1"; }

# run <name> <command...>: exit 3 from the command means "skipped".
run() {
    local name="$1"; shift
    hr "$name"
    "$@"
    local status=$?
    if [[ $status -eq 0 ]]; then
        PASSED+=("$name")
    elif [[ $status -eq 3 ]]; then
        SKIPPED+=("$name")
    else
        FAILED+=("$name")
    fi
    return 0
}

# ---------------------------------------------------------------- layers

layer_jest() {
    # Runs the coverage thresholds in jest.config.js, so a coverage regression
    # fails here rather than being a number someone eyeballs.
    npx sfdx-lwc-jest -- --coverage --ci
}

layer_eslint() {
    npx eslint force-app/main/default/lwc
}

layer_prettier() {
    npx prettier --check \
        "force-app/**/*.{js,html,css,cls,trigger}" \
        "scripts/**/*.mjs" \
        "*.json"
}

layer_pmd() {
    scripts/quality/run-pmd.sh
}

layer_mutation() {
    # Coverage proves a line ran; this proves an assertion would notice if it
    # were wrong. Slow (one full suite run per mutant), so it is opt-out.
    if [[ "${SKIP_MUTATION:-}" == "1" ]]; then
        echo "SKIPPED — SKIP_MUTATION=1"
        return 3
    fi
    scripts/quality/mutate.sh
}

layer_suite_health() {
    # A focused test silently shrinks the suite to one case while still
    # reporting green, which is the most expensive way to lose coverage.
    local focused
    focused="$(grep -rEn '\b(describe|it|test)\.only\b' \
        force-app/main/default/lwc --include='*.test.js' || true)"
    if [[ -n "$focused" ]]; then
        echo "found focused tests — the suite is not running everything:"
        printf '%s\n' "$focused" | sed 's/^/    /'
        return 1
    fi

    # Order independence: a suite that only passes in one order is hiding
    # shared state between specs.
    echo "checking order independence (randomised run)…"
    npx sfdx-lwc-jest -- --ci --randomize >/dev/null 2>&1 || {
        echo "suite fails when spec order is randomised — specs share state"
        return 1
    }
    echo "no focused tests; suite passes in randomised order"
}

layer_apex_tests() {
    if [[ -z "$ORG_ALIAS" ]]; then
        echo "SKIPPED — no org given. Apex tests and their coverage are computed"
        echo "          org-side, not locally. Re-run with: --org <alias>"
        return 3
    fi
    if ! command -v sf >/dev/null 2>&1; then
        echo "SKIPPED — sf CLI not installed"
        return 3
    fi
    sf apex run test --target-org "$ORG_ALIAS" --wait 10 --code-coverage --result-format human
}

layer_deploy_validate() {
    if [[ -z "$ORG_ALIAS" ]]; then
        echo "SKIPPED — no org given. A dry-run deploy is the only check that"
        echo "          compiles Apex and validates metadata. Re-run with: --org <alias>"
        return 3
    fi
    if ! command -v sf >/dev/null 2>&1; then
        echo "SKIPPED — sf CLI not installed"
        return 3
    fi
    sf project deploy start --target-org "$ORG_ALIAS" --dry-run
}

# ---------------------------------------------------------------- run

echo "gauntlet: $(git rev-parse --short HEAD 2>/dev/null || echo 'no git') on $(date -u +%Y-%m-%dT%H:%M:%SZ)"

run "LWC unit tests + coverage"  layer_jest
run "ESLint (LWC)"               layer_eslint
run "Prettier format check"      layer_prettier
run "PMD (Apex static analysis)" layer_pmd
run "Mutation spot-check"        layer_mutation
run "Suite health"               layer_suite_health
run "Apex tests (org-side)"      layer_apex_tests
run "Deploy validation (dry run)" layer_deploy_validate

# ---------------------------------------------------------------- summary

hr "Summary"
for n in "${PASSED[@]:-}";  do [[ -n "$n" ]] && printf '  \033[32mPASS\033[0m    %s\n' "$n"; done
for n in "${SKIPPED[@]:-}"; do [[ -n "$n" ]] && printf '  \033[33mSKIP\033[0m    %s\n' "$n"; done
for n in "${FAILED[@]:-}";  do [[ -n "$n" ]] && printf '  \033[31mFAIL\033[0m    %s\n' "$n"; done

n_pass=${#PASSED[@]}; n_skip=${#SKIPPED[@]}; n_fail=${#FAILED[@]}
echo
echo "  ${n_pass} passed, ${n_skip} skipped, ${n_fail} failed"

if [[ $n_fail -gt 0 ]]; then
    echo
    echo "  The gauntlet did not pass. Do not report this change as verified."
    exit 1
fi
if [[ $n_skip -gt 0 ]]; then
    echo
    echo "  Note: ${n_skip} layer(s) did not run. Their results are unknown, not green."
fi
exit 0
