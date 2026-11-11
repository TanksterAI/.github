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
| `python-ci.yml` | Python | one job: ruff + optional mypy + your `verify.py` gate; optional graceful checkout of a private sibling repo |
| `node-ci.yml` | Node / TypeScript | npm or pnpm, single job, `.nvmrc` as the version source of truth |
| `rust-ci.yml` | Rust | fmt, clippy `-D warnings`, test, release build (not on PRs unless `release-on-pr`), and the no-panics-in-production gate |
| `security.yml` | any | osv-scanner + gitleaks in one job, both blocking; the advisory ecosystem audit runs weekly (every run if `audit-strict`) |
| `lighthouse-ci.yml` | Node / web frontends | `lhci autorun` against a locally built app, plus a sticky PR comment with the score table; advisory by default |
| `runtime-gate.yml` | web apps (any stack) | boots the app (Dockerfile, command or static), crawls it in a real browser and **fails on runtime errors**: exceptions, console errors, hydration errors, failed requests, 4xx/5xx, blank pages; plus advisory screenshot diffs and an advisory Gemini explorer that uses the app like a person. See `docs/runtime-gate.md` |
| `lockfile.yml` | Node / TypeScript | `workflow_dispatch` lockfile regeneration that proves the result before committing |
| `workflows-lint.yml` | any | actionlint over `.github/workflows/`, self-updating and cached |
| `claude-review.yml` | any | Claude posts inline line-level PR review comments -- **retired 30 Aug 2026**, no active callers; CodeRabbit Pro is now the org's sole PR reviewer (see "The agent pipeline" below). Kept in the repo, unused, in case that changes |
| `claude-address-feedback.yml` | any | Claude reads unresolved review threads (CodeRabbit + its own), fixes, resolves, pushes |
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

Docker-free jobs can also take the light lane, a second free pool of runners
on Cloud Run; see [Light lane](#light-lane) below.

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

## Light lane

GitHub-hosted minutes are spent, and the Cloud Build fallback (`tankster-gcb`)
has a free tier of its own that runs out too. The light lane adds a second
free pool: one-job runners on Cloud Run Jobs (`gh-light-runner` in
`tankster-infra`, 1 vCPU, 4 GiB). Cloud Run has no Docker daemon, so only jobs
that need no Docker may use it. The dispatcher, the runner image and its
limits are described in `ci/fallback-runner/` in `tankster-infra`.

**How a job asks.** With a label bound to its own run,
`tankster-light-<run id>-<run attempt>`. A runner takes any queued job whose
labels it has, so a fixed `tankster-light` label would let a light runner
started for one run take a job from another, in any repository, including
one that needs Docker. A run-bound label means a light runner only ever takes
a job of the run it was started for, and only one that asked for the lane.

**When it is open.** Only while the organisation variable `CI_LIGHT_RUNNER`
is `tankster-light`. Unset, `off` or anything else means closed, and every
job runs exactly where it ran before (the tests in `tests/light-lane` check
this for every combination of inputs and variables). The dispatcher sets the
variable, and keeps it `off` until the lane is switched on there. While the
Cloud Run pool is capped or turned off, light jobs are still served, by Cloud
Build, so while the dispatcher runs, asking for the lane never leaves a job
waiting (see "If the dispatcher stops" below). A repository that
cannot see the variable is never on the lane. Only the dispatcher should
write it: GitHub compares strings without regard to case, so `Tankster-Light`
opens the lane too, and a repository variable of the same name overrides the
organisation's for that repository, so none should exist.

**Which shared workflows use it.** Each Docker-free one has a `light` input,
default `true` except where the table says otherwise:

| Workflow | Light lane | Why |
|---|---|---|
| `node-ci.yml`, `python-ci.yml`, `lockfile.yml` | yes | Docker-free, but they run your commands (`test`, `verify`, ...): see opting out, toolchains and egress |
| `rust-ci.yml` | off by default (`light: true` opts in) | every Rust build needs a C linker, and the light image has no C toolchain and no rustup: the job would fail with `rustup: command not found`. The dispatcher learns that and re-runs it on Cloud Build (see toolchains), but only after one failed light execution for each caller's workflow, which every Rust caller would waste. Turn it on only once the image has them |
| `workflows-lint.yml`, `runtime-gate-flows.yml`, `auto-merge-gate.yml` | yes | nothing in them needs Docker, and they send little |
| `claude-address-feedback.yml`, `conflict-sweep.yml` | off by default (`light: true` opts in) | no Docker, but every model request resends the conversation, so a long session can pass the egress limit, and the re-run on Cloud Build would repeat the session: its model usage, and any pushes or comments the first attempt made. Turn it on only once their egress has been measured |
| `security.yml` | no | `osv-scanner-action` is a Docker action |
| `runtime-gate.yml` | no | runs Postgres, and in `mode: docker` the app, with `docker` |
| `lighthouse-ci.yml` | not yet | no Docker, but Chrome, its system libraries and Lighthouse's CPU-sensitive scores have not been tried on a 1-vCPU Cloud Run runner |
| `claude-review.yml` | no | retired |

**Opting out.** A caller whose own commands need Docker, or upload a lot (see
egress below), passes `light: false`. Setting `runs-on` also takes a job off
the lane. If a caller does neither, a Docker call on a light runner fails the
job, and the dispatcher re-runs the run's failed jobs on Cloud Build and
records the workflow in `CI_LIGHT_DOCKER`, so its light jobs go to Cloud Build
from then on. That works when the failed job's log shows one of:

- `TANKSTER_LIGHT_NO_DOCKER`, which the runner's `docker` and
  `docker-compose` print;
- `Cannot connect to the Docker daemon`, `Could not find a valid Docker
  environment` or `/var/run/docker.sock`, the errors of clients that use the
  socket themselves (testcontainers, docker-py, dockerode, BuildKit clients).

Anything else that needs Docker must pass `light: false`: a tool that gives up
with some other message fails the job and is not re-run.

**Toolchains.** The light image has no compilers or linkers: no `cc`, `gcc`,
`g++`, `make` or `ld`, no `rustup` or `cargo`, and no `python3` (which node-gyp
needs). A caller whose dependencies compile native code must pass
`light: false`: a Node package with a native addon built by node-gyp, or a
Python package that builds from source because no wheel fits the runner. If a
caller does not, the dispatcher records the workflow in `CI_LIGHT_DOCKER` with
the reason `toolchain` and re-runs the run's failed jobs once on Cloud Build,
when the failed job's log shows one of these (exact and case-sensitive):

- `rustup: command not found`, `cargo: command not found`,
  `` linker `cc` not found ``;
- `gyp ERR!`;
- `make: command not found`, `gcc: command not found`,
  `g++: command not found`, `cc: command not found`;
- `error: command 'gcc' failed`, `unable to execute 'gcc'`.

Anything else that needs a compiler must pass `light: false`: a build that
fails with some other message fails the job and is not re-run. meson's
`Unknown compiler(s)` and maturin's or setuptools-rust's
`can't find Rust compiler`, for example, are not learned. rust-ci is off the
lane by default because every Rust caller would otherwise lose one failed
light execution before it is learned.

**Egress.** Cloud Run's internet egress is free for 1 GiB a month, then billed,
so the runner image meters what each job sends. A light job that sends more
than 64 MiB (the image's default `EGRESS_LIMIT_BYTES`) is stopped from
outside. Everything a job uploads counts: cache saves, artifact uploads,
`git push`, deployments and requests to APIs, a model's API included.
Downloads (checkout, installs, cache restores) do not. The runner's execution
then exits with code 70, and the dispatcher records the workflow in
`CI_LIGHT_DOCKER` with the reason `egress` and re-runs the run's failed jobs
on Cloud Build. In GitHub the stopped job just fails, as a lost runner does;
the `TANKSTER_LIGHT_EGRESS` line is in the Cloud Run execution's log, not the
job's.

The shared workflows keep their own uploads off the light runner (its runner
names start `crj-`): node-ci restores its dependency cache read-only and
never saves it, rust-ci's `rust-cache` restores but does not save,
workflows-lint does not save its actionlint cache, and lockfile turns
setup-node's cache off there. node-ci's build artifact (`artifact-name`) is
still uploaded, because callers download it in a later job: a caller whose
artifact is large passes `light: false`. So do jobs that upload coverage
reports, push images or deploy.

**Your own workflows.** A job in a consuming repo that needs no Docker joins
the lane with exactly this `runs-on` (the lint accepts no other form):

```yaml
    runs-on: ${{ (vars.CI_LIGHT_RUNNER == 'tankster-light' && format('tankster-light-{0}-{1}', github.run_id, github.run_attempt)) || vars.CI_RUNNER || 'ubuntu-latest' }}
```

The shared workflows use the same thing with their inputs in front:

```yaml
${{ inputs.runs-on || (inputs.light && vars.CI_LIGHT_RUNNER == 'tankster-light' && format('tankster-light-{0}-{1}', github.run_id, github.run_attempt)) || vars.CI_RUNNER || 'ubuntu-latest' }}
```

A reusable workflow of your own that uses this second form must declare
`light` under `on.workflow_call.inputs` with `type: boolean`. From a `string`
input, `'false'` is a non-empty string, which is true, so the job would take
the lane anyway; the lint fails the second form in a workflow without a
boolean `light` input.

**The lint.** `workflows-lint.yml`'s "Light jobs stay Docker-free" step
checks every job whose `runs-on` mentions `tankster-light`, and fails it when:

- its `runs-on` is not exactly one of the two expressions above (whitespace
  aside). That is what binds the label to the run and to the organisation's
  switch, so no other form is accepted;
- it has `services` or a `container`, or a step uses `docker://`;
- it uses the shared-workflow form in a workflow without a boolean `light`
  input (see above);
- a shell `run` step (bash, sh or the default shell) calls a container tool
  as a command (`docker`, `docker-compose`, `podman`, `nerdctl`, `buildah`,
  `buildctl`, `kind`, `k3d`, `minikube`, `earthly`, `act`, `dagger`),
  including after `sudo`, `env`, `nice`, `exec`, `!`, `if`, `xargs`, `eval`,
  inside `$( )` and in `sh -c '...'`. Guards such as `command -v docker`,
  `which docker`, `type docker` and `hash docker` are fine. A step whose
  shell is `python`, `pwsh` or anything else is not read as shell, and a
  heredoc body is skipped unless a shell reads it (`bash <<EOF`,
  `cat <<EOF | sh`);
- a step uses one of Docker's own `docker/*` actions (setup-buildx,
  build-push, login, setup-qemu, bake, compose...), or an action whose
  `action.yml`, read through the GitHub API at the pinned ref with the job's
  token, says `runs.using: docker`. Composite actions are followed into their
  steps. An action whose `action.yml` is missing, refused or does not parse
  fails the job, except the first-party `actions/*` ones checked to be node
  actions. A transient error (5xx, 429, a rate limit, the network) is tried
  three times, 2 and then 5 seconds apart (or as `Retry-After` says, up to
  10), and then only warned about. After one action has ended that way, the
  rest are tried once each, so an outage costs seconds, not minutes;
- a step gives `anthropics/claude-code-action` an `mcp__github__` tool: the
  action runs that MCP server in a Docker container.

It also checks a job that calls `node-ci.yml`, `python-ci.yml` or
`lockfile.yml` without `light: false` or `runs-on`: their command inputs
(`install`, `test`, `verify`, ...) are your commands on a light runner, so
they get the same `run` rules, with each expression in them read as one
plain word. Owners and labels are matched without regard to case, as GitHub
matches them. And it fails a light label passed to a
reusable workflow through `with: runs-on` (use its `light` input: only that
workflow knows whether its jobs need Docker) or put in a strategy matrix.
Repositories whose workflows do neither are skipped without being parsed. The
script is the step's own `run:` block; `self-check.yml` runs
`tests/light-lane` against it.

What it cannot see: Docker reached through a script file, a package script
(`npm run ...`), a variable or a library such as testcontainers; a `runs-on`
that takes its label from a variable, which has no `tankster-light` in it to
find; and how much a job uploads. The dispatcher's re-runs above cover the
first only for the messages listed, and the last through the egress stop.

On a runner without shellcheck, actionlint skips its shellcheck pass
without saying so; workflows-lint prints a warning when that happens, and
the `run:` blocks are checked wherever shellcheck is installed.

**Short jobs.** Every light job pays a Cloud Run start and a runner
registration out of a free pool of roughly 1,500 to 2,000 minutes a month.
That cost has not been measured yet. If it turns out to dominate jobs of a
few seconds (`auto-merge-gate`, say), those are better passed
`light: false`.

**If the dispatcher stops.** While the lane is open, light jobs wait for the
dispatcher. If it is paused or down (for example after the GCP spend cap
trips), set the organisation variable `CI_LIGHT_RUNNER` to `off`: light jobs
then go back to `CI_RUNNER`. Jobs already queued with a light label wait
until the dispatcher returns or are re-run.

## The agent pipeline

`claude-address-feedback.yml` and `auto-merge-gate.yml`, together with
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
3. **`auto-merge-gate.yml`** enables `gh pr merge --auto` on the PR the
   moment it's opened (unless it carries `needs-human-review`).
4. **The org ruleset** -- required status checks green, and every review
   conversation resolved -- is what actually lets GitHub complete the merge.
   Neither workflow above ever calls merge itself.

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
regardless of which credential is used: the ruleset itself, and each
repo's own "Allow auto-merge" setting turned on. See
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

  auto-merge-gate:
    if: github.event_name == 'pull_request' && contains(fromJSON('["opened","reopened","ready_for_review","labeled","unlabeled"]'), github.event.action)
    uses: TanksterAI/.github/.github/workflows/auto-merge-gate.yml@v1
```

## Runtime gate: does the app still work?

`runtime-gate.yml` exists because a dependency update can pass build, lint and
unit tests and still break the running app. It boots the app the way it is
deployed, uses it in a real browser, and fails the check on runtime errors, so
Renovate cannot merge an update that breaks a page. There are no test cases to
write or maintain. An advisory AI explorer (Gemini free tier, `GEMINI_API_KEY`
secret) uses the app like a person for major and framework updates. Full
guide, inputs and examples: [`docs/runtime-gate.md`](docs/runtime-gate.md).

The Renovate presets set `platformAutomerge: false`, so Renovate itself checks
that every status (this gate included) is green before it merges. GitHub's
native auto-merge only waits for checks that branch protection or a ruleset
makes required. A repository that has neither, for example a private
repository on a plan that does not offer them (see GitHub's
[protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)
and [rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets)
pages for which plans do), has no required checks, so native auto-merge would
merge the moment the PR opened.

```yaml
jobs:
  runtime:
    uses: TanksterAI/.github/.github/workflows/runtime-gate.yml@<sha>
    permissions: { contents: read, actions: read, pull-requests: write }
    with:
      mode: docker
    secrets:
      gemini-api-key: ${{ secrets.GEMINI_API_KEY }}
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
- **npm audit / pip-audit / cargo-audit** -- ecosystem advisories. Advisory,
  and their databases are OSV sources already, so they run on the weekly
  schedule and on manual runs only (on every run with `audit-strict: true`).
  cargo-audit comes as a prebuilt binary, not `cargo install`.

All three run as steps of one job: a finding in one does not stop the others,
and a final verdict step fails the job if osv-scanner or gitleaks found
anything.

Public repos can and should keep a CodeQL workflow of their own alongside this.

## Renovate

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["github>TanksterAI/.github:node"]
}
```

Presets: `default` (implied by `github>TanksterAI/.github`), `node`, `python`, `rust`,
and the opt-in `tanksterai-ui` (see [below](#opt-in-the-tanksterai-ui-packages)).

Updates come **once a month**, in a window on the 1st-3rd (London time), and
normally as two pull requests per repository: `non-major (automerge)`
(non-major GitHub Actions bumps, dev and test tooling, cargo patches; merged by
Renovate on green CI inside the window) and `non-major (review)` (everything
else non-major, Docker digests included). The scientific stack keeps its own
group. Majors, GitHub Actions majors included, open no pull request until they
are ticked on the Dependency Dashboard. Lockfile maintenance is quarterly.
Branches are not updated or rebased outside the window, so a reviewed pull
request merged later needs "Update branch" first. Security fixes are
unaffected: `vulnerabilityAlerts` ignores the schedule and grouping and opens
a pull request at once. Every Renovate pull
request costs a full CI run plus another on merge, so this is the difference
between about 450 and about 100 pull requests a month across the estate.

`default.json` includes `helpers:pinGitHubActionDigests`, which converts every
`uses: some/action@v1.2.3` into a commit digest with the version as a trailing
comment, and then keeps those digests current. That is how this estate gets
SHA-pinned actions without anyone hand-maintaining a list of hashes.

The exception is this repository's own reusable workflows: Renovate leaves
`TanksterAI/.github` and `rishitank/.github` refs alone, so they stay at `@v1`
and a change reaches every repository by moving the tag, with no pull request
anywhere. A caller still pinned to a commit SHA must be moved to `@v1` once by
hand: Renovate will not touch it again.

If this repository is private, the Renovate app must be installed on it as well
as on the consuming repos, or preset resolution will fail.

### The Node runtime (`node` preset)

The estate runs the newest stable Node, not only LTS, and `.nvmrc` holds its
major line (`26`) as the one source. The `node` preset moves every copy of that
version together, in one `Node runtime` pull request that is never automerged
(`renovate/node-runtime` for releases inside the line, `renovate/major-node-runtime`
for a new major, which like any major opens no pull request until it is ticked
on the Dependency Dashboard). A new major is offered as soon as it ships rather
than when it reaches LTS; prereleases (`27.0.0-rc.1`) never are.

Release age works differently here than for other dependencies: it is a status
check, not a delay. Every Node update goes into the branch as soon as Renovate
finds it, and while the Node release is younger than the baseline's age (7 days
for a major, 3 for a minor or patch) the pull request carries a pending
`renovate/stability-days` check, which turns green once it is old enough.
Docker images do not count towards it (their tags are re-pushed on every
rebuild); `.nvmrc`, engines, setup-node and exact pins do. The check is not
part of `ci-gate`, so wait for it before merging. This is
`internalChecksFilter: "none"`: with Renovate's default, a young release was
held back one dependency at a time, and the pull request moved some copies of
the version but not others.

What Renovate tracks, and in which shape:

| Where | Tracked shape | On a new major |
|---|---|---|
| `.nvmrc`, `.node-version` and other node-version files | bare major (`26`) or exact (`26.13.0`) | `27`, or the new exact release |
| Docker `node` images (`FROM`, `ARG ...=node:...`) | a version tag (`26-bookworm-slim`, `26.13.0-bookworm-slim`), which keeps its precision | `node:27-bookworm-slim`, `node:27.0.0-bookworm-slim` |
| `actions/setup-node` `node-version:` in workflows | bare major or exact | `27`, or the new exact release |
| `engines.node` in any `package.json` | exactly `">=26"`, `">= 26"` or `">=26.0.0"` | `">=27"` (same shape) |

- `node-version-file: .nvmrc` in a workflow has nothing to update; it follows
  `.nvmrc`. That is the preferred form.
- An `engines.node` in any **other** shape (`">=22.18"`, `">=22.23.4"`,
  `"^22"`, `"22.x"`) is not touched by Renovate at all: the npm manager's own
  `engines` dependency is off, because it would rewrite `">=26"` to
  `">=26.14.0"` on every release. Move such a range to `">=<major>"` by hand.
- A lagging `engines.node` that is already `">=<major>"` (say `">=22"`) is
  raised to the newest major in the next `Node runtime` pull request, which
  narrows who can install that package. For a published package that is a
  breaking change to its public contract; decide it there.
- A repository rule that sets `ignoreUnstable: true` for `node-version`
  dependencies (the older "Track the CURRENT Node line" rules) comes after the
  preset and undoes it: a new major is held until LTS again. Delete such rules.

### Opt-in: the `@tanksterai` UI packages

A product that uses the private UI packages `@tanksterai/tokens`,
`@tanksterai/css` and `@tanksterai/react` (published to GitHub Packages) adds
`tanksterai-ui` after its language preset:

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["github>TanksterAI/.github:node", "github>TanksterAI/.github:tanksterai-ui"]
}
```

> [!WARNING]
> `tanksterai-ui` must come **after** the language preset in `extends`. Placed
> first, `default.json`'s devDependency rule overrides it and these packages
> are automerged, with nothing to say so.

What `tanksterai-ui.json` does:

- Maps the `@tanksterai` scope to `https://npm.pkg.github.com` (`npmrc`, with
  `npmrcMerge` so the repository's own `.npmrc` settings are kept, plus
  `registryUrls`) and signs in there with the Mend credential below.
- Puts the three packages in one `tanksterai-ui` pull request, labelled
  `tankster-ui`, that opens at the next Renovate run after a release (publishing
  a package does not trigger a run). It overrides the monthly window and turns
  the release-age wait off with `minimumReleaseAge: null`.
  `minimumReleaseAgeBehaviour: "timestamp-optional"` does nothing while that
  is null; it is a guard, so that if an age is ever set, a missing publish time
  cannot hold a release back. The estate-wide `prConcurrentLimit` and
  `prHourlyLimit` still apply; `prPriority` puts this pull request first in the
  queue.
- Never automerges, even when the packages are devDependencies (which
  `default.json` otherwise automerges), provided the preset comes after the
  language preset as above. Majors open no pull request until they are ticked
  on the Dependency Dashboard.
- Disables `@tanksterai/design-tokens`, which `@tanksterai/tokens` replaced.
  Renovate opens no pull requests for it. It cannot stop someone adding it
  back to a `package.json`, and moving off it is a change made by hand.

It is a separate preset, not part of `default` or `node`, because its host rule
needs a credential. A repository that extends it while the credential is missing
stops with a Renovate config error ("The following secrets name was not found
in config: TANKSTERAI_PACKAGES_TOKEN"). Opting in keeps that to the
repositories that asked for it.

**The credential.** `TANKSTERAI_PACKAGES_TOKEN` is a Mend credential that the
organisation owner adds at [developer.mend.io](https://developer.mend.io), in
the organisation's settings under *Credentials*. Add it at organisation level,
not repository level, so every opted-in repository inherits it. It is a GitHub
personal access token (classic), from an account that can read the packages,
with only the `read:packages` scope. A classic token with `read:packages` can
read every package its account can see, in every organisation, so it should
come from the narrowest account available. The chosen account is the
organisation owner's own, with only `read:packages`: a dedicated machine account
would need a paid Team seat. It is not a GitHub Actions secret and never
goes in a repository: the preset names it, as
`{{ secrets.TANKSTERAI_PACKAGES_TOKEN }}`, and Mend fills it in at run time. If
the token was given an expiry date, renew it in the same place before then.

## CI minute budget

GitHub bills every job rounded up to a whole minute, and the fallback runner
boots a VM per job. In October 2026 the average private job ran 51 seconds, so
46% of the minutes billed were rounding. Rules for anything added here or in a
consuming repo:

- **One job per concern, steps not jobs.** A check that takes seconds belongs
  as a step of a job that is already running.
- **Cancel superseded runs.** Every caller that runs on `pull_request` sets
  `concurrency` with `cancel-in-progress: true`, keyed on the caller's ref.
- **No duplicate runs.** Merges are squash-only from up-to-date branches, so a
  `push: main` run re-checks a tree the pull request already checked. Keep a
  push trigger only where something needs it: a deployment, a visual
  baseline, or `rust-ci.yml`, whose release build is skipped on pull requests
  (unless `release-on-pr`) and so happens on the caller's push run.
- **Schedules weekly at most** unless the job is the product.
- **Reference this repository at `@v1`**, never by SHA: a SHA pin turns every
  change into a pull request in every consuming repository.

## Changing a workflow

A change here lands on every consuming repo at once. Treat it accordingly:

1. Open a PR. `workflows-lint.yml` runs actionlint and the light-lane lint
   over the change, and `self-check.yml` runs their tests.
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
