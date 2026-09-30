# Fixtures for the runner guard in `workflows-lint.yml`

`self-check.yml` runs the guard's own script, taken from `workflows-lint.yml`,
in this directory. Every line marked `# expect-flag` must be reported, and no
other line may be. These files are never run as workflows: GitHub only runs
the ones in the repository's top-level `.github/workflows`.
