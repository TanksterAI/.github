#!/usr/bin/env bash
# Scenario tests for repo-settings-reconcile.yml against a mock `gh` (./gh).
# They run the workflow's real `run:` block, extracted with yq, so the code
# tested is the code that ships. Needs bash, jq, yq (v4) and python3.
# Usage: tests/reconcile/test.sh <path-to-this-repository>
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "${1:?path to the repository}" && pwd)
export PATH="${HERE}:${PATH}"
# Files pushed through the API lose their executable bit.
chmod +x "${HERE}/gh"
WORK=${WORK:-$(mktemp -d)}; mkdir -p "$WORK"
yq '.jobs.reconcile.steps[] | select(.name == "Reconcile") | .run' \
  "${SRC}/.github/workflows/repo-settings-reconcile.yml" > "${WORK}/run.sh"
cp "${SRC}/settings.yml" "${WORK}/settings.yml"

pass=0; fail=0
ok()   { echo "  PASS  $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

REPO_OK='{"allow_auto_merge": true, "allow_squash_merge": true, "delete_branch_on_merge": true, "security_and_analysis": {"secret_scanning": {"status": "enabled"}}}'
LEGACY='{"name": "review-gate", "target": "branch", "enforcement": "active", "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}}, "rules": [{"type": "deletion"}]}'
OTHER='{"name": "release-tags", "target": "tag", "enforcement": "active", "conditions": {"ref_name": {"include": ["refs/tags/v*"], "exclude": []}}, "rules": [{"type": "deletion"}]}'

# Fresh estate: no org rulesets, hand-made review-gate copies on two repos,
# one unrelated repo ruleset, one repo with a settings drift.
fresh_state() {
  jq -n --argjson ok "${REPO_OK}" --argjson legacy "${LEGACY}" --argjson other "${OTHER}" '{
    org: {rulesets: {}},
    repos: {
      "TanksterAI/alpha": {settings: $ok, rulesets: {"101": $legacy, "102": $other}},
      "TanksterAI/beta":  {settings: $ok, rulesets: {"201": $legacy}},
      "TanksterAI/gamma": {settings: ($ok + {delete_branch_on_merge: false}), rulesets: {}}
    }}' > "${WORK}/state.json"
  : > "${WORK}/state.json.log"
}

# Run the reconciler. $1 = dry-run true|false. Sets RC and OUT.
run() {
  : > "${WORK}/summary.md"
  OUT=$(cd "${WORK}" && GH_TOKEN=x ORG=TanksterAI GITHUB_EVENT_NAME=test DRY_RUN="$1" \
        GITHUB_STEP_SUMMARY="${WORK}/summary.md" MOCK_STATE="${WORK}/state.json" \
        bash -e run.sh 2>&1); RC=$?
  echo "${OUT}" > "${WORK}/last.out"
}
writes()  { grep -cE '^(POST|PUT|PATCH|DELETE) ' "${WORK}/state.json.log" || true; }
deletes() { grep -cE '^DELETE .*/rulesets/' "${WORK}/state.json.log" || true; }
st()      { jq -r "$1" "${WORK}/state.json"; }
org_rs()  { st "[.org.rulesets[] | select(.name == \"$1\")] | first"; }
out_has() { grep -qF -- "$1" <<< "${OUT}"; }

echo "== 1. dry run"
fresh_state; before=$(cat "${WORK}/state.json")
run true
check "exits 0" '[ "$RC" = 0 ]'
check "reports org review-gate create" 'out_has "drift     org ruleset review-gate: create"'
check "reports org ci-gate create" 'out_has "drift     org ruleset ci-gate: create"'
check "reports the settings drift" 'out_has "drift     TanksterAI/gamma: merge:{\"delete_branch_on_merge\":true}"'
check "no writes of any kind" '[ "$(writes)" = 0 ]'
check "state untouched" '[ "$(cat "${WORK}/state.json")" = "${before}" ]'
check "legacy kept: org ruleset not verified" 'out_has "repository rulesets named review-gate are kept"'

echo "== 2. org ruleset create (apply)"
fresh_state
run false
check "exits 0" '[ "$RC" = 0 ]'
check "review-gate created, active" '[ "$(org_rs review-gate | jq -r .enforcement)" = active ]'
check "ci-gate created, disabled" '[ "$(org_rs ci-gate | jq -r .enforcement)" = disabled ]'
check "targets ~ALL repos, no exclude" '[ "$(org_rs review-gate | jq -c .conditions.repository_name)" = "{\"include\":[\"~ALL\"],\"exclude\":[],\"protected\":false}" ]'
check "targets ~DEFAULT_BRANCH" '[ "$(org_rs review-gate | jq -c .conditions.ref_name)" = "{\"include\":[\"~DEFAULT_BRANCH\"],\"exclude\":[]}" ]'
check "CodeRabbit check pinned to 347564" '[ "$(org_rs review-gate | jq -c "[.rules[] | select(.type==\"required_status_checks\") | .parameters.required_status_checks[]]")" = "[{\"context\":\"CodeRabbit\",\"integration_id\":347564}]" ]'
check "strict" '[ "$(org_rs review-gate | jq "[.rules[] | select(.type==\"required_status_checks\")][0].parameters.strict_required_status_checks_policy")" = true ]'
check "pull_request: 1 approval, dismiss stale, threads, squash" '[ "$(org_rs review-gate | jq -c "[.rules[] | select(.type==\"pull_request\")][0].parameters | [.required_approving_review_count, .dismiss_stale_reviews_on_push, .required_review_thread_resolution, .allowed_merge_methods]")" = "[1,true,true,[\"squash\"]]" ]'
check "deletion + non_fast_forward" '[ "$(org_rs review-gate | jq -c "[.rules[].type] | sort")" = "[\"deletion\",\"non_fast_forward\",\"pull_request\",\"required_status_checks\"]" ]'
check "bypass: renovate 2740, pull_request mode only" '[ "$(org_rs review-gate | jq -c .bypass_actors)" = "[{\"actor_id\":2740,\"actor_type\":\"Integration\",\"bypass_mode\":\"pull_request\"}]" ]'
check "ci-gate check pinned to github-actions 15368" '[ "$(org_rs ci-gate | jq -c "[.rules[] | .parameters.required_status_checks[]]")" = "[{\"context\":\"ci-gate\",\"integration_id\":15368}]" ]'
check "ci-gate has no bypass" '[ "$(org_rs ci-gate | jq -c .bypass_actors)" = "[]" ]'
check "legacy review-gate retired on alpha" '[ "$(st "[.repos[\"TanksterAI/alpha\"].rulesets[] | select(.name==\"review-gate\")] | length")" = 0 ]'
check "legacy review-gate retired on beta" '[ "$(st ".repos[\"TanksterAI/beta\"].rulesets | length")" = 0 ]'
check "differently named repo ruleset untouched" '[ "$(st ".repos[\"TanksterAI/alpha\"].rulesets[\"102\"].name")" = release-tags ]'
check "exactly two deletes, both review-gate ids" '[ "$(grep -E "^DELETE .*/rulesets/" "${WORK}/state.json.log" | sort | tr "\n" " ")" = "DELETE repos/TanksterAI/alpha/rulesets/101 DELETE repos/TanksterAI/beta/rulesets/201 " ]'
first_delete=$(grep -nE '^DELETE .*/rulesets/' "${WORK}/state.json.log" | head -1 | cut -d: -f1)
last_org=$(grep -nE ' orgs/TanksterAI/rulesets' "${WORK}/state.json.log" | tail -1 | cut -d: -f1)
check "every delete comes after the org read-back" '[ "${first_delete}" -gt "${last_org}" ]'
check "settings drift repaired alongside" '[ "$(st ".repos[\"TanksterAI/gamma\"].settings.delete_branch_on_merge")" = true ]'
check "summary table lists both org rulesets" 'grep -q "| \`review-gate\` | created |" "${WORK}/summary.md" && grep -q "| \`ci-gate\` | created |" "${WORK}/summary.md"'

echo "== 3. idempotent re-run"
: > "${WORK}/state.json.log"
run false
check "exits 0" '[ "$RC" = 0 ]'
check "no writes" '[ "$(writes)" = 0 ]'
check "review-gate ok" 'out_has "ok        org ruleset review-gate (active)"'
check "ci-gate ok" 'out_has "ok        org ruleset ci-gate (disabled)"'
check "all repos ok" '[ "$(grep -c "^ok        TanksterAI/" <<< "${OUT}")" = 3 ]'

echo "== 4. drift repair"
# Someone, in the UI: excludes main, adds a property filter, drops the
# CodeRabbit check and Renovate's bypass, and switches ci-gate on early.
jq '.org.rulesets |= with_entries(
      if .value.name == "review-gate" then
        .value.conditions.ref_name.exclude = ["refs/heads/main"]
        | .value.conditions.repository_property = {include: [{name: "tier", property_values: ["x"]}], exclude: []}
        | .value.rules |= map(select(.type != "required_status_checks"))
        | .value.bypass_actors = [{actor_id: 1, actor_type: "OrganizationAdmin", bypass_mode: "always"}]
      else .value.enforcement = "active" end)' "${WORK}/state.json" > "${WORK}/t" && mv "${WORK}/t" "${WORK}/state.json"
: > "${WORK}/state.json.log"
run true
check "dry run: both reported as update" 'out_has "drift     org ruleset review-gate: update" && out_has "drift     org ruleset ci-gate: update"'
check "dry run: no writes" '[ "$(writes)" = 0 ]'
run false
check "exits 0" '[ "$RC" = 0 ]'
check "PUT to both" '[ "$(grep -c "^PUT orgs/TanksterAI/rulesets/" "${WORK}/state.json.log")" = 2 ]'
check "exclude repaired" '[ "$(org_rs review-gate | jq -c .conditions.ref_name.exclude)" = "[]" ]'
check "property filter removed" '[ "$(org_rs review-gate | jq -c .conditions.repository_property)" = null ]'
check "CodeRabbit check restored" '[ "$(org_rs review-gate | jq "[.rules[] | select(.type==\"required_status_checks\")] | length")" = 1 ]'
check "bypass restored to renovate only" '[ "$(org_rs review-gate | jq -c "[.bypass_actors[].actor_id]")" = "[2740]" ]'
check "ci-gate back to disabled" '[ "$(org_rs ci-gate | jq -r .enforcement)" = disabled ]'
: > "${WORK}/state.json.log"; run false
check "converged afterwards" '[ "$RC" = 0 ] && [ "$(writes)" = 0 ]'

echo "== 5. NEEDS-ORG-ADMIN (403 on /orgs/{org}/rulesets)"
fresh_state
jq '.org.deny = 403' "${WORK}/state.json" > "${WORK}/t" && mv "${WORK}/t" "${WORK}/state.json"
run false
check "exits 0 (not a failure)" '[ "$RC" = 0 ]'
check "reports NEEDS-ORG-ADMIN clearly" 'out_has "::warning title=NEEDS-ORG-ADMIN::" && out_has "blocked   org ruleset review-gate: list(NEEDS-ORG-ADMIN)"'
check "repo settings still reconciled" '[ "$(st ".repos[\"TanksterAI/gamma\"].settings.delete_branch_on_merge")" = true ]'
check "no legacy ruleset deleted" '[ "$(deletes)" = 0 ] && [ "$(st ".repos[\"TanksterAI/beta\"].rulesets | length")" = 1 ]'
check "summary shows NEEDS-ORG-ADMIN" 'grep -q "| \`review-gate\` | NEEDS-ORG-ADMIN |" "${WORK}/summary.md"'

echo "== 5b. NEEDS-ORG-ADMIN (404)"
fresh_state
jq '.org.deny = 404' "${WORK}/state.json" > "${WORK}/t" && mv "${WORK}/t" "${WORK}/state.json"
run false
check "exits 0, NEEDS-ORG-ADMIN, no deletes" '[ "$RC" = 0 ] && out_has "NEEDS-ORG-ADMIN" && [ "$(deletes)" = 0 ]'

echo "== 5c. NEEDS-ORG-ADMIN (read allowed, write 403)"
fresh_state
jq '.org.deny_write = 403' "${WORK}/state.json" > "${WORK}/t" && mv "${WORK}/t" "${WORK}/state.json"
run false
check "exits 0, create(NEEDS-ORG-ADMIN), no deletes" '[ "$RC" = 0 ] && out_has "blocked   org ruleset review-gate: create(NEEDS-ORG-ADMIN)" && out_has "::warning title=NEEDS-ORG-ADMIN::" && [ "$(deletes)" = 0 ]'

echo "== 6. PLAN-BLOCKED"
fresh_state
jq '.org.plan_blocked = true' "${WORK}/state.json" > "${WORK}/t" && mv "${WORK}/t" "${WORK}/state.json"
run false
check "exits 0, PLAN-BLOCKED, no deletes" '[ "$RC" = 0 ] && out_has "blocked   org ruleset review-gate: list(PLAN-BLOCKED)" && [ "$(deletes)" = 0 ]'

echo "== 6b. a failed org ruleset read never stops the run"
# Existing org ruleset, list allowed, GET of the ruleset refused (403).
fresh_state; run false >/dev/null
jq --argjson legacy "${LEGACY}" '.org.deny_get = 403 | .repos["TanksterAI/beta"].rulesets["203"] = $legacy
   | .repos["TanksterAI/gamma"].settings.delete_branch_on_merge = false' "${WORK}/state.json" > "${WORK}/t" && mv "${WORK}/t" "${WORK}/state.json"
: > "${WORK}/state.json.log"
run false
check "lookup 403: exit 0, read(NEEDS-ORG-ADMIN)" '[ "$RC" = 0 ] && out_has "blocked   org ruleset review-gate: read(NEEDS-ORG-ADMIN)" && out_has "::warning title=NEEDS-ORG-ADMIN::"'
check "lookup 403: repos still reconciled" '[ "$(st ".repos[\"TanksterAI/gamma\"].settings.delete_branch_on_merge")" = true ] && out_has "3 repositories"'
check "lookup 403: nothing retired" '[ "$(deletes)" = 0 ]'
jq '.org.deny_get = 500 | .repos["TanksterAI/gamma"].settings.delete_branch_on_merge = false' "${WORK}/state.json" > "${WORK}/t" && mv "${WORK}/t" "${WORK}/state.json"
run false
check "lookup 500: exit 1 (a real failure), repos still reconciled" '[ "$RC" = 1 ] && out_has "read(FAILED)" && [ "$(st ".repos[\"TanksterAI/gamma\"].settings.delete_branch_on_merge")" = true ]'
check "lookup 500: nothing retired" '[ "$(deletes)" = 0 ]'
# Fresh estate: the create succeeds, the read-back GET fails.
fresh_state
jq '.org.deny_get = 500' "${WORK}/state.json" > "${WORK}/t" && mv "${WORK}/t" "${WORK}/state.json"
run false
check "read-back 500: exit 1, reported, repos reconciled" '[ "$RC" = 1 ] && out_has "blocked   org ruleset review-gate: read back after create(FAILED)" && [ "$(st ".repos[\"TanksterAI/gamma\"].settings.delete_branch_on_merge")" = true ]'
check "read-back 500: not verified, nothing retired" '[ "$(deletes)" = 0 ] && out_has "repository rulesets named review-gate are kept"'

echo "== 7. read-back mismatch: no retirement"
fresh_state
jq '.org.drop_bypass = true' "${WORK}/state.json" > "${WORK}/t" && mv "${WORK}/t" "${WORK}/state.json"
run false
check "exits 1 (NOT-APPLIED is a failure)" '[ "$RC" = 1 ] && out_has "org ruleset review-gate was accepted but does not match the policy"'
check "no legacy ruleset deleted" '[ "$(deletes)" = 0 ]'

echo "== 8. retirement guards"
# Org review-gate already live and matching (state from scenario 3), legacy copies re-added.
fresh_state; run false >/dev/null
jq --argjson legacy "${LEGACY}" '.repos["TanksterAI/alpha"].rulesets["103"] = $legacy
   | .repos["TanksterAI/beta"].rulesets["202"] = $legacy
   | .repos["TanksterAI/beta"].org_not_visible = true' "${WORK}/state.json" > "${WORK}/t" && mv "${WORK}/t" "${WORK}/state.json"
: > "${WORK}/state.json.log"
run true; cp "${WORK}/last.out" "${WORK}/s8-dry.out"
check "dry run: retirement reported" 'out_has "drift     TanksterAI/alpha: legacy-ruleset:review-gate:retire"'
check "dry run: nothing deleted" '[ "$(deletes)" = 0 ] && [ "$(st ".repos[\"TanksterAI/alpha\"].rulesets | length")" = 2 ]'
run false
check "alpha copy retired" '[ "$(st ".repos[\"TanksterAI/alpha\"].rulesets | keys | join(\",\")")" = 102 ]'
check "beta copy kept: org ruleset not listed there" '[ "$(st ".repos[\"TanksterAI/beta\"].rulesets | length")" = 1 ] && out_has "TanksterAI/beta: repository ruleset review-gate kept"'
check "release-tags untouched throughout" '[ "$(st ".repos[\"TanksterAI/alpha\"].rulesets[\"102\"].name")" = release-tags ]'

echo "== 9. ci-gate active never retires anything by itself"
# ci-gate has no retire_repo_rulesets: a repo ruleset named ci-gate survives even when the org ci-gate is active and verified.
cp "${WORK}/settings.yml" "${WORK}/settings.yml.bak"
yq -i '.org_rulesets.ci-gate.enforcement = "active"' "${WORK}/settings.yml"
jq '.repos["TanksterAI/gamma"].rulesets["301"] = {name: "ci-gate", target: "branch", enforcement: "active", conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}}, rules: []}' "${WORK}/state.json" > "${WORK}/t" && mv "${WORK}/t" "${WORK}/state.json"
run false
check "repo ruleset ci-gate untouched" '[ "$(st ".repos[\"TanksterAI/gamma\"].rulesets[\"301\"].name")" = ci-gate ]'
mv "${WORK}/settings.yml.bak" "${WORK}/settings.yml"

echo "== 10. policy validation and slug resolution"
fresh_state
cp "${WORK}/settings.yml" "${WORK}/settings.yml.bak"
yq -i 'del(.org_rulesets.review-gate.repositories)' "${WORK}/settings.yml"
run false
check "missing repositories: exits 1 before any write" '[ "$RC" = 1 ] && [ "$(writes)" = 0 ] && out_has "org_rulesets entries need"'
cp "${WORK}/settings.yml.bak" "${WORK}/settings.yml"
yq -i '.org_rulesets.review-gate.bypass_apps = ["no-such-app"]' "${WORK}/settings.yml"
run false
check "unknown app slug: exits 1 before any write" '[ "$RC" = 1 ] && [ "$(writes)" = 0 ] && out_has "cannot resolve GitHub App '"'"'no-such-app'"'"'"'
mv "${WORK}/settings.yml.bak" "${WORK}/settings.yml"

set_state() { jq "$1" "${WORK}/state.json" > "${WORK}/t" && mv "${WORK}/t" "${WORK}/state.json"; }
SRC_OK='{"id": 900, "private": true, "access_level": "organization", "files": [".github/workflows/org-auto-merge.yml"], "ref": "refs/heads/main"}'

echo "== 11. auto-merge (required workflow) and long-lived-branches"
fresh_state
run false
check "exits 0" '[ "$RC" = 0 ]'
check "auto-merge created, active" '[ "$(org_rs auto-merge | jq -r .enforcement)" = active ]'
check "auto-merge: one workflows rule only" '[ "$(org_rs auto-merge | jq -c "[.rules[].type]")" = "[\"workflows\"]" ]'
check "auto-merge: workflow is .github (id 900) org-auto-merge.yml at main" '[ "$(org_rs auto-merge | jq -c "[.rules[0].parameters.workflows[] | {path, repository_id, ref}]")" = "[{\"path\":\".github/workflows/org-auto-merge.yml\",\"repository_id\":900,\"ref\":\"refs/heads/main\"}]" ]'
check "auto-merge: branch creation not blocked" '[ "$(org_rs auto-merge | jq .rules[0].parameters.do_not_enforce_on_create)" = true ]'
check "auto-merge: ~ALL on ~DEFAULT_BRANCH, no bypass" '[ "$(org_rs auto-merge | jq -c "[.conditions.repository_name.include, .conditions.ref_name.include, .bypass_actors]")" = "[[\"~ALL\"],[\"~DEFAULT_BRANCH\"],[]]" ]'
check "long-lived-branches: deletion only, no bypass" '[ "$(org_rs long-lived-branches | jq -c "[[.rules[].type], .bypass_actors, .enforcement]")" = "[[\"deletion\"],[],\"active\"]" ]'
check "long-lived-branches: main, master, develop, release/**" '[ "$(org_rs long-lived-branches | jq -c ".conditions.ref_name.include | sort")" = "[\"refs/heads/develop\",\"refs/heads/main\",\"refs/heads/master\",\"refs/heads/release/**/*\"]" ]'
check "long-lived-branches: every repository" '[ "$(org_rs long-lived-branches | jq -c .conditions.repository_name.include)" = "[\"~ALL\"]" ]'
check "summary lists both as created" 'grep -q "| \`auto-merge\` | created |" "${WORK}/summary.md" && grep -q "| \`long-lived-branches\` | created |" "${WORK}/summary.md"'
check "no public-repo warning while all are private" '! out_has "PUBLIC-REPOS"'
: > "${WORK}/state.json.log"; run false
check "converged: GitHub's sha:null default is not drift" '[ "$RC" = 0 ] && [ "$(writes)" = 0 ] && out_has "ok        org ruleset auto-merge (active)" && out_has "ok        org ruleset long-lived-branches (active)"'

echo "== 12. workflow rule drift repaired"
set_state '.org.rulesets |= with_entries(if .value.name == "auto-merge" then .value.rules[0].parameters.workflows[0].ref = "refs/heads/some-branch" else . end)
  | .org.rulesets |= with_entries(if .value.name == "long-lived-branches" then .value.conditions.ref_name.include = ["refs/heads/main"] else . end)'
: > "${WORK}/state.json.log"; run false
check "exits 0, two PUTs" '[ "$RC" = 0 ] && [ "$(grep -c "^PUT orgs/TanksterAI/rulesets/" "${WORK}/state.json.log")" = 2 ]'
check "workflow ref back to main" '[ "$(org_rs auto-merge | jq -r .rules[0].parameters.workflows[0].ref)" = refs/heads/main ]'
check "long-lived branch list restored" '[ "$(org_rs long-lived-branches | jq ".conditions.ref_name.include | length")" = 4 ]'

echo "== 13. a required workflow that cannot run is never required"
for case in "access none|.source.access_level = \"none\"|Access: none" \
            "access unreadable|.source.access_level = null|Access: unreadable" \
            "file missing|.source.files = []|is not found at refs/heads/main" \
            "file only on another ref|.source.ref = \"refs/heads/other\"|is not found at refs/heads/main" \
            "contents unreadable|.source.contents_denied = true|could not check .github/.github/workflows/org-auto-merge.yml"; do
  IFS='|' read -r label mutate expect <<< "${case}"
  fresh_state; set_state ".source = ${SRC_OK} | ${mutate}"
  run false
  check "${label}: exit 1, reported" '[ "$RC" = 1 ] && out_has "::warning title=WORKFLOW-UNREACHABLE::org ruleset auto-merge left as it is" && out_has "${expect}"'
  check "${label}: auto-merge not written" '[ "$(org_rs auto-merge)" = null ]'
  check "${label}: other rulesets and repos still reconciled" '[ "$(org_rs review-gate | jq -r .enforcement)" = active ] && [ "$(org_rs long-lived-branches | jq -r .enforcement)" = active ] && [ "$(st ".repos[\"TanksterAI/gamma\"].settings.delete_branch_on_merge")" = true ]'
  check "${label}: summary says UNREACHABLE" 'grep -q "| \`auto-merge\` | UNREACHABLE |" "${WORK}/summary.md"'
done
fresh_state; set_state ".source = ${SRC_OK} | .source.access_level = \"none\""
run true
check "dry run: unreachable reported, exit 0, no writes" '[ "$RC" = 0 ] && out_has "WORKFLOW-UNREACHABLE" && [ "$(writes)" = 0 ]'
fresh_state; set_state ".source = ${SRC_OK} | .source.private = false | .source.access_level = \"none\""
run false
check "public source: access setting not needed, created" '[ "$RC" = 0 ] && [ "$(org_rs auto-merge | jq -r .enforcement)" = active ]'
# Already live and matching, then the file disappears: left alone, loudly.
fresh_state; run false >/dev/null
set_state ".source = ${SRC_OK} | .source.files = []"
: > "${WORK}/state.json.log"; run false
check "live ruleset, file gone: exit 1, no org writes, ruleset kept" '[ "$RC" = 1 ] && [ "$(grep -cE "^(PUT|POST|DELETE) orgs/" "${WORK}/state.json.log")" = 0 ] && [ "$(org_rs auto-merge | jq -r .enforcement)" = active ]'

echo "== 14. public repository while the workflow source is private"
fresh_state; set_state '.repos["TanksterAI/alpha"].private = false'
run false
check "exit 0, warning names the public repo" '[ "$RC" = 0 ] && out_has "::warning title=PUBLIC-REPOS::" && out_has "TanksterAI/alpha"'
fresh_state; set_state ".source = ${SRC_OK} | .source.private = false | .repos[\"TanksterAI/alpha\"].private = false"
run false
check "public source: no warning" '[ "$RC" = 0 ] && ! out_has "PUBLIC-REPOS"'

echo "== 15. unknown workflow repository"
fresh_state
cp "${WORK}/settings.yml" "${WORK}/settings.yml.bak"
yq -i '.org_rulesets.auto-merge.required_workflows[0].repository = "no-such-repo"' "${WORK}/settings.yml"
run false
check "exits 1 before any write" '[ "$RC" = 1 ] && [ "$(writes)" = 0 ] && out_has "cannot resolve repository '"'"'TanksterAI/no-such-repo'"'"'"'
mv "${WORK}/settings.yml.bak" "${WORK}/settings.yml"

echo "== 16. disabled ruleset with a workflow is not preflighted"
fresh_state; set_state ".source = ${SRC_OK} | .source.files = []"
cp "${WORK}/settings.yml" "${WORK}/settings.yml.bak"
yq -i '.org_rulesets.auto-merge.enforcement = "disabled"' "${WORK}/settings.yml"
run false
check "written disabled, exit 0" '[ "$RC" = 0 ] && [ "$(org_rs auto-merge | jq -r .enforcement)" = disabled ]'
mv "${WORK}/settings.yml.bak" "${WORK}/settings.yml"

echo
echo "${pass} passed, ${fail} failed"
[ "${fail}" = 0 ]
