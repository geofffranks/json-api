#!/usr/bin/env bash
# Tests for ci/scripts/lib/semver.sh

# shellcheck source=../lib/semver.sh
source "$REPO_ROOT/ci/scripts/lib/semver.sh"

assert_eq() {
    local expected=$1 actual=$2 msg=${3:-}
    if [ "$expected" != "$actual" ]; then
        echo "    expected: '$expected'"
        echo "    actual:   '$actual'"
        [ -n "$msg" ] && echo "    msg:      $msg"
        return 1
    fi
}

test_semver_bump_patch() {
    assert_eq "1.2.1" "$(semver_bump 1.2.0 patch)"
}

test_semver_bump_minor() {
    assert_eq "1.3.0" "$(semver_bump 1.2.0 minor)"
    assert_eq "1.3.0" "$(semver_bump 1.2.5 minor)"
}

test_semver_bump_major() {
    assert_eq "2.0.0" "$(semver_bump 1.2.0 major)"
    assert_eq "2.0.0" "$(semver_bump 1.2.5 major)"
}

test_semver_bump_strips_v_prefix_input() {
    assert_eq "1.3.0" "$(semver_bump v1.2.0 minor)"
}

test_semver_bump_rejects_unknown_part() {
    if semver_bump 1.2.0 huge >/dev/null 2>&1; then
        return 1
    fi
}

test_semver_bump_rejects_non_semver() {
    if semver_bump "not-a-version" minor >/dev/null 2>&1; then
        return 1
    fi
}

test_semver_validate_accepts() {
    semver_validate 1.2.0
}

test_semver_validate_accepts_zero_zero_zero() {
    semver_validate 0.0.0
}

test_semver_validate_rejects_missing_part() {
    if semver_validate 1.2 >/dev/null 2>&1; then
        return 1
    fi
}

test_semver_validate_rejects_v_prefix() {
    if semver_validate v1.2.0 >/dev/null 2>&1; then
        return 1
    fi
}

test_semver_validate_rejects_leading_zero_major() {
    if semver_validate 01.0.0 >/dev/null 2>&1; then
        return 1
    fi
}

test_semver_validate_rejects_leading_zero_minor() {
    if semver_validate 0.09.0 >/dev/null 2>&1; then
        return 1
    fi
}
