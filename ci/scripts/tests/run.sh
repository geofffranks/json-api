#!/usr/bin/env bash
# Minimal shell test harness.
# Discovers ci/scripts/tests/test_*.sh, sources each, and runs every function
# whose name starts with `test_`. A test passes if the function returns 0.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

pass=0
fail=0
failed_tests=()

for test_file in "$SCRIPT_DIR"/test_*.sh; do
    [ -f "$test_file" ] || continue
    # shellcheck disable=SC1090
    source "$test_file"

    while read -r test_fn; do
        [ -n "$test_fn" ] || continue
        printf "  %s ... " "$test_fn"
        if (set -e; "$test_fn"); then
            printf "ok\n"
            pass=$((pass + 1))
        else
            printf "FAIL\n"
            fail=$((fail + 1))
            failed_tests+=("$(basename "$test_file"):$test_fn")
        fi
        unset -f "$test_fn"
    done < <(declare -F | awk '{print $3}' | grep '^test_' || true)
done

echo
echo "Results: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    echo
    echo "Failed:"
    for f in "${failed_tests[@]}"; do
        echo "  - $f"
    done
    exit 1
fi
