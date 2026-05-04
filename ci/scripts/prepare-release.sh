#!/usr/bin/env bash
# Orchestrate "prepare release":
#   - resolve target version (BUMP or VERSION_OVERRIDE)
#   - validate (no existing tag, no existing release branch, commits exist)
#   - generate release notes via build-release-notes.sh
#   - prepend a section to Changes
#   - bump $VERSION in lib/JSON/API.pm (handles both v-string and quoted forms)
#   - commit on a new branch release/<version>
#
# Required env:
#   BUMP                 patch|minor|major (used if VERSION_OVERRIDE empty)
#   VERSION_OVERRIDE     optional explicit X.Y.Z; takes precedence over BUMP
#   GH_TOKEN             gh CLI auth
#   GITHUB_REPOSITORY    owner/repo
#   GITHUB_OUTPUT        path for workflow outputs (set by GitHub Actions; optional locally)
# Optional env:
#   DRY_RUN              if set to '1', describe actions without git/branch push
#   REPO_ROOT            defaults to current working directory
#   GIT_USER_NAME        defaults to 'github-actions[bot]'
#   GIT_USER_EMAIL       defaults to '41898282+github-actions[bot]@users.noreply.github.com'
#
# Outputs (when GITHUB_OUTPUT is set):
#   version=<X.Y.Z>
#   branch=release/<X.Y.Z>
#   pr_body_file=<absolute path>

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$PWD}"
DRY_RUN="${DRY_RUN:-0}"
GIT_USER_NAME="${GIT_USER_NAME:-github-actions[bot]}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/semver.sh
source "$SCRIPT_DIR/lib/semver.sh"

cd "$REPO_ROOT"

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY env var must be set}"

run() {
    if [ "$DRY_RUN" = "1" ]; then
        echo "DRY_RUN: $*"
    else
        "$@"
    fi
}

# 1. Resolve target version. Look at both no-prefix tags and v-prefix tags
# (the project is transitioning from v-prefix to no-prefix). Highest semver
# wins regardless of prefix.
LAST_TAG=$(git tag --sort=-version:refname | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
if [ -z "$LAST_TAG" ]; then
    echo "prepare-release: no semver-style tag found in repo" >&2
    exit 1
fi
LAST_VERSION="${LAST_TAG#v}"

if [ -n "${VERSION_OVERRIDE:-}" ]; then
    semver_validate "$VERSION_OVERRIDE"
    NEW_VERSION="$VERSION_OVERRIDE"
else
    : "${BUMP:?BUMP env var is required when VERSION_OVERRIDE is unset}"
    NEW_VERSION=$(semver_bump "$LAST_VERSION" "$BUMP")
fi

echo "prepare-release: last tag = $LAST_TAG"
echo "prepare-release: new version = $NEW_VERSION"

# 2. Validate.
if git rev-parse "refs/tags/$NEW_VERSION" >/dev/null 2>&1; then
    echo "prepare-release: tag $NEW_VERSION already exists" >&2
    exit 1
fi
if git show-ref --quiet "refs/heads/release/$NEW_VERSION"; then
    echo "prepare-release: branch release/$NEW_VERSION already exists locally" >&2
    exit 1
fi
if git ls-remote --exit-code --heads origin "release/$NEW_VERSION" >/dev/null 2>&1; then
    echo "prepare-release: branch release/$NEW_VERSION already exists on origin" >&2
    exit 1
fi

if [ -z "$(git log "${LAST_TAG}..HEAD" --oneline)" ]; then
    echo "prepare-release: no commits since $LAST_TAG, nothing to release" >&2
    exit 1
fi

# 3. Generate release notes.
PR_BODY_FILE="$(mktemp -t prepare-release.XXXXXX)"
"$SCRIPT_DIR/build-release-notes.sh" \
    --new-version "$NEW_VERSION" \
    --previous-tag "$LAST_TAG" \
    --target-commitish main \
    > "$PR_BODY_FILE"

if [ ! -s "$PR_BODY_FILE" ]; then
    echo "prepare-release: WARNING — generated release notes are empty. Maintainer should fill in the section in the PR." >&2
    echo "_(Auto-generated notes were empty — please fill in.)_" > "$PR_BODY_FILE"
fi

# 4. Prepend a new section to Changes.
TODAY=$(date -u +%Y-%m-%d)
NEW_SECTION="$(mktemp -t prepare-release-section.XXXXXX)"
{
    echo "## ${NEW_VERSION} — ${TODAY}"
    echo
    cat "$PR_BODY_FILE"
    echo
} > "$NEW_SECTION"

if [ ! -f Changes ]; then
    echo "prepare-release: Changes file is missing from repo root" >&2
    exit 1
fi

# Guard: Changes must already contain at least one '## X.Y.Z' heading so that
# finalize-release's extract-release-section.sh has a bounded section to read.
# If the file is in pre-backfill state, extract-release-section would read to
# EOF and embed the entire legacy changelog into the release body. Run
# ci/scripts/backfill-changes.sh and merge that PR before triggering
# prepare-release for the first time.
if ! grep -qE '^## [0-9]+\.[0-9]+\.[0-9]+' Changes; then
    echo "prepare-release: Changes file has no '## X.Y.Z' heading. The file is in legacy format." >&2
    echo "prepare-release: Run ci/scripts/backfill-changes.sh and merge that PR before the first release." >&2
    exit 1
fi

NEW_CHANGES="$(mktemp -t prepare-release-changes.XXXXXX)"
cat "$NEW_SECTION" Changes > "$NEW_CHANGES"
mv "$NEW_CHANGES" Changes
rm -f "$NEW_SECTION"

# 5. Bump $VERSION in lib/JSON/API.pm. Accept v-string OR quoted form;
# always emit quoted form.
perl -i -pe "s/^(\\s*)\\\$VERSION\\s*=\\s*['\"]?v?[0-9.]+['\"]?;/\$1\\\$VERSION = '${NEW_VERSION}';/" lib/JSON/API.pm
if ! grep -qF "\$VERSION = '${NEW_VERSION}';" lib/JSON/API.pm; then
    echo "prepare-release: failed to update \$VERSION in lib/JSON/API.pm (regex didn't match — has the line format changed?)" >&2
    exit 1
fi

# 6. Commit on release branch.
run git config user.name  "$GIT_USER_NAME"
run git config user.email "$GIT_USER_EMAIL"
run git checkout -b "release/$NEW_VERSION"
run git add Changes lib/JSON/API.pm
run git commit -m "release ${NEW_VERSION}"
run git push --set-upstream origin "release/$NEW_VERSION"

# 7. Emit outputs for the workflow.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "version=$NEW_VERSION"
        echo "branch=release/$NEW_VERSION"
        echo "pr_body_file=$PR_BODY_FILE"
    } >> "$GITHUB_OUTPUT"
fi

echo "prepare-release: done. version=$NEW_VERSION branch=release/$NEW_VERSION pr_body_file=$PR_BODY_FILE"
