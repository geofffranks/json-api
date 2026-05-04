#!/usr/bin/env bash
# One-shot, idempotent backfill of Changes for release v1.2.0 (the single
# release that shipped after the 2026-04-29 Changes deprecation notice).
#
# Required env: GH_TOKEN (gh CLI auth), GITHUB_REPOSITORY (owner/repo).
# Run from repo root. Modifies Changes in-place.
# Re-running is safe: existing sections (matched by '## <version> — ' header)
# are skipped.
#
# The GitHub tag for the version is 'v1.2.0', but the section heading written
# to Changes uses '1.2.0' (no v) since the project is dropping the v-prefix
# going forward. GitHub stores release bodies with CRLF; this script strips
# '\r' so the file in the CPAN tarball uses LF only.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$PWD}"
cd "$REPO_ROOT"

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY env var must be set}"

# Each entry is "version_no_v:gh_tag". Order: oldest first (each is prepended,
# so newest ends up at top after the loop).
ENTRIES=(
    "1.2.0:v1.2.0"
)

if [ ! -f Changes ]; then
    echo "backfill: Changes file is missing" >&2
    exit 1
fi

for entry in "${ENTRIES[@]}"; do
    version="${entry%%:*}"
    gh_tag="${entry##*:}"

    if grep -qE "^## ${version//./\\.} — " Changes; then
        echo "backfill: section for $version already present, skipping"
        continue
    fi

    echo "backfill: fetching $gh_tag..."
    body=$(gh release view "$gh_tag" --repo "$GITHUB_REPOSITORY" --json body --jq '.body' | tr -d '\r')
    date=$(gh release view "$gh_tag" --repo "$GITHUB_REPOSITORY" --json publishedAt --jq '.publishedAt' | cut -dT -f1)

    if [ -z "$body" ] || [ -z "$date" ]; then
        echo "backfill: could not fetch body or date for $gh_tag" >&2
        exit 1
    fi

    section=$(mktemp)
    {
        echo "## ${version} — ${date}"
        echo
        echo "$body"
        echo
    } > "$section"

    new=$(mktemp)
    cat "$section" Changes > "$new"
    mv "$new" Changes
    rm -f "$section"

    echo "backfill: prepended section for $version"
done

# Replace the legacy "no longer updated" notice if present.
if grep -q '^# NOTE: Starting on Apr 29, 2026' Changes; then
    perl -i -0pe '
        s/^# NOTE: Starting on Apr 29, 2026[^\n]*\n[^\n]*\n[^\n]*github\.com\/geofffranks\/json-api\/releases\n\n/# NOTE: Automated tracking resumed 2026-05-04. See https:\/\/github.com\/geofffranks\/json-api\/releases for any older entries pre-1.2.0.\n\n/m
    ' Changes
fi

echo "backfill: done. Review the diff before committing."
