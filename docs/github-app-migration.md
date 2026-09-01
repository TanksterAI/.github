# Replacing ORG_ADMIN_TOKEN with a GitHub App

`token-health.yml` points here. This is the way to make that check pass
forever rather than rotating a secret on a calendar you will not keep.

## Why

Two workflows write settings across the whole organisation:

| workflow | needs |
|---|---|
| `repo-settings-reconcile.yml` | Administration: write, Vulnerability alerts: write |
| `branch-prune.yml` | Contents: write |

Both run on `ORG_ADMIN_TOKEN`, a fine-grained personal access token. Three
problems with that, in ascending order of how much they will cost you:

1. **It expires.** A PAT has a maximum lifetime. When it lapses, the nightly
   reconciler fails at 03:00 and the estate drifts until somebody notices.
2. **It is a person.** Every settings change in the audit log is attributed
   to Rishi, whether he made it or a cron did. When there is more than one
   person, that stops being a curiosity and becomes a problem.
3. **It carries a person's whole access.** A fine-grained PAT is bounded by
   what its author can reach. An App installation is bounded by what it was
   installed for, which is a much smaller thing.

A GitHub App installation token fixes all three. It does not expire in any
sense that matters here: the App mints a fresh one per run, valid an hour,
and nothing needs rotating.

## Steps

About twenty minutes, once.

### 1. Create the App

Organisation Settings -> Developer settings -> GitHub Apps -> **New GitHub App**.

- **Name**: `tankster-settings-reconciler` (must be globally unique; add a
  suffix if taken)
- **Homepage URL**: the `.github` repository URL is fine
- **Webhook**: **untick Active**. This App is never called by GitHub; it only
  makes API calls outward.

**Repository permissions** -- grant exactly these and nothing else:

| permission | level | why |
|---|---|---|
| Administration | Read and write | `allow_auto_merge`, `delete_branch_on_merge` |
| Contents | Read and write | `branch-prune.yml` deleting merged refs |
| Metadata | Read-only | mandatory; GitHub adds it automatically |
| Pull requests | Read-only | listing merged PRs to find prunable branches |
| Dependabot alerts | Read and write | enabling alerts per `settings.yml` |

Do **not** grant Actions, Secrets, Workflows, or any organisation permission.
The reconciler does not need them, and an App that cannot rewrite workflows
cannot be used to rewrite itself.

**Where can this App be installed**: *Only on this account*.

Create it.

### 2. Generate a private key

On the App's settings page, scroll to **Private keys** -> **Generate a
private key**. A `.pem` file downloads. This is the credential; treat it the
way you would treat the PAT.

Note the **App ID** shown at the top of the same page.

### 3. Install it

Still on the App's page: **Install App** -> the `TanksterAI` organisation ->
**All repositories**.

All repositories rather than a list, deliberately: the entire point of the
reconciler is that a repository created next month is covered without anyone
remembering to add it. A selected list reintroduces the per-repo step this
whole mechanism exists to delete.

### 4. Store the credentials

`TanksterAI/.github` -> Settings -> Secrets and variables -> Actions ->
**New repository secret**, twice:

- `SETTINGS_APP_ID` -- the numeric App ID from step 2
- `SETTINGS_APP_PRIVATE_KEY` -- the **entire** contents of the `.pem`,
  including the `-----BEGIN RSA PRIVATE KEY-----` and `-----END-----` lines
  and the trailing newline

### 5. Switch the workflows over

In both `repo-settings-reconcile.yml` and `branch-prune.yml`, add a token
step before the step that uses `GH_TOKEN`:

```yaml
      - uses: actions/create-github-app-token@v2
        id: app-token
        with:
          app-id: ${{ secrets.SETTINGS_APP_ID }}
          private-key: ${{ secrets.SETTINGS_APP_PRIVATE_KEY }}
          owner: ${{ github.repository_owner }}
```

Then change `GH_TOKEN: ${{ secrets.ORG_ADMIN_TOKEN }}` to:

```yaml
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
```

`owner:` without `repositories:` mints an installation token covering every
repository the App is installed on, which after step 3 is all of them.

### 6. Verify before deleting anything

Run `repo-settings-reconcile` by hand with **dry-run ticked**. It should list
the same repositories it always did. If it reports zero repositories, the
token is wrong -- the workflow already refuses to call that success, which is
why it is safe to test this way.

Then run `token-health` by hand. It should report *no expiration header* and
pass. That is the migration confirming itself.

### 7. Only then, delete `ORG_ADMIN_TOKEN`

Remove the repository secret, and revoke the PAT at
https://github.com/settings/tokens. Leaving a working admin PAT lying around
after it stopped being needed is the actual risk here.

## What this does not fix

An App installation token still cannot tick **Allow auto-merge** on a
repository that does not exist yet -- there is no org-level default for it,
which is why the reconciler exists at all. The App changes who holds the
credential, not what GitHub exposes.

It also does not touch `AUTO_MERGE_ENABLED`. Auto-merge stays off across the
estate until rulesets can cover private repositories on this plan and a
ruleset requires CI to pass. See the comments in any repository's
`agent-pipeline.yml` for why that is not caution but arithmetic.
