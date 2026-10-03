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
| `claude-review.yml` | any | The org's PR reviewer since 3 Oct 2026. Claude reviews every PR for correctness and security, posts inline comments, resolves its own threads once they are fixed, and submits REQUEST_CHANGES or APPROVE -- the approval the `review-gate` rulesets require. Replaces CodeRabbit's review and approval (see "The agent pipeline" below) |
| `claude-address-feedback.yml` | any | Claude reads unresolved review threads (its own review, plus CodeRabbit's summaries), fixes, resolves, pushes |
| `auto-merge-gate.yml` | any | Enables/disables `gh pr merge --auto` per PR based on an opt-out label; merge timing itself comes from the org ruleset |

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

The agent pipeline below (`claude-review`, `claude-address-feedback` and
`auto-merge-gate`) deliberately does **not** follow this advisory-first
pattern -- it went live org-wide from day one, at the account owner's explicit
instruction, rather than proving itself on one repo first. Said here so the
inconsistency with every other workflow in this file reads as a deliberate
choice, not an oversight.

## The agent pipeline

`claude-review.yml`, `claude-address-feedback.yml` and `auto-merge-gate.yml`
let a PR go from opened to merged with no human review, by default, org-wide:

1. **Open a PR.** `claude-review.yml` reviews it: correctness through Claude
   Code's bundled `code-review` skill and a security pass following Claude
   Code's `/security-review` methodology, in one run. It posts one review with
   inline comments and a verdict -- REQUEST_CHANGES while any of its threads
   is open, APPROVE once none are -- as CodeRabbit's request-changes workflow
   did. Later pushes get an incremental review of the new commits only, and
   Claude resolves its own threads the new code fixed.
2. **Feedback arrives.** `claude-address-feedback.yml` fires on the review,
   fixes what's real, resolves the thread, replies to what it disputes, and
   pushes -- which re-triggers CI and an incremental review, and the cycle
   repeats until nothing is left to flag. Incremental reviews post blocking
   findings only, so the loop converges.
3. **Threads resolved without a push?** GitHub has no workflow trigger for
   resolving a thread, so comment on the PR: `claude-review.yml` re-checks its
   threads and approves once none of them is open. Same hook as
   `review-gate.yml`.
4. **`auto-merge-gate.yml`** enables `gh pr merge --auto` on the PR the
   moment it's opened (unless it carries `needs-human-review`).
5. **The `review-gate` ruleset** -- one approving review, every conversation
   resolved, required checks green -- is what actually lets GitHub complete
   the merge. None of the workflows above ever calls merge itself.

History: CodeRabbit was the reviewer from 30 Aug 2026 and `claude-review.yml`
was retired. CodeRabbit Pro was never bought; a 14-day Advanced trial supplied
its reviews and approvals from mid-September until about 3 Oct, when the org
fell back to CodeRabbit Free (summaries only, no approval) and every merge
stopped. `claude-review.yml` was rebuilt as the reviewer on 3 Oct, on the Max
subscription, rather than paying for CodeRabbit while Tankster AI has no
revenue. CodeRabbit stays installed: its summary still posts, and the rulesets
still require its status check. Full record in
`claude/coderabbit-config-decision-2026-10-03.md`, Tankster AI project.

Requires, at the organisation level (not reproducible by a workflow file,
so done once by hand): the Claude GitHub App installed org-wide, and
**either** a `CLAUDE_CODE_OAUTH_TOKEN` organisation Actions secret (a Claude
subscription token -- Pro/Max/Team/Enterprise -- minted locally with
`claude setup-token`; one year, does not auto-renew) **or** an
`ANTHROPIC_API_KEY` one (metered Console billing). Both Claude workflows
accept either credential as an optional secret and pass both through, and
Anthropic's documented auth precedence has the API key always win when both
are set -- so starting on the OAuth token and adding the API key later,
without removing the token, is enough to switch the whole org over with no
workflow edit. See the header comment in `claude-address-feedback.yml` for
the full reasoning, including the trade-off of an OAuth secret shared across
every repo pooling its rate limit with the token owner's own interactive
usage. Also required regardless of which credential is used: the ruleset
itself, and each repo's own "Allow auto-merge" setting turned on. See
`claude/infrastructure-conventions.md` in the Tankster AI project for the
full checklist and current status.

Reusable workflows in this private repository can't be called from a public
repository (see "Visibility" below). Public repos (`grit` and `adlc` as of
3 Oct 2026) get CodeRabbit's free open-source plan instead, which includes
full reviews. Not yet observed: whether it approves there under the org's
settings, since neither repo has had a PR since going public. Check that on
the first one.

A caller repo opts in with two files. The reviewer is its own file because
`agent-pipeline.yml` queues runs per PR without cancelling, and a later
comment event would replace a queued review:

```yaml
# .github/workflows/claude-review.yml in a consuming repo
name: claude-review

on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
  issue_comment:
    types: [created]

concurrency:
  group: claude-review-${{ github.event_name }}-${{ github.event.pull_request.number || github.event.issue.number }}
  cancel-in-progress: true

permissions: {}

jobs:
  review:
    if: >-
      github.event_name == 'pull_request' ||
      (github.event.issue.pull_request != null && github.event.comment.user.type != 'Bot')
    permissions:
      contents: read
      pull-requests: read
      issues: read
      id-token: write
      actions: read
    uses: TanksterAI/.github/.github/workflows/claude-review.yml@v1
    secrets:
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
      claude-code-oauth-token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

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

  auto-merge-gate:
    if: github.event_name == 'pull_request' && contains(fromJSON('["opened","reopened","ready_for_review","labeled","unlabeled"]'), github.event.action)
    uses: TanksterAI/.github/.github/workflows/auto-merge-gate.yml@v1
```

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

1. Open a PR. `workflows-lint.yml` runs actionlint over the change.
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
