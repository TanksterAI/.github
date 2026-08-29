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
| `claude-review.yml` | any | Claude posts inline line-level PR review comments -- the gap CodeRabbit's Free tier leaves |
| `claude-address-feedback.yml` | any | Claude reads unresolved review threads (CodeRabbit + its own), fixes, resolves, pushes |
| `auto-merge-gate.yml` | any | Enables/disables `gh pr merge --auto` per PR based on an opt-out label; merge timing itself comes from the org ruleset |

Every job sets `timeout-minutes` and a least-privilege `permissions` block.
Callers still need their own `permissions` block, because the caller's grant is
the ceiling for everything it calls.

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

The agent pipeline below (`claude-review`, `claude-address-feedback`,
`auto-merge-gate`) deliberately does **not** follow this advisory-first
pattern -- it went live org-wide from day one, at the account owner's
explicit instruction, rather than proving itself on one repo first. Said
here so the inconsistency with every other workflow in this file reads as a
deliberate choice, not an oversight.

## The agent pipeline

`claude-review.yml`, `claude-address-feedback.yml`, and `auto-merge-gate.yml`
together let a PR go from opened to merged with no human review, by default,
org-wide:

1. **Open a PR.** `claude-review.yml` posts inline comments; CodeRabbit
   (installed separately at the org level, Free tier) posts its own summary
   and merge-risk flag alongside it.
2. **Feedback arrives.** `claude-address-feedback.yml` fires on CodeRabbit's
   or Claude's comments, fixes what's real, resolves the thread, replies to
   what it disputes, and pushes -- which re-triggers CI and step 1, and the
   cycle repeats until nothing is left to flag.
3. **`auto-merge-gate.yml`** enables `gh pr merge --auto` on the PR the
   moment it's opened (unless it carries `needs-human-review`).
4. **The org ruleset** -- required status checks green, and every review
   conversation resolved -- is what actually lets GitHub complete the merge.
   None of the three workflows above ever call merge themselves.

Requires, at the organisation level (not reproducible by a workflow file,
so done once by hand): the Claude GitHub App installed org-wide, an
`ANTHROPIC_API_KEY` organisation Actions secret, the ruleset itself, and
each repo's own "Allow auto-merge" setting turned on. See
`claude/infrastructure-conventions.md` in the Tankster AI project for the
full checklist and current status.

A caller repo opts in with:

```yaml
# .github/workflows/agent-pipeline.yml in a consuming repo
name: agent-pipeline

on:
  pull_request:
    types: [opened, synchronize, ready_for_review, reopened, labeled, unlabeled]
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
  review:
    if: github.event_name == 'pull_request' && contains(fromJSON('["opened","synchronize","ready_for_review","reopened"]'), github.event.action)
    uses: TanksterAI/.github/.github/workflows/claude-review.yml@v1
    secrets:
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}

  address-feedback:
    if: github.event_name == 'pull_request_review' || github.event_name == 'issue_comment'
    uses: TanksterAI/.github/.github/workflows/claude-address-feedback.yml@v1
    secrets:
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}

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
3. Merge, then move the `v1` tag:
   `git tag -f v1 && git push -f origin v1`.

## Visibility

Reusable workflows in a **private** repository can only be called by other
**private** repositories owned by the same account, and only once
Settings -> Actions -> General -> Access is set to allow it.

A **public** repository has no such restriction and additionally makes
`SECURITY.md`, `CONTRIBUTING.md` and the issue/PR templates here apply
automatically to every repo on the account that lacks its own.
