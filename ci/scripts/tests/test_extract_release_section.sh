#!/usr/bin/env bash
# Tests for ci/scripts/extract-release-section.sh

EXTRACT="$REPO_ROOT/ci/scripts/extract-release-section.sh"
FIXTURE="$REPO_ROOT/ci/scripts/tests/fixtures/Changes.fixture.md"

assert_eq() {
    local expected=$1 actual=$2
    if [ "$expected" != "$actual" ]; then
        echo "    expected: '$expected'"
        echo "    actual:   '$actual'"
        return 1
    fi
}

test_extract_version_only() {
    local v
    v=$("$EXTRACT" --changes-file "$FIXTURE" --version-only)
    assert_eq "1.3.0" "$v"
}

test_extract_body_to_file() {
    local out
    out=$(mktemp)
    "$EXTRACT" --changes-file "$FIXTURE" --out-file "$out" >/dev/null
    local first
    first=$(grep -m1 -v '^[[:space:]]*$' "$out")
    rm -f "$out"
    assert_eq "## What's Changed" "$first"
}

test_extract_body_stops_at_next_section() {
    local out
    out=$(mktemp)
    "$EXTRACT" --changes-file "$FIXTURE" --out-file "$out" >/dev/null
    if grep -q '^## 1\.2\.0' "$out"; then
        rm -f "$out"
        return 1
    fi
    if ! grep -q '1.2.0...1.3.0' "$out"; then
        rm -f "$out"
        return 1
    fi
    rm -f "$out"
}

test_extract_fails_when_no_section() {
    local empty
    empty=$(mktemp)
    echo "no headings here" > "$empty"
    if "$EXTRACT" --changes-file "$empty" --version-only >/dev/null 2>&1; then
        rm -f "$empty"
        return 1
    fi
    rm -f "$empty"
}

test_extract_fails_when_heading_not_semver() {
    local bad
    bad=$(mktemp)
    cat > "$bad" <<'EOF'
## not-a-version — 2026-05-04

body
EOF
    if "$EXTRACT" --changes-file "$bad" --version-only >/dev/null 2>&1; then
        rm -f "$bad"
        return 1
    fi
    rm -f "$bad"
}

test_extract_fails_with_missing_flag_value() {
    local err exit_code
    err=$("$EXTRACT" --changes-file 2>&1)
    exit_code=$?
    if [ "$exit_code" -ne 2 ]; then
        echo "    expected exit 2, got $exit_code"
        return 1
    fi
    if ! echo "$err" | grep -q 'requires a value'; then
        echo "    expected error to mention 'requires a value', got: $err"
        return 1
    fi
}
