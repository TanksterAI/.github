#!/usr/bin/env bash
# Scenario tests for org-auto-merge.yml's run block against a mock `gh`
# (./gh). Extracted with yq, so the code tested is the code that ships.
# Needs bash, jq and yq (v4).
# Usage: tests/org-auto-merge/test.sh <path-to-this-repository>
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); SRC=$(cd "${1:?path to the repository}" && pwd)
export PATH="${HERE}:${PATH}"
# Files pushed through the API lose their executable bit.
chmod +x "${HERE}/gh"
W=$(mktemp -d); yq '.jobs.arm.steps[] | select(.name == "Arm or disarm auto-merge") | .run' \
  "${SRC}/.github/workflows/org-auto-merge.yml" > "${W}/run.sh"
pass=0; fail=0
check() { if eval "$2"; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1"; echo "        out: ${OUT}"; fail=$((fail+1)); fi; }
GATED='[{"type":"pull_request","parameters":{"required_approving_review_count":1}},
        {"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"CodeRabbit"},{"context":"ci-gate"}]}},
        {"type":"workflows","parameters":{"workflows":[]}}]'
REVIEW_ONLY='[{"type":"pull_request","parameters":{"required_approving_review_count":1}},
        {"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"CodeRabbit"}]}}]'
CI_NO_REVIEW='[{"type":"pull_request","parameters":{"required_approving_review_count":0}},
        {"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"image"}]}}]'
run() { # env overrides as args
  : > "${W}/calls"; : > "${W}/summary"
  OUT=$(env STATE=open DRAFT=false AUTHOR_TYPE=User OPTED_OUT=false PR=https://x/pr/1 REPO=o/r HEAD_REPO=o/r BASE=main \
        TOKEN_KIND=GITHUB_TOKEN RULES_JSON="${GATED}" CALLS="${W}/calls" GITHUB_STEP_SUMMARY="${W}/summary" "$@" \
        bash "${W}/run.sh" 2>&1); RC=$?
}
armed()    { grep -q -- "pr merge .* --auto --squash" "${W}/calls"; }
disarmed() { grep -q -- "--disable-auto" "${W}/calls"; }
has()      { grep -qF -- "$1" <<< "${OUT}"; }

run;                                   check "gated base: armed"                    '[ $RC = 0 ] && armed && has "Armed with GITHUB_TOKEN" && has "(ci-gate)"'
check "summary written"                'grep -q "Armed" "${W}/summary"'
run RULES_JSON="${REVIEW_ONLY}";       check "review but no CI: not armed, disarmed" '[ $RC = 0 ] && ! armed && disarmed && has "CI check besides CodeRabbit (it requires: none)"'
run RULES_JSON="${CI_NO_REVIEW}";      check "CI but no approval: not armed"         '[ $RC = 0 ] && ! armed && disarmed && has "(it requires 0)"'
run RULES_JSON='[]';                   check "no rules at all: not armed"            '[ $RC = 0 ] && ! armed && disarmed'
run RULES_FAIL=1;                      check "rules unreadable: disarmed, not armed, exit 0" '[ $RC = 0 ] && ! armed && disarmed && has "could not read the rules"'
run HEAD_REPO=someone/r;               check "fork: nothing called, exit 0"          '[ $RC = 0 ] && [ ! -s "${W}/calls" ] && has "from a fork"'
run DRAFT=true;                        check "draft: nothing called"                 '[ $RC = 0 ] && [ ! -s "${W}/calls" ]'
run AUTHOR_TYPE=Bot;                   check "bot: nothing called"                   '[ $RC = 0 ] && [ ! -s "${W}/calls" ]'
run STATE=closed;                      check "closed: nothing called"                '[ $RC = 0 ] && [ ! -s "${W}/calls" ]'
run OPTED_OUT=true;                    check "label: disarmed, not armed"            '[ $RC = 0 ] && disarmed && ! armed'
run ARMED=true;                        check "already armed: no second arm"          '[ $RC = 0 ] && ! armed && has "Already armed"'
run MERGE_FAIL=1;                      check "GitHub refuses: warning, exit 0"       '[ $RC = 0 ] && has "::warning::could not arm auto-merge" && has "Merge by hand"'
run TOKEN_KIND="merge App";            check "App token reported"                    'has "Armed with merge App"'
run BASE="release/2026.10";            check "base with a slash is sent encoded"     'grep -q "rules/branches/release%2F2026.10" "${W}/calls" && armed'
echo; echo "${pass} passed, ${fail} failed"; rm -rf "${W}"; [ "${fail}" = 0 ]
