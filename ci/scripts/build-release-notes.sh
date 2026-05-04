#!/usr/bin/env bash
# Generate auto release notes via GitHub's API.
#
# Required env: GH_TOKEN (gh CLI auth), GITHUB_REPOSITORY (owner/repo).
# Args:
#   --new-version <X.Y.Z>     Tag name to be created.
#   --previous-tag <ref>      Last released tag, used as comparison base.
#                             (May still be the v-prefixed legacy form, e.g. v1.2.0.)
#   --target-commitish <ref>  Branch or commit (default: main).
#
# Output:
#   Writes the markdown body to stdout. Exits 0 on success, non-zero on error.
#   GitHub stores release bodies with CRLF (web textarea source); this script
#   strips '\r' so the output uses LF only.

set -euo pipefail

NEW_VERSION=""
PREVIOUS_TAG=""
TARGET_COMMITISH="main"

while [ $# -gt 0 ]; do
    case "$1" in
        --new-version)
            [ -n "${2-}" ] || { echo "build-release-notes: --new-version requires a value" >&2; exit 2; }
            NEW_VERSION=$2; shift 2 ;;
        --previous-tag)
            [ -n "${2-}" ] || { echo "build-release-notes: --previous-tag requires a value" >&2; exit 2; }
            PREVIOUS_TAG=$2; shift 2 ;;
        --target-commitish)
            [ -n "${2-}" ] || { echo "build-release-notes: --target-commitish requires a value" >&2; exit 2; }
            TARGET_COMMITISH=$2; shift 2 ;;
        *) echo "build-release-notes: unknown arg '$1'" >&2; exit 2 ;;
    esac
done

: "${NEW_VERSION:?--new-version is required}"
: "${PREVIOUS_TAG:?--previous-tag is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY env var must be set (e.g. owner/repo)}"

gh api \
    --method POST \
    -H "Accept: application/vnd.github+json" \
    "/repos/${GITHUB_REPOSITORY}/releases/generate-notes" \
    -f "tag_name=${NEW_VERSION}" \
    -f "previous_tag_name=${PREVIOUS_TAG}" \
    -f "target_commitish=${TARGET_COMMITISH}" \
    --jq '.body' \
    | tr -d '\r'
