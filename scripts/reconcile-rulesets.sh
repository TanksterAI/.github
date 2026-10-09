#!/usr/bin/env bash
# reconcile-rulesets.sh -- bring each repository's `review-gate` ruleset in
# line with rulesets.review_gate in settings.yml.
#
# Usage:
#   reconcile-rulesets.sh --org NAME [--mode dry-run|apply] [--policy FILE]
#
# WHY. Every repository carries its own review-gate ruleset (there is no
# org-level one), so changing the policy by hand means editing every repo.
# This makes the policy one line in settings.yml.
#
# WHAT IT MANAGES, and only this: the `pull_request` rule's
# required_approving_review_count inside the ruleset named by
# rulesets.review_gate.name. Every other rule (the CodeRabbit status check,
# review-thread resolution, squash-only, no deletion, no force-push), the
# bypass list, the conditions and the enforcement are copied back unchanged.
#
# required_approving_review_count is 0 because this org has one human, and
# GitHub never lets the author approve their own pull request. With 1 the
# gate can never be satisfied and every merge needs a bypass, and a bypass
# skips ALL rules, the CodeRabbit check and thread resolution included. 0
# keeps those two as the real gate.
#
# A 2xx IS NOT EVIDENCE (see repo-settings-reconcile.yml). Every write is read
# back, and a value that did not move is a failure.
#
# Needs gh, jq, yq and GH_TOKEN with Administration: write on the org's
# repositories (ORG_ADMIN_TOKEN). Exit 0 done; 1 something could not be read
# or written; 2 bad usage.
set -euo pipefail

fail_usage() { echo "::error title=reconcile-rulesets::$*"; exit 2; }

mode=dry-run
org=""
policy=settings.yml
while [ $# -gt 0 ]; do
  case "$1" in
    --org) org="${2:-}"; shift 2 || fail_usage "--org needs a value" ;;
    --mode) mode="${2:-}"; shift 2 || fail_usage "--mode needs a value" ;;
    --policy) policy="${2:-}"; shift 2 || fail_usage "--policy needs a value" ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) fail_usage "unknown argument '$1'" ;;
  esac
done
case "${mode}" in dry-run|apply) ;; *) fail_usage "--mode must be dry-run or apply, not '${mode}'" ;; esac
[ -n "${org}" ] || fail_usage "--org is required"
[ -f "${policy}" ] || fail_usage "${policy} not found"
for dep in gh jq yq; do
  command -v "${dep}" >/dev/null 2>&1 || fail_usage "'${dep}' is required but is not on PATH"
done

name=$(yq -r '.rulesets.review_gate.name // "review-gate"' "${policy}")
want=$(yq -r '.rulesets.review_gate.required_approving_review_count // ""' "${policy}")
case "${want}" in
  ''|*[!0-9]*) fail_usage "rulesets.review_gate.required_approving_review_count must be a whole number, got '${want}'" ;;
esac

summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
echo "reconcile-rulesets: org ${org}, ruleset '${name}', approvals -> ${want}, mode ${mode}"
echo

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

if ! gh api --paginate "orgs/${org}/repos?type=all&per_page=100" \
  --jq '.[] | select(.archived == false) | .full_name' > "${work}/repos"; then
  echo "::error title=reconcile-rulesets::could not list repositories for ${org}"
  exit 1
fi
if [ ! -s "${work}/repos" ]; then
  echo "::error title=reconcile-rulesets::no repositories returned for ${org}; the token probably cannot see them"
  exit 1
fi

total=0; ok=0; changed=0; absent=0; failed=0
rows=""

while IFS= read -r repo <&3; do
  total=$((total + 1))

  # Repository-level rulesets only: an org ruleset is not this job's to edit.
  if ! gh api --paginate "repos/${repo}/rulesets?includes_parents=false&per_page=100" \
    > "${work}/list.json" 2> "${work}/err"; then
    if grep -qiE 'upgrade to github|make this repository public' "${work}/err"; then
      echo "n/a       ${repo} (plan has no rulesets for this repository)"
      absent=$((absent + 1))
      rows="${rows}| ${repo} | n/a | plan has no rulesets |\n"
      continue
    fi
    echo "::warning title=reconcile-rulesets::${repo}: could not list rulesets: $(head -c 200 "${work}/err" | tr '\n' ' ')"
    failed=$((failed + 1))
    rows="${rows}| ${repo} | ? | could not list rulesets |\n"
    continue
  fi

  id=$(jq -s -r --arg n "${name}" 'flatten | map(select(.name == $n and .source_type == "Repository")) | first | .id // empty' "${work}/list.json")
  if [ -z "${id}" ]; then
    echo "absent    ${repo} (no '${name}' ruleset)"
    absent=$((absent + 1))
    rows="${rows}| ${repo} | - | no ${name} ruleset |\n"
    continue
  fi

  if ! gh api "repos/${repo}/rulesets/${id}" > "${work}/rs.json" 2> "${work}/err"; then
    echo "::warning title=reconcile-rulesets::${repo}: could not read ruleset ${id}"
    failed=$((failed + 1))
    rows="${rows}| ${repo} | ? | could not read ruleset ${id} |\n"
    continue
  fi

  have=$(jq -r '[.rules[] | select(.type == "pull_request") | .parameters.required_approving_review_count] | first // "none"' "${work}/rs.json")
  if [ "${have}" = none ]; then
    echo "::warning title=reconcile-rulesets::${repo}: ruleset ${id} has no pull_request rule; left alone"
    absent=$((absent + 1))
    rows="${rows}| ${repo} | - | ${name} has no pull_request rule |\n"
    continue
  fi
  if [ "${have}" = "${want}" ]; then
    echo "ok        ${repo} (${have})"
    ok=$((ok + 1))
    rows="${rows}| ${repo} | ${have} | ok |\n"
    continue
  fi

  if [ "${mode}" != apply ]; then
    echo "would set ${repo} ruleset ${id}: approvals ${have} -> ${want}"
    changed=$((changed + 1))
    rows="${rows}| ${repo} | ${have} -> ${want} | would change |\n"
    continue
  fi

  # The PUT body is the ruleset as read, with one number changed. Only the
  # writable fields are sent; everything else GitHub returns is read-only.
  jq --argjson want "${want}" '{
      name, target, enforcement,
      bypass_actors: (.bypass_actors // []),
      conditions: (.conditions // {}),
      rules: [.rules[] | if .type == "pull_request"
                         then .parameters.required_approving_review_count = $want
                         else . end]
    }' "${work}/rs.json" > "${work}/body.json"

  if ! gh api -X PUT "repos/${repo}/rulesets/${id}" --input "${work}/body.json" --silent 2> "${work}/err"; then
    echo "::warning title=reconcile-rulesets::${repo}: PUT ruleset ${id} failed: $(head -c 200 "${work}/err" | tr '\n' ' ')"
    failed=$((failed + 1))
    rows="${rows}| ${repo} | ${have} | write failed |\n"
    continue
  fi

  # Read back, and check that nothing else moved.
  gh api "repos/${repo}/rulesets/${id}" > "${work}/after.json"
  after=$(jq -r '[.rules[] | select(.type == "pull_request") | .parameters.required_approving_review_count] | first // "none"' "${work}/after.json")
  same_rest=$(jq -n --slurpfile a "${work}/rs.json" --slurpfile b "${work}/after.json" '
      def norm: {enforcement, bypass_actors, conditions,
                 rules: [.rules[] | if .type == "pull_request"
                                    then del(.parameters.required_approving_review_count)
                                    else . end] | sort_by(.type)};
      ($a[0] | norm) == ($b[0] | norm)')
  if [ "${after}" = "${want}" ] && [ "${same_rest}" = true ]; then
    echo "applied   ${repo} ruleset ${id}: approvals ${have} -> ${after}"
    changed=$((changed + 1))
    rows="${rows}| ${repo} | ${have} -> ${after} | applied |\n"
  else
    echo "::warning title=reconcile-rulesets::${repo}: read back approvals=${after}, other rules unchanged=${same_rest}"
    failed=$((failed + 1))
    rows="${rows}| ${repo} | ${have} -> ${after} | read-back mismatch |\n"
  fi
done 3< "${work}/repos"

echo
echo "${total} repositories: ${ok} already ${want}, ${changed} $( [ "${mode}" = apply ] && echo changed || echo 'would change'), ${absent} without the ruleset, ${failed} failed"
{
  echo "### Ruleset reconcile (${mode})"
  echo
  echo "Ruleset \`${name}\`: required approvals -> **${want}**. Every other rule is left as it is."
  echo
  echo "| Repository | Approvals | Result |"
  echo "|---|---|---|"
  printf '%b' "${rows}"
  echo
  echo "${total} repositories, ${ok} ok, ${changed} changed, ${absent} without the ruleset, ${failed} failed."
} >> "${summary}"

[ "${failed}" -eq 0 ] || exit 1
