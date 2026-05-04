#!/usr/bin/env bash
# Extract the topmost '## X.Y.Z' section from a Changes file.
#
# Usage:
#   extract-release-section.sh --changes-file <path> --version-only
#   extract-release-section.sh --changes-file <path> --out-file <path>
#
# In --version-only mode, prints the version on stdout. The version must
# match X.Y.Z.
#
# In --out-file mode, writes the section body (everything after the first
# '## X.Y.Z' heading, up to but not including the next '## X.Y.Z' heading)
# to the file at --out-file, and prints the parsed version to stdout.
#
# Section boundaries are version headings only — '## What's Changed' and
# similar non-version subheadings are preserved as body content.
#
# Exit non-zero if there is no '## ' heading or the heading is not semver.

set -euo pipefail

CHANGES_FILE=""
OUT_FILE=""
VERSION_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --changes-file)
            [ -n "${2-}" ] || { echo "extract-release-section: --changes-file requires a value" >&2; exit 2; }
            CHANGES_FILE=$2; shift 2 ;;
        --out-file)
            [ -n "${2-}" ] || { echo "extract-release-section: --out-file requires a value" >&2; exit 2; }
            OUT_FILE=$2; shift 2 ;;
        --version-only) VERSION_ONLY=1;  shift ;;
        *) echo "extract-release-section: unknown arg '$1'" >&2; exit 2 ;;
    esac
done

if [ -z "$CHANGES_FILE" ]; then
    echo "extract-release-section: --changes-file is required" >&2
    exit 2
fi
if [ ! -f "$CHANGES_FILE" ]; then
    echo "extract-release-section: $CHANGES_FILE does not exist" >&2
    exit 2
fi
if [ "$VERSION_ONLY" -eq 0 ] && [ -z "$OUT_FILE" ]; then
    echo "extract-release-section: either --version-only or --out-file is required" >&2
    exit 2
fi

heading_line=$(grep -m1 '^## ' "$CHANGES_FILE" || true)
if [ -z "$heading_line" ]; then
    echo "extract-release-section: no '## ' heading found in $CHANGES_FILE" >&2
    exit 1
fi

version=$(echo "$heading_line" | sed -E 's/^## ([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "extract-release-section: heading does not start with X.Y.Z: '$heading_line'" >&2
    exit 1
fi

echo "$version"

if [ "$VERSION_ONLY" -eq 1 ]; then
    exit 0
fi

awk '
    BEGIN { found = 0 }
    /^## [0-9]+\.[0-9]+\.[0-9]+/ {
        if (!found) { found = 1; next }
        else exit
    }
    found { print }
' "$CHANGES_FILE" > "$OUT_FILE"
