# Shared CI

Reusable GitHub Actions workflows and Renovate presets for every repository under this account.

The point is that CI lives in one place. A repo that adopts these gets a caller
workflow of roughly fifteen lines instead of a hundred-and-fifty-line `ci.yml`
that drifts away from its siblings the moment someone fixes a bug in one copy
and not the other four.

## Using a workflow

```yaml
# .github/workflows/ci.yml in a consuming repo
name: ci

on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:

# Cancel superseded runs. This belongs in the caller, not the reusable
# workflow, because the group has to be keyed on the caller's ref.
concurrency:
  group: ci-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  ci:
    uses: TanksterAI/.github/.github/workflows/python-ci.yml@v1
    with:
      python-version: "3.12"
      verify: python verify.py
```

The doubled `.github/.github/` is not a typo: the first is the repository name,
the second is the directory inside it.

Pin to `@v1`. That tag moves forward as these workflows improve, so consuming
repos pick up fixes without a PR each. Pin to a commit SHA instead if a repo
needs to be insulated from that.

## Available workflows

| Workflow | For | Notable |
|---|---|---|
| `python-ci.yml` | Python | ruff + optional mypy + your `verify.py` gate; optional graceful checkout of a private sibling repo |
| `node-ci.yml` | Node / TypeScript | npm or pnpm, single job, `.nvmrc` as the version source of truth |
| `rust-ci.yml` | Rust | fmt, clippy `-D warnings`, test, release build, and the no-panics-in-production gate |
| `security.yml` | any | osv-scanner + gitleaks + ecosystem audit |
| `lighthouse-ci.yml` | Node / web frontends | `lhci autorun` against a locally built app, plus a sticky PR comment with the score table; advisory by default |
| `lockfile.yml` | Node / TypeScript | `workflow_dispatch` lockfile regeneration that proves the result before committing |
| `workflows-lint.yml` | any | actionlint over `.github/workflows/`, self-updating and cached |
| `claude-review.yml` | any | Claude posts inline line-level PR review comments -- **retired 30 Aug 2026**, no active callers; CodeRabbit Pro is now the org's sole PR reviewer (see "The agent pipeline" below). Kept in the repo, unused, in case that changes |
| `claude-address-feedback.yml` | any | Claude reads unresolved review threads (CodeRabbit + its own), fixes, resolves, pushes |
| `org-auto-merge.yml` | any | **Not called by anyone.** The `auto-merge` org ruleset requires it, so GitHub runs it on every PR in every repository. Turns on auto-merge only where the base branch requires an approval and CI; never merges itself, and its own decisions never block a PR (a failed run does) |
| `auto-merge-gate.yml` | any | The per-repo predecessor of `org-auto-merge.yml`: callers can drop it once the `auto-merge` org ruleset is live |

Every job sets `timeout-minutes` and a least-privilege `permissions` block.
Callers still need their own `permissions` block, because the caller's grant is
the ceiling for everything it calls.

### Where jobs run

Every job here runs on `${{ vars.CI_RUNNER || 'ubuntu-latest' }}`, and the
reusable workflows' `runs-on` input defaults to the same. `CI_RUNNER` is an
organisation variable: `ubuntu-latest` while the organisation's included
Actions minutes last, and `tankster-gcb` -- one-job runners on Google Cloud
Build's free tier -- once they run out. A dispatcher flips it automatically
and flips it back when the minutes reset; how that works, and what differs on
those runners, is in `ci/fallback-runner/README.md` in `tankster-infra`.

A consuming repo's own inline jobs should use the same expression, so the
whole estate moves together. Passing `runs-on` explicitly still pins a job to
one runner.

### Advisory-first inputs

`python-ci.yml` takes `lint-strict`, `security.yml` takes `audit-strict`,
`lighthouse-ci.yml` takes `strict`. All three default to `false`, so a repo
that has never been linted, audited, or Lighthouse-checked can adopt these
today without a wall of red. They print a step summary (or, for Lighthouse, a
PR comment) saying so.

Leaving them `false` forever is how a quality gate becomes decoration. Clear the
backlog, flip the flag.

`lighthouse-ci.yml` doesn't set its own performance/accessibility/SEO budgets --
those live in the consuming repo's own `lighthouserc.json` (or `.js`/`.cjs`),
which `lhci autorun` discovers on its own. See `lighthouserc.example.json` in
this repository for a starting point. A repo that wants "advisory on PRs,
blocking on protected branches" rather than one fixed value can compute
`strict` from the triggering event instead of hardcoding it:
`strict: ${{ github.event_name != 'pull_request' }}`.

The agent pipeline below (`claude-address-feedback`, `auto-merge-gate`, and
CodeRabbit Pro as the reviewer leg) deliberately does **not** follow this
advisory-first pattern -- it went live org-wide from day one, at the account
owner's explicit instruction, rather than proving itself on one repo first.
Said here so the inconsistency with every other workflow in this file reads as
a deliberate choice, not an oversight.

## The agent pipeline

`claude-address-feedback.yml` and `org-auto-merge.yml`, together with
CodeRabbit Pro as the org's PR reviewer (installed and licensed separately
at the organisation level -- not a workflow in this repo), let a PR go from
opened to merged with no human review, by default, org-wide:

1. **Open a PR.** CodeRabbit Pro posts its line-by-line review and
   merge-risk summary. `claude-review.yml` used to also post inline
   comments here; it was retired 30 Aug 2026 once CodeRabbit Pro closed a
   confirmed gap in Claude's then-current review configuration (no
   linter/SAST signal reached it, among other things) more cheaply than
   building that wiring in-house would have. Full comparison in
   `claude/coderabbit-pro-verdict.md`, Tankster AI project.
2. **Feedback arrives.** `claude-address-feedback.yml` fires on CodeRabbit's
   comments, fixes what's real, resolves the thread, replies to what it
   disputes, and pushes -- which re-triggers CI and a fresh CodeRabbit pass,
   and the cycle repeats until nothing is left to flag.
3. **`org-auto-merge.yml`** enables `gh pr merge --auto` on the PR when it
   is opened and on every push (unless it is a draft, a bot's PR, a PR from
   a fork, or carries `needs-human-review`). No repository calls it: the
   `auto-merge` org ruleset requires it, so GitHub runs it everywhere, in
   repositories that don't exist yet too. It arms only where the base
   branch's rules require an approval and a CI check besides CodeRabbit's.
   Its script exits 0 on every path it handles (armed, not armed, disarmed,
   GitHub refusing), so its own decisions never block a PR. The run itself
   can still fail, and then it blocks the merge like any failed required
   check: see "A failed `arm` run blocks the merge" below.
4. **The review gate** is what actually lets GitHub complete the merge.
   Neither workflow above ever calls merge itself. The gate is the
   `review-gate` **organisation ruleset** declared under `org_rulesets:` in
   `settings.yml`, which `repo-settings-reconcile.yml` writes once, to the
   org. It targets every repository (`~ALL`) on its default branch, so a new
   repository is covered the moment it exists, and neither file names a
   repository. It requires:
   - one approval, dismissed by any later push. In practice that is
     CodeRabbit's approval of the latest commit;
   - every review conversation resolved;
   - the `CodeRabbit` check green, pinned to the CodeRabbit app, on a branch
     that is up to date with its base;
   - squash merges only, no force-push, no deleting the branch;
   - no bypass for people, admins included. Only Renovate may merge its own
     PRs past it, in `pull_request` mode, because CodeRabbit won't review bot
     PRs. That works only when Renovate merges directly as itself
     (`platformAutomerge: false` in `default.json`), which is why
     `org-auto-merge.yml` skips bot PRs.

   A green `CodeRabbit` check is not proof of a review: it goes green when a
   review is skipped, paused or rate-limited. The approval is the proof,
   which is why the approval count must never drop to 0.

   A second organisation ruleset, `ci-gate`, requires one check named
   `ci-gate` from GitHub Actions. It is declared `enforcement: disabled` until
   every repository publishes that check (see "The `ci-gate` contract"
   below), then flipped to `active` in a reviewed PR.

   A third, `auto-merge`, is the one that requires `org-auto-merge.yml`
   (step 3). A required workflow can't be switched on per repository; it
   runs from this repository's `main` on every PR in the org. Before writing
   that ruleset, the reconciler checks the file exists at `main` and that
   this private repository lets the org's repositories use its workflows
   (Settings > Actions > General > Access). If either fails it writes
   nothing, reports `WORKFLOW-UNREACHABLE` and fails the run, because a
   required workflow that can't run blocks every merge. GitHub runs a private
   required workflow only on private repositories, so the reconciler also
   names any public repository, which would wait for a workflow that never
   comes.

   A fourth, `long-lived-branches`, makes `main`, `master`, `develop` and
   everything under `release/` undeletable in every repository.
   `delete_branch_on_merge` deletes a PR's head branch when it merges, so
   without this a PR from `develop` into `main` would take `develop` with it.

   **Rollout.** On 2026-09-25, the day the org moved to GitHub Team, the same
   gate was put on all 33 repositories by hand as repository rulesets named
   `review-gate`. Once the org ruleset has been read back active and
   matching, and each repository lists it as applying there, the reconciler
   deletes those per-repository copies (and nothing with any other name).
   Until then both apply, and they ask for the same thing.

   **Token.** Organisation rulesets need `ORG_ADMIN_TOKEN` to carry the
   organisation permission "Administration: read and write". Without it the
   reconciler reports `NEEDS-ORG-ADMIN`, leaves the org rulesets and the
   per-repository copies alone, and still reconciles every repository's
   settings. On a plan without organisation rulesets it reports
   `PLAN-BLOCKED`.

Requires, at the organisation level (not reproducible by a workflow file,
so done once by hand): the Claude GitHub App installed org-wide; **either**
a `CLAUDE_CODE_OAUTH_TOKEN` organisation Actions secret (a Claude
subscription token -- Pro/Max/Team/Enterprise -- minted locally with
`claude setup-token`; one year, does not auto-renew) **or** an
`ANTHROPIC_API_KEY` one (metered Console billing), for
`claude-address-feedback.yml`; and a CodeRabbit Pro seat for the reviewer
leg. `claude-address-feedback.yml` accepts either Claude credential as an
optional secret and passes both through, and Anthropic's documented auth
precedence has the API key always win when both are set -- so starting on
the OAuth token and adding the API key later, without removing the token,
is enough to switch the whole org over with no workflow edit. See the
header comment in that file for the full reasoning, including the
trade-off of an OAuth secret shared across every repo pooling its rate
limit with the token owner's own interactive usage. Also required
regardless of which credential is used: the ruleset itself, CodeRabbit's
"Request Changes Workflow" switched on in its organisation settings (without
it CodeRabbit never approves, and the gate never opens), and each repo's own
"Allow auto-merge" setting turned on. See
`claude/infrastructure-conventions.md` in the Tankster AI project for the
full checklist and current status.

A caller repo opts in with:

```yaml
# .github/workflows/agent-pipeline.yml in a consuming repo
name: agent-pipeline

on:
  pull_request:
    types: [opened, ready_for_review, reopened, labeled, unlabeled]
  pull_request_review:
    types: [submitted]
  issue_comment:
    types: [created]

concurrency:
  group: agent-pipeline-${{ github.workflow }}-${{ github.event.pull_request.number || github.event.issue.number }}
  cancel-in-progress: false

permissions:
  contents: read

jobs:
  address-feedback:
    if: github.event_name == 'pull_request_review' || github.event_name == 'issue_comment'
    uses: TanksterAI/.github/.github/workflows/claude-address-feedback.yml@v1
    secrets:
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
      claude-code-oauth-token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

Auto-merge needs no job here: `org-auto-merge.yml` runs on every PR by
itself once the `auto-merge` org ruleset is live. Remove any
`auto-merge-gate` job then: that older workflow arms without checking the
base branch's rules. (tankster-core's is inert until then, because its
`AUTO_MERGE_ENABLED` variable is unset.)

## The `ci-gate` contract

A ruleset can only require a check by its exact name, and every repository
names its CI jobs differently. Listing each repository's job names here would
make this repository depend on every other one, and every new repository
would need an edit here. So the org-wide `ci-gate` ruleset requires one
conventionally named check, `ci-gate`, and knows nothing else. Each
repository implements it with one job in its own CI workflow that passes only
when all of that repository's CI jobs passed.

Add this job to the workflow that holds the repository's CI jobs, usually
`.github/workflows/ci.yml`:

```yaml
  # The one check the org-wide `ci-gate` ruleset requires. It passes only when every
  # CI job listed in `needs` succeeded or was deliberately skipped, so the org rule
  # never needs to know this repo's job names. Add new CI jobs to `needs`.
  ci-gate:
    name: ci-gate
    if: always()
    needs: [<every CI job in this workflow>]
    runs-on: ${{ vars.CI_RUNNER || 'ubuntu-latest' }}
    timeout-minutes: 2
    steps:
      - name: All required CI jobs passed
        env:
          RESULTS: ${{ toJSON(needs) }}
        run: |
          echo "$RESULTS" | jq -e 'to_entries | all(.value.result == "success" or .value.result == "skipped")' >/dev/null \
            || { echo "::error::A required CI job failed or was cancelled:"; echo "$RESULTS" | jq -r 'to_entries[] | "\(.key): \(.value.result)"'; exit 1; }
```

- **Top level, in the repository's own workflow.** The job id and `name:` must
  both be exactly `ci-gate`. It can't live in a reusable workflow here: a job
  inside a called workflow reports its check as `<caller job> / <job name>`
  (for example `ci / ci-gate`), so it would never match the required name.
- **`needs` lists the CI jobs**: lint, typecheck, test, build, security,
  including jobs that call reusable workflows (`needs: [ci, security]`).
- **Leave out** bot and agent jobs (`address-feedback`, `auto-merge-gate`),
  advisory jobs allowed to fail (Lighthouse and the like), and release or
  deploy jobs that only run on main.
- **`skipped` passes**: a job skipped by its own `if:` (a path filter, say) is
  fine. `failure` and `cancelled` fail the gate.
- **One workflow file.** `needs` can't cross workflow files, so if CI is split
  across several, `ci-gate` goes in the main one and covers its jobs.
- **Triggers.** The workflow must run on `pull_request` (and ideally `push` to
  the default branch), so `ci-gate` reports on every PR.
- **No CI yet?** Add a minimal `ci.yml` with the lightest honest check the
  repository supports (markdown lint, `python -m compileall`, `cargo check`,
  `npm ci && npm run build`) plus `ci-gate`. Never a check that always passes.

This repository follows the contract: `self-check.yml` has a top-level
`ci-gate` job that needs `actionlint`, `Renovate presets` and `Scenario tests`.

## What the gate does not cover

Stated plainly, so nobody relies on more than is there:

- **Admins can edit organisation rulesets.** An admin, or an agent holding an
  admin's token, can't merge past an active gate, but can change or delete
  the ruleset itself. The reconciler restores it on its next run (on a push
  to `settings.yml`, nightly, or by hand), not instantly. Keep admin tokens
  away from agents where you can.
- **`@coderabbitai approve` defeats the gate.** That command makes CodeRabbit
  approve without a review. Nothing in a ruleset can tell that approval from
  a real one, so it must never be posted, by a person or an agent.
- **CodeRabbit skips bot PRs.** It never reviews or approves them, which is
  why Renovate has a bypass. Dependabot has none, so its PRs need a human
  approval.
- **The owner's approval counts on PRs opened by others.** A ruleset can't
  name CodeRabbit as the required reviewer (`required_reviewers` accepts
  teams only), so on a PR someone else opened, the owner's approval
  satisfies the gate too. On PRs the owner's account opens, which includes
  every agent using the owner's token, only CodeRabbit's approval can count.
- **Adding `needs-human-review` to an armed PR doesn't disarm it.** GitHub
  ignores a required workflow's event filters and runs it only on opened,
  synchronize and reopened, never on a label. Push a commit (which re-runs
  it) or press "Disable auto-merge".
- **PRs already open when `auto-merge` goes live wait for it.** A required
  workflow runs on the next opened, synchronize or reopened event, so an
  older PR shows `auto-merge / arm` as expected until you push to it, or
  close and reopen it.
- **A merge armed with `GITHUB_TOKEN` starts no workflows.** GitHub records
  the merge as github-actions, and pushes made that way don't trigger
  `on: push`. Set the org variable `MERGE_APP_CLIENT_ID` and secret
  `MERGE_APP_PRIVATE_KEY` for a GitHub App with Contents and Pull requests
  (read and write), and `org-auto-merge.yml` arms with that App instead, so
  release and deploy workflows fire after an auto-merge.
- **A failed `arm` run blocks the merge.** `auto-merge / arm` is a required
  workflow, so if the run itself fails (the runner named by `CI_RUNNER` is
  unavailable, the 5-minute timeout is hit, or Actions has an outage) the PR
  can't merge, by hand or automatically, until it passes. Re-run the `arm`
  job from the PR's Checks tab, or push a commit.
- **Personal accounts have no account-wide rulesets.** Repositories under a
  personal account aren't covered by any of this. rishitank/.github handles
  its own account separately: its reconciler writes the same ruleset body to
  each public repository, and a scheduled sweep arms auto-merge, still with
  no per-repository data.

## Security tooling, and what is deliberately absent

There is no CodeQL here and nothing uploads SARIF. Both require GitHub Code
Security on private repositories, and most of this estate is private, so a
CodeQL workflow would fail on the repos that need it most. What is here works on
every repo at no cost:

- **osv-scanner** -- vulnerable dependencies across npm, PyPI, crates and Go.
  Uses the `osv-scanner-action` sub-action, not the reusable workflow, because
  the reusable one uploads SARIF.
- **gitleaks** -- secrets, in CLI form. The gitleaks *Action* requires a licence
  key for organisation-owned repositories; the MIT-licensed CLI does not.
- **npm audit / pip-audit / cargo-audit** -- ecosystem advisories.

Public repos can and should keep a CodeQL workflow of their own alongside this.

## Renovate

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["github>TanksterAI/.github:node"]
}
```

Presets: `default` (implied by `github>TanksterAI/.github`), `node`, `python`, `rust`.

`default.json` includes `helpers:pinGitHubActionDigests`, which converts every
`uses: some/action@v1.2.3` into a commit digest with the version as a trailing
comment, and then keeps those digests current. That is how this estate gets
SHA-pinned actions without anyone hand-maintaining a list of hashes.

If this repository is private, the Renovate app must be installed on it as well
as on the consuming repos, or preset resolution will fail.

## Changing a workflow

A change here lands on every consuming repo at once. Treat it accordingly:

1. Open a PR. `self-check.yml` runs actionlint over the change, and the
   scenario tests in `tests/` against the reconciler and
   `org-auto-merge.yml` (run them locally with `bash tests/<name>/test.sh .`;
   they need jq, yq v4 and python3). A change to either file comes with a
   scenario for it.
2. Test against one consuming repo by pinning it to the branch
   (`@my-branch` instead of `@v1`) and watching a real run go green.
3. Merge, then move the `v1` tag: run the `move-major-tag` workflow, or by
   hand `git tag -f v1 && git push -f origin v1`.

## Visibility

Reusable workflows in a **private** repository can only be called by other
**private** repositories owned by the same account, and only once
Settings -> Actions -> General -> Access is set to allow it.

A **public** repository has no such restriction and additionally makes
`SECURITY.md`, `CONTRIBUTING.md` and the issue/PR templates here apply
automatically to every repo on the account that lacks its own.
