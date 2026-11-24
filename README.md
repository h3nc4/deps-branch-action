# deps-branch-action

Renovate merges each dependency update into an integration branch, `deps`, after that update passes CI on its own. This action merges the default branch into `deps` after every push to it and, once a week, promotes `deps` to the default branch as one squashed commit. The default branch then gets one dependency commit a week instead of one per update.

## How it works

On every push to the default branch, the action merges the default branch into `deps` through the merges API, so `deps` always holds the latest code and the next promotion lists only new updates. It creates `deps` from the default branch the first time. A merge conflict fails the run and leaves `deps` as it was.

On every push to `deps`, once Renovate merges an update there, it opens a draft pull request from `deps` to the default branch, or keeps the open one. CI runs on that draft after every update, so two updates that pass alone but break together show up during the week.

On the weekly schedule, or when dispatched, it syncs first. If `deps` has no change the default branch lacks, it stops. Otherwise it takes the draft, or opens the pull request when there is none, titles it `update dependencies for week N` and marks it ready. Then it turns on auto-merge with a squash. GitHub merges it once the default branch's required checks pass. GitHub refuses auto-merge where the default branch doesn't require checks. There the action waits up to an hour for the pull request's checks and merges it itself once they all pass. A promotion that doesn't start any check is merged too, because every update in it passed its own. The pull request comes from `deps` itself, which is never deleted, and since every push to the default branch is synced into `deps` the pull request is never behind.

## Usage

Add a workflow that runs on push to the default branch and to `deps`, on a weekly schedule and on dispatch, with a GitHub App installation token. A pull request opened with `GITHUB_TOKEN` starts checks that wait for approval.

```yaml
name: Dependency branch

on:
  push:
    branches:
      - main
      - deps
  schedule:
    - cron: "0 9 * * 1"
  workflow_dispatch:

permissions: {}

concurrency:
  group: ${{ github.workflow }}
  cancel-in-progress: false

jobs:
  deps:
    name: Sync or promote deps
    runs-on: ubuntu-latest
    steps:
      - name: Request an app token
        id: app-token
        uses: actions/create-github-app-token@f418cff399f7aef4c2f0ad47e25ca7a6abbdd6fc # v3.4.0
        with:
          client-id: ${{ vars.APP_CLIENT_ID }}
          private-key: ${{ secrets.APP_PRIVATE_KEY }}
          permission-contents: write
          permission-pull-requests: write
          permission-workflows: write
      - name: Run h3nc4/deps-branch-action
        uses: h3nc4/deps-branch-action@v1
        with:
          token: ${{ steps.app-token.outputs.token }}
```

Point Renovate at `deps` with the preset in this repository, which also stops Renovate rebasing on every merge into `deps` and turns off its vulnerability pull requests:

```json
{
  "extends": ["config:best-practices", "github>h3nc4/deps-branch-action"]
}
```

Every CI workflow whose `pull_request` trigger lists branches needs `deps` in that list, because the automerge step only merges an update after its checks finish.

A `baseBranchPatterns` in the repository's own Renovate config overrides the preset, so remove it. A `paths` filter on the only CI workflow leaves an update to another file without a check, so add `.github/workflows/**` to it.

## Repository settings

- **Allow auto-merge**, which the promotion uses.
- **A ruleset on `deps`** that blocks deletion and force pushes.
- **Dependabot security updates**, which open security fixes against the default branch directly, since the preset turns off Renovate's.

The app needs contents, pull requests and workflows write. Workflows write is needed because a sync can bring workflow changes into `deps`.

## Limits

A change on the default branch that conflicts with `deps` stops the sync until someone merges the default branch into `deps` by hand. `rebaseWhen: conflicted` lets two updates that each pass alone meet in `deps` untested together, and the promotion's checks on the default branch catch such a pair before it is merged.
