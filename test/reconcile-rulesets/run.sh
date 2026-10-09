#!/usr/bin/env bash
# out and before are read inside the eval strings passed to check.
# shellcheck disable=SC2034
# Tests for scripts/reconcile-rulesets.sh against ./fake-gh.
# Run: bash test/reconcile-rulesets/run.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
pass=0; fail=0
check() { if eval "$2"; then echo "ok   - $1"; pass=$((pass+1)); else echo "FAIL - $1"; fail=$((fail+1)); fi; }

setup() {
  FAKE_DIR=$(mktemp -d); export FAKE_DIR
  bin=$(mktemp -d); cp "$here/fake-gh" "$bin/gh"; export PATH="$bin:$PATH"
  cat > "$FAKE_DIR/repos.json" <<'J'
[{"full_name":"acme/one","archived":false},{"full_name":"acme/two","archived":false},
 {"full_name":"acme/three","archived":false},{"full_name":"acme/free","archived":false},
 {"full_name":"acme/old","archived":true},{"full_name":"acme/settled","archived":false}]
J
  for r in one two settled; do
    n=1; [ "$r" = settled ] && n=0
    echo "[{\"id\":10,\"name\":\"review-gate\",\"source_type\":\"Repository\"},{\"id\":11,\"name\":\"other\",\"source_type\":\"Repository\"}]" > "$FAKE_DIR/$r.list.json"
    cat > "$FAKE_DIR/$r.rs.json" <<J
{"id":10,"name":"review-gate","target":"branch","enforcement":"active","source_type":"Repository","node_id":"X",
 "bypass_actors":[{"actor_id":2740,"actor_type":"Integration","bypass_mode":"pull_request"}],
 "conditions":{"ref_name":{"exclude":[],"include":["~DEFAULT_BRANCH"]}},
 "rules":[{"type":"deletion"},
  {"type":"pull_request","parameters":{"allowed_merge_methods":["squash"],"dismiss_stale_reviews_on_push":true,"require_code_owner_review":false,"require_last_push_approval":false,"required_approving_review_count":$n,"required_review_thread_resolution":true}},
  {"type":"required_status_checks","parameters":{"do_not_enforce_on_create":false,"required_status_checks":[{"context":"CodeRabbit","integration_id":347564}],"strict_required_status_checks_policy":true}},
  {"type":"non_fast_forward"}]}
J
  done
  echo '[]' > "$FAKE_DIR/three.list.json"
  touch "$FAKE_DIR/free.forbidden"
  printf 'rulesets:\n  review_gate:\n    name: review-gate\n    required_approving_review_count: 0\n' > "$FAKE_DIR/settings.yml"
  export GITHUB_STEP_SUMMARY="$FAKE_DIR/summary.md"
}

# 1. dry run writes nothing and reports two changes
setup
out=$(bash "$root/scripts/reconcile-rulesets.sh" --org acme --mode dry-run --policy "$FAKE_DIR/settings.yml")
check "dry run exits 0" true
check "dry run makes no PUT" "[ ! -f \"$FAKE_DIR/puts.log\" ]"
check "dry run reports one and two" "echo \"\$out\" | grep -q 'would set acme/one' && echo \"\$out\" | grep -q 'would set acme/two'"
check "already-0 repo is ok" "echo \"\$out\" | grep -q 'ok        acme/settled (0)'"
check "archived repo skipped" "! echo \"\$out\" | grep -q acme/old"
check "free-plan repo is n/a, not a failure" "echo \"\$out\" | grep -q 'n/a       acme/free'"
check "repo without ruleset is absent" "echo \"\$out\" | grep -q 'absent    acme/three'"

# 2. apply changes the number and nothing else
before=$(jq -S '.rules' "$FAKE_DIR/one.rs.json")
if bash "$root/scripts/reconcile-rulesets.sh" --org acme --mode apply --policy "$FAKE_DIR/settings.yml" > "$FAKE_DIR/apply.out" 2>&1; then rc=0; else rc=$?; fi
check "apply exits 0" "[ $rc = 0 ]"
check "apply PUTs exactly one and two" "[ \"\$(sort \"$FAKE_DIR/puts.log\" | tr '\n' ' ')\" = 'one two ' ]"
check "approvals now 0" "[ \"\$(jq '.rules[] | select(.type==\"pull_request\") | .parameters.required_approving_review_count' \"$FAKE_DIR/one.rs.json\")\" = 0 ]"
check "CodeRabbit check, thread resolution, bypass untouched" "[ \"\$(jq -S '.rules | map(if .type==\"pull_request\" then del(.parameters.required_approving_review_count) else . end)' \"$FAKE_DIR/one.rs.json\")\" = \"\$(echo \"\$before\" | jq -S 'map(if .type==\"pull_request\" then del(.parameters.required_approving_review_count) else . end)')\" ] && jq -e '.bypass_actors[0].actor_id==2740' \"$FAKE_DIR/one.rs.json\" >/dev/null"
check "PUT body has only writable fields" "[ \"\$(jq -c 'keys' \"$FAKE_DIR/one.lastbody.json\")\" = '[\"bypass_actors\",\"conditions\",\"enforcement\",\"name\",\"rules\",\"target\"]' ]"

# 3. second apply is a no-op
rm -f "$FAKE_DIR/puts.log"
bash "$root/scripts/reconcile-rulesets.sh" --org acme --mode apply --policy "$FAKE_DIR/settings.yml" > /dev/null
check "idempotent: no PUT on rerun" "[ ! -f \"$FAKE_DIR/puts.log\" ]"

# 4. silently ignored write is a failure
setup
touch "$FAKE_DIR/one.ignorewrite"
if bash "$root/scripts/reconcile-rulesets.sh" --org acme --mode apply --policy "$FAKE_DIR/settings.yml" > "$FAKE_DIR/o" 2>&1; then rc=0; else rc=$?; fi
check "ignored write exits 1" "[ $rc = 1 ] && grep -q 'read back approvals=1' \"$FAKE_DIR/o\""

# 5. listing error is a failure, not a skip
setup
touch "$FAKE_DIR/two.err"
if bash "$root/scripts/reconcile-rulesets.sh" --org acme --mode dry-run --policy "$FAKE_DIR/settings.yml" > "$FAKE_DIR/o" 2>&1; then rc=0; else rc=$?; fi
check "500 on list exits 1" "[ $rc = 1 ] && grep -q 'could not list rulesets' \"$FAKE_DIR/o\""

# 6. bad usage
setup
if bash "$root/scripts/reconcile-rulesets.sh" --org acme --mode yes --policy "$FAKE_DIR/settings.yml" > /dev/null 2>&1; then rc=0; else rc=$?; fi
check "bad mode exits 2" "[ $rc = 2 ]"
printf 'rulesets:\n  review_gate:\n    required_approving_review_count: one\n' > "$FAKE_DIR/settings.yml"
if bash "$root/scripts/reconcile-rulesets.sh" --org acme --policy "$FAKE_DIR/settings.yml" > /dev/null 2>&1; then rc=0; else rc=$?; fi
check "non-numeric policy exits 2" "[ $rc = 2 ]"

echo; echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
