# Releasing

Releases are driven by GitHub Actions. The maintainer's only manual step is clicking "Run workflow" and reviewing the resulting PR.

## Prerequisites (one-time)

Before triggering `prepare-release` for the first time, the `Changes` file must contain at least one `## X.Y.Z` section heading so that the extract step in `finalize-release` has a bounded section to read.

To populate `Changes` with the post-2026-04-29 release (v1.2.0) that shipped during the file's frozen period, run the one-shot backfill and merge its PR:

```bash
git checkout main
git pull --ff-only
git checkout -b chore/backfill-changes
GITHUB_REPOSITORY=geofffranks/json-api \
    GH_TOKEN=$(gh auth token) \
    bash ci/scripts/backfill-changes.sh
git add Changes
git commit -m "chore: backfill Changes for release v1.2.0"
git push --set-upstream origin chore/backfill-changes
gh pr create --base main --title "Backfill Changes for v1.2.0"
```

The script is idempotent — re-running on an already-backfilled file is a no-op. `prepare-release` itself fails loudly with a clear message if invoked before backfill.

## Step 1 — Trigger Prepare Release

1. Go to **Actions → prepare-release** in GitHub.
2. Click **Run workflow**.
3. Pick a `bump` (default `minor`) or type an explicit `version`. Click **Run workflow**.

The workflow:

- Computes the new version from the latest semver tag (accepts both v-prefix and no-prefix tags).
- Calls GitHub's "generate release notes" API for `<last-tag>..main`.
- Prepends a `## <version> — <YYYY-MM-DD>` section to `Changes` containing the generated markdown.
- Bumps `$VERSION` in `lib/JSON/API.pm` (accepts both v-string and quoted-string forms; emits quoted form).
- Commits to a new `release/<version>` branch.
- Opens a PR titled `Release <version>` against `main`.

## Step 2 — Review the release PR

The PR description is **display only**. The `Changes` file in the PR is the canonical source for the release notes — the GitHub release body and the file inside the CPAN tarball will both be generated from it at merge time.

To amend the notes (add prose, fix a wrong PR title, group entries by category), edit `Changes` directly in the PR. Push additional commits to the `release/<version>` branch as needed.

When you're happy, merge the PR.

## Step 3 — Finalize Release (automatic)

On merge, the `finalize-release` workflow:

- Extracts the topmost `## ` section from `Changes`.
- Verifies the section's version matches the branch name (`release/<version>`).
- Tags the merge commit `<version>` (no `v` prefix) and pushes the tag.
- Creates a GitHub release titled `<version>` with the section body as the release notes.

## Step 4 — CPAN upload (automatic)

The existing `publish-cpan` workflow fires on the new release, builds the dist, and uploads the tarball to CPAN. The tarball's `Changes` file contains the new section because the release commit (which the tag points to) included it.

## Versioning convention

Going forward, tags and `$VERSION` use no-prefix semver:

- Tag: `1.3.0`
- Source: `$VERSION = '1.3.0';` (quoted-string form, NOT v-string)
- Tarball: `JSON-API-1.3.0.tar.gz`

Old `v*` tags (v1.2.0 and earlier) stay as historical. PAUSE/MetaCPAN treats both forms as semantically identical version numbers.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `prepare-release` fails with "Tag X.Y.Z already exists" | The bump produced a version that's already tagged. | Pass an explicit `version` input that hasn't been used. |
| `prepare-release` fails with "Branch release/X.Y.Z already exists" | Stale branch from a previous attempt. | Delete the stale branch (`git push origin --delete release/X.Y.Z`) and re-run. |
| `prepare-release` fails with "no commits since X.Y.Z" | Nothing new to release. | Don't release. |
| `prepare-release` fails with "Changes file has no '## X.Y.Z' heading" | `Changes` is in pre-backfill state. | Run the backfill (see Prerequisites). |
| `prepare-release` fails with "failed to update $VERSION" | The line format in `lib/JSON/API.pm` changed and no longer matches the regex. | Update the regex in `ci/scripts/prepare-release.sh`. |
| `finalize-release` tags but fails at `gh release create` (transient) | GitHub API hiccup. | Re-run `finalize-release` manually via `workflow_dispatch` with `tag=X.Y.Z`. **If the failed run partially created the GitHub release (e.g. release exists but is empty/draft), delete it via `gh release delete X.Y.Z` first** — `gh release create` is not idempotent and will error on a duplicate. |
| Version in `Changes` heading doesn't match branch name | Maintainer edited the heading line in the PR but not the branch. | Either rename the branch or fix the heading; finalize-release fails loudly to catch this. |
