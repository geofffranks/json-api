# Automated Changelog Implementation Plan (JSON::API)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resume automated maintenance of the `Changes` file in `JSON::API`, with the same source-of-truth + workflow_dispatch flow shipped in `test-mockmodule`. Bundle a one-time conversion of `$VERSION` from Perl v-string syntax to quoted-string form so the project drops the `v` prefix from tags / releases / tarballs going forward.

**Architecture:** Two new GitHub Actions workflows (`prepare-release.yml`, `finalize-release.yml`), four helper shell scripts in `ci/scripts/`, a one-shot backfill of v1.2.0, modifications to `publish-cpan.yml` (drop v-prefix gate, update version regex), modifications to `MANIFEST.SKIP` (add several exclusions absent from this repo), one-line conversion of `$VERSION` in `lib/JSON/API.pm`. `Changes` is the single source of truth for release notes; `finalize-release` extracts the topmost `## X.Y.Z` section as the GitHub release body.

**Tech Stack:** GitHub Actions (YAML), Bash, `gh` CLI, `jq`, `actionlint`, `shellcheck`, Perl 5.

**Spec:** [docs/superpowers/specs/2026-05-04-automated-changelog-design.md](../specs/2026-05-04-automated-changelog-design.md)
**Prior art:** Same flow shipped in test-mockmodule. The four helper scripts in this plan are essentially copies, with these adaptations:
- `prepare-release.sh` regex matches v-string AND quoted-string forms
- `build-release-notes.sh` strips CRLF from gh output (lesson from test-mockmodule's fix)
- `backfill-changes.sh` strips CRLF and handles a single version
- All other scripts and lib are identical

---

## File Structure

**Created:**

| Path | Responsibility |
|---|---|
| `ci/scripts/lib/semver.sh` | Pure-bash semver parse and bump. Sourced by other scripts. |
| `ci/scripts/extract-release-section.sh` | Extract topmost `## X.Y.Z` section from `Changes`. |
| `ci/scripts/build-release-notes.sh` | Wrap `gh api .../releases/generate-notes`. |
| `ci/scripts/prepare-release.sh` | Orchestrate: validate, build notes, prepend section, bump $VERSION, commit. |
| `ci/scripts/backfill-changes.sh` | One-shot, idempotent backfill of v1.2.0. |
| `ci/scripts/tests/run.sh` | Minimal shell test harness. |
| `ci/scripts/tests/test_semver.sh` | TDD tests for `semver.sh`. |
| `ci/scripts/tests/test_extract_release_section.sh` | TDD tests for `extract-release-section.sh`. |
| `ci/scripts/tests/fixtures/Changes.fixture.md` | Fixture. |
| `.github/workflows/prepare-release.yml` | `workflow_dispatch` → release PR. |
| `.github/workflows/finalize-release.yml` | PR merge → tag + GitHub release. |
| `.github/workflows/lint-release-tooling.yml` | actionlint, shellcheck, shell-tests. |
| `RELEASING.md` | Maintainer-facing release flow doc. |

**Modified:**

| Path | Why |
|---|---|
| `Changes` | Backfill v1.2.0 section; replace deprecation notice. |
| `MANIFEST.SKIP` | Add `^ci\b`, `\B\.github\b`, `^RELEASING\.md`, `^docs\b`, broaden the dist tarball pattern. |
| `lib/JSON/API.pm` | Convert `$VERSION = v1.2.0;` → `$VERSION = '1.2.0';` (one-time, drops v-string syntax). |
| `.github/workflows/publish-cpan.yml` | Drop the `'refs/tags/v'` gate; update version-patch regex to handle both forms. |

---

## Cross-cutting decisions

- **Bot identity for commits made by `prepare-release.yml`:** `github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>`.
- **Tag/version format going forward:** no `v` prefix (e.g. `1.3.0`). Old `v*` tags stay as historical.
- **Default branch:** `main`.
- **Test runner for new shell code:** `bash ci/scripts/tests/run.sh`. No `bats` dependency.
- **Lint gating:** `actionlint`, `shellcheck`, and the shell test harness must all pass before each commit.
- **Out of scope:** anything else in `lib/JSON/API.pm` (the actual JSON API logic), `debian/`, `json-api.spec`, `t/`, `testsuite.yml`, `lint.yml`.

---

## Task 1: Add lint job for the new release tooling

**Files:**
- Create: `.github/workflows/lint-release-tooling.yml`

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/lint-release-tooling.yml`:

```yaml
name: lint-release-tooling

on:
  push:
    branches:
      - '*'
    tags-ignore:
      - '*'
  pull_request:

jobs:
  actionlint:
    name: actionlint
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - name: Run actionlint
        uses: raven-actions/actionlint@v2
        with:
          files: ".github/workflows/*.yml"

  shellcheck:
    name: shellcheck
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - name: Install shellcheck
        run: sudo apt-get update && sudo apt-get install -y shellcheck
      - name: Run shellcheck
        run: |
          if [ -d ci/scripts ]; then
            find ci/scripts -type f -name '*.sh' -print0 \
              | xargs -0 -r shellcheck --shell=bash --severity=warning
          fi

  shell-tests:
    name: shell tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - name: Run shell tests
        run: |
          if [ -x ci/scripts/tests/run.sh ]; then
            bash ci/scripts/tests/run.sh
          else
            echo "ci/scripts/tests/run.sh not present yet — skipping"
          fi
```

- [ ] **Step 2: Verify workflow YAML parses**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/lint-release-tooling.yml'))" && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/lint-release-tooling.yml
git commit -m "ci: add lint job for release tooling (actionlint, shellcheck, shell-tests)"
```

---

## Task 2: Build minimal shell test harness

**Files:**
- Create: `ci/scripts/tests/run.sh`

- [ ] **Step 1: Write the harness**

Create `ci/scripts/tests/run.sh`:

```bash
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
```

Make it executable:

```bash
chmod +x ci/scripts/tests/run.sh
```

- [ ] **Step 2: Verify harness runs cleanly with no tests yet**

Run: `bash ci/scripts/tests/run.sh`
Expected: `Results: 0 passed, 0 failed` (exit 0).

- [ ] **Step 3: Lint**

Run: `shellcheck --shell=bash --severity=warning ci/scripts/tests/run.sh`
Expected: no output, exit 0.

- [ ] **Step 4: Commit**

```bash
git add ci/scripts/tests/run.sh
git commit -m "ci: add minimal shell test harness for release tooling"
```

---

## Task 3: TDD semver bump library

**Files:**
- Create: `ci/scripts/lib/semver.sh`
- Test: `ci/scripts/tests/test_semver.sh`

- [ ] **Step 1: Write the failing tests**

Create `ci/scripts/tests/test_semver.sh`:

```bash
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
```

- [ ] **Step 2: Run tests — verify they fail**

Run: `bash ci/scripts/tests/run.sh`
Expected: failures because `ci/scripts/lib/semver.sh` doesn't exist yet (the source statement will fail to find the file).

- [ ] **Step 3: Write the library**

Create `ci/scripts/lib/semver.sh`:

```bash
#!/usr/bin/env bash
# Semver helpers. Use: `source ci/scripts/lib/semver.sh` from another script.
# All functions return non-zero on invalid input and write a message to stderr.

# semver_validate <version>
# Validates that <version> is a strict X.Y.Z (no v prefix, no pre-release,
# no leading zeros).
semver_validate() {
    local v=$1
    if [[ ! "$v" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
        echo "semver_validate: not a valid X.Y.Z version: '$v'" >&2
        return 1
    fi
}

# semver_bump <version> <part>
# part = patch | minor | major
# Strips a leading 'v' from <version> for convenience but emits no v in output.
semver_bump() {
    local current=$1 part=$2
    current="${current#v}"
    if ! semver_validate "$current"; then
        return 1
    fi
    local maj min pat
    IFS=. read -r maj min pat <<< "$current"
    case "$part" in
        major) echo "$((10#$maj + 1)).0.0" ;;
        minor) echo "${maj}.$((10#$min + 1)).0" ;;
        patch) echo "${maj}.${min}.$((10#$pat + 1))" ;;
        *)
            echo "semver_bump: unknown part '$part' (expected patch|minor|major)" >&2
            return 1
            ;;
    esac
}
```

- [ ] **Step 4: Run tests — verify they pass**

Run: `bash ci/scripts/tests/run.sh`
Expected: `Results: 12 passed, 0 failed`.

- [ ] **Step 5: Lint**

Run: `shellcheck --shell=bash --severity=warning ci/scripts/lib/semver.sh ci/scripts/tests/test_semver.sh`
Expected: no output, exit 0.

- [ ] **Step 6: Commit**

```bash
git add ci/scripts/lib/semver.sh ci/scripts/tests/test_semver.sh
git commit -m "ci: add semver bump library with TDD coverage"
```

---

## Task 4: TDD extract-release-section.sh

**Files:**
- Create: `ci/scripts/extract-release-section.sh`
- Create: `ci/scripts/tests/fixtures/Changes.fixture.md`
- Create: `ci/scripts/tests/test_extract_release_section.sh`

- [ ] **Step 1: Create the fixture**

Create `ci/scripts/tests/fixtures/Changes.fixture.md`:

```markdown
## 1.3.0 — 2026-05-04

## What's Changed
* feat: shiny thing by @koan-bot in https://example.com/pr/100
* fix: small issue by @geofffranks in https://example.com/pr/101

**Full Changelog**: https://example.com/compare/1.2.0...1.3.0

## 1.2.0 — 2026-04-29

## What's Changed
* feat: add patch method by @mat813 in https://example.com/pr/9

**Full Changelog**: https://example.com/compare/v1.1.1...v1.2.0

# NOTE: Older entries omitted in fixture for brevity.
```

- [ ] **Step 2: Write the failing tests**

Create `ci/scripts/tests/test_extract_release_section.sh`:

```bash
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
```

- [ ] **Step 3: Run tests — verify they fail**

Run: `bash ci/scripts/tests/run.sh`
Expected: failures from the new tests (the script doesn't exist yet).

- [ ] **Step 4: Write the script**

Create `ci/scripts/extract-release-section.sh`:

```bash
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
```

Make executable:

```bash
chmod +x ci/scripts/extract-release-section.sh
```

- [ ] **Step 5: Run tests — verify they pass**

Run: `bash ci/scripts/tests/run.sh`
Expected: previous 12 + 6 new = `Results: 18 passed, 0 failed`.

- [ ] **Step 6: Lint**

Run: `shellcheck --shell=bash --severity=warning ci/scripts/extract-release-section.sh ci/scripts/tests/test_extract_release_section.sh`
Expected: no output, exit 0.

- [ ] **Step 7: Commit**

```bash
git add ci/scripts/extract-release-section.sh ci/scripts/tests/test_extract_release_section.sh ci/scripts/tests/fixtures/Changes.fixture.md
git commit -m "ci: extract-release-section helper with TDD coverage"
```

---

## Task 5: Build build-release-notes.sh

A thin wrapper around `gh api .../releases/generate-notes`. Includes CRLF-stripping from the start (lesson from test-mockmodule).

**Files:**
- Create: `ci/scripts/build-release-notes.sh`

- [ ] **Step 1: Write the script**

Create `ci/scripts/build-release-notes.sh`:

```bash
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
```

Make executable:

```bash
chmod +x ci/scripts/build-release-notes.sh
```

- [ ] **Step 2: Lint**

Run: `shellcheck --shell=bash --severity=warning ci/scripts/build-release-notes.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Smoke-test against the live repo**

Requires `gh auth status` to be logged in. This will not modify anything.

```bash
GITHUB_REPOSITORY=geofffranks/json-api \
    bash ci/scripts/build-release-notes.sh \
    --new-version 1.3.0 \
    --previous-tag v1.2.0 \
    --target-commitish main \
    | head -20
```
Expected: markdown content beginning with `## What's Changed`, OR empty (if there are no commits since v1.2.0 — possible since the most recent commits are CI/test changes that may or may not have been merged via PRs depending on history). Either is fine for a smoke test.

Confirm no `^M` characters in the output:
```bash
GITHUB_REPOSITORY=geofffranks/json-api \
    bash ci/scripts/build-release-notes.sh \
    --new-version 1.3.0 \
    --previous-tag v1.2.0 \
    --target-commitish main \
    | cat -A | head -5
```
Expected: each line ends with `$`, no `^M$` patterns.

- [ ] **Step 4: Commit**

```bash
git add ci/scripts/build-release-notes.sh
git commit -m "ci: build-release-notes wrapper for GitHub generate-notes API"
```

---

## Task 6: Build prepare-release.sh orchestrator

Orchestrates the prepare-release workflow's logic. Supports `DRY_RUN=1`. The `$VERSION` regex accepts BOTH the old v-string form (`$VERSION = v1.2.0;`) AND the new quoted form (`$VERSION = '1.2.0';`) and always emits the quoted form.

**Files:**
- Create: `ci/scripts/prepare-release.sh`

- [ ] **Step 1: Write the script**

Create `ci/scripts/prepare-release.sh`:

```bash
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
```

Make executable:

```bash
chmod +x ci/scripts/prepare-release.sh
```

- [ ] **Step 2: Lint**

Run: `shellcheck --shell=bash --severity=warning ci/scripts/prepare-release.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Run shell tests to confirm no regressions**

Run: `bash ci/scripts/tests/run.sh`
Expected: `Results: 18 passed, 0 failed`.

- [ ] **Step 4: DRY_RUN smoke test**

**Critical:** the script mutates `Changes` and `lib/JSON/API.pm` unconditionally — DRY_RUN only gates git ops. After the test, you MUST roll back the file changes.

This task expects the existing un-backfilled `Changes` to fail the new pre-backfill guard. That's the correct behavior.

```bash
git status --short  # should be clean (or only have the new prepare-release.sh as untracked)

DRY_RUN=1 BUMP=minor GITHUB_REPOSITORY=geofffranks/json-api \
    bash ci/scripts/prepare-release.sh 2>&1 | tail -10
```
Expected output ends with:
```
prepare-release: Changes file has no '## X.Y.Z' heading. The file is in legacy format.
prepare-release: Run ci/scripts/backfill-changes.sh and merge that PR before the first release.
```
(Exit code 1.)

This proves the guard works. The `Changes` and `lib/JSON/API.pm` files were NOT mutated since the guard fired before the prepend step. Verify:

```bash
git diff --stat
```
Expected: no diff.

- [ ] **Step 5: Commit**

```bash
git add ci/scripts/prepare-release.sh
git commit -m "ci: prepare-release orchestrator (validates, notes, bumps, commits)"
```

---

## Task 7: prepare-release.yml workflow

**Files:**
- Create: `.github/workflows/prepare-release.yml`

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/prepare-release.yml`:

```yaml
name: prepare-release

on:
  workflow_dispatch:
    inputs:
      bump:
        description: "Semver part to bump (ignored if 'version' is set)"
        required: false
        default: minor
        type: choice
        options:
          - patch
          - minor
          - major
      version:
        description: "Explicit X.Y.Z version (overrides 'bump' if non-empty)"
        required: false
        default: ""
        type: string

concurrency:
  group: release-prep
  cancel-in-progress: false

jobs:
  prepare:
    name: Prepare release PR
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0

      - name: Run prepare-release
        id: prepare
        env:
          BUMP: ${{ inputs.bump }}
          VERSION_OVERRIDE: ${{ inputs.version }}
          GITHUB_REPOSITORY: ${{ github.repository }}
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: bash ci/scripts/prepare-release.sh

      - name: Open release PR
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          PR_BODY_FILE: ${{ steps.prepare.outputs.pr_body_file }}
          PR_BRANCH: ${{ steps.prepare.outputs.branch }}
          PR_VERSION: ${{ steps.prepare.outputs.version }}
        run: |
          set -euo pipefail
          BODY_WITH_NOTE=$(mktemp)
          cat > "$BODY_WITH_NOTE" <<'NOTE_EOF'
          > **Reviewer note:** the `Changes` file in this PR is the source of truth for the release notes. The GitHub release body and CPAN tarball will be generated from the topmost section of `Changes` at merge time. Edits to **this PR description** will NOT be reflected in either — edit `Changes` directly if you want to amend the notes.

          NOTE_EOF
          cat "$PR_BODY_FILE" >> "$BODY_WITH_NOTE"

          gh pr create \
              --base main \
              --head "$PR_BRANCH" \
              --title "Release ${PR_VERSION}" \
              --body-file "$BODY_WITH_NOTE" \
              --label release
```

- [ ] **Step 2: Validate workflow YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/prepare-release.yml'))" && echo OK`
Expected: `OK`.

- [ ] **Step 3: Ensure the `release` label exists on the repo**

```bash
if gh label list --repo geofffranks/json-api --json name --jq '.[].name' | grep -Fxq release; then
    echo "release label already exists"
else
    gh label create release --repo geofffranks/json-api --description "Release PR" --color FBCA04
fi
```

(If the `gh label create` write is blocked by a hook, ask the user to run it once.)

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/prepare-release.yml
git commit -m "ci: add prepare-release workflow (workflow_dispatch -> release PR)"
```

---

## Task 8: finalize-release.yml workflow

**Files:**
- Create: `.github/workflows/finalize-release.yml`

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/finalize-release.yml`:

```yaml
name: finalize-release

on:
  pull_request:
    types: [closed]
    branches: [main]
  workflow_dispatch:
    inputs:
      tag:
        description: "Existing tag to (re)create the GitHub release for"
        required: true
        type: string

concurrency:
  group: release-finalize-${{ github.event.pull_request.number || inputs.tag }}
  cancel-in-progress: false

jobs:
  finalize:
    name: Finalize release
    if: |
      github.event_name == 'workflow_dispatch'
      || (github.event.pull_request.merged == true && startsWith(github.event.pull_request.head.ref, 'release/'))
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: read
    steps:
      - name: Checkout merge commit
        if: github.event_name == 'pull_request'
        uses: actions/checkout@v6
        with:
          ref: ${{ github.event.pull_request.merge_commit_sha }}
          fetch-depth: 0

      - name: Checkout tag (retry path)
        if: github.event_name == 'workflow_dispatch'
        uses: actions/checkout@v6
        with:
          ref: ${{ inputs.tag }}
          fetch-depth: 0

      - name: Extract release section from Changes
        id: extract
        run: |
          set -euo pipefail
          BODY_FILE=$(mktemp)
          VERSION=$(bash ci/scripts/extract-release-section.sh \
              --changes-file Changes \
              --out-file "$BODY_FILE")
          echo "version=$VERSION"          >> "$GITHUB_OUTPUT"
          echo "body_file=$BODY_FILE"      >> "$GITHUB_OUTPUT"

      - name: Verify version matches branch (PR path)
        if: github.event_name == 'pull_request'
        env:
          PR_BRANCH: ${{ github.event.pull_request.head.ref }}
          EXTRACTED_VERSION: ${{ steps.extract.outputs.version }}
        run: |
          set -euo pipefail
          BRANCH_VERSION="${PR_BRANCH#release/}"
          if [ "$BRANCH_VERSION" != "$EXTRACTED_VERSION" ]; then
            echo "finalize-release: branch version '$BRANCH_VERSION' does not match Changes section version '$EXTRACTED_VERSION'" >&2
            exit 1
          fi

      - name: Verify version matches input tag (retry path)
        if: github.event_name == 'workflow_dispatch'
        env:
          INPUT_TAG: ${{ inputs.tag }}
          EXTRACTED_VERSION: ${{ steps.extract.outputs.version }}
        run: |
          set -euo pipefail
          if [ "$INPUT_TAG" != "$EXTRACTED_VERSION" ]; then
            echo "finalize-release: input tag '$INPUT_TAG' does not match Changes section version '$EXTRACTED_VERSION'" >&2
            exit 1
          fi

      - name: Tag and push (PR path only)
        if: github.event_name == 'pull_request'
        env:
          VERSION: ${{ steps.extract.outputs.version }}
        run: |
          set -euo pipefail
          git config user.name  "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git tag -a "$VERSION" -m "release $VERSION"
          git push origin "refs/tags/$VERSION"

      - name: Create GitHub release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          VERSION: ${{ steps.extract.outputs.version }}
          BODY_FILE: ${{ steps.extract.outputs.body_file }}
        run: |
          set -euo pipefail
          gh release create "$VERSION" \
              --title "$VERSION" \
              --notes-file "$BODY_FILE"
```

- [ ] **Step 2: Validate workflow YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/finalize-release.yml'))" && echo OK`
Expected: `OK`.

- [ ] **Step 3: Run shell tests to confirm no regressions**

Run: `bash ci/scripts/tests/run.sh`
Expected: `Results: 18 passed, 0 failed`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/finalize-release.yml
git commit -m "ci: add finalize-release workflow (tag + create GH release on PR merge)"
```

---

## Task 9: Build backfill-changes.sh

One-shot, idempotent. Pulls v1.2.0's release body from GitHub and prepends a `## 1.2.0 — 2026-04-29` section. Replaces the deprecation notice. Includes CRLF stripping.

**Files:**
- Create: `ci/scripts/backfill-changes.sh`

- [ ] **Step 1: Write the script**

Create `ci/scripts/backfill-changes.sh`:

```bash
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
```

Make executable:

```bash
chmod +x ci/scripts/backfill-changes.sh
```

- [ ] **Step 2: Lint**

Run: `shellcheck --shell=bash --severity=warning ci/scripts/backfill-changes.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Confirm tests still pass**

Run: `bash ci/scripts/tests/run.sh`
Expected: `Results: 18 passed, 0 failed`.

- [ ] **Step 4: Commit (script only — running it is Task 13)**

```bash
git add ci/scripts/backfill-changes.sh
git commit -m "ci: add one-shot backfill script for Changes (v1.2.0)"
```

---

## Task 10: Add RELEASING.md and update MANIFEST.SKIP

**Files:**
- Create: `RELEASING.md`
- Modify: `MANIFEST.SKIP`

- [ ] **Step 1: Write RELEASING.md**

Create `RELEASING.md`:

````markdown
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
| `finalize-release` tags but fails at `gh release create` (transient) | GitHub API hiccup. | Re-run `finalize-release` manually via `workflow_dispatch` with `tag=X.Y.Z`. |
| Version in `Changes` heading doesn't match branch name | Maintainer edited the heading line in the PR but not the branch. | Either rename the branch or fix the heading; finalize-release fails loudly to catch this. |
````

- [ ] **Step 2: Update MANIFEST.SKIP**

The current `MANIFEST.SKIP` is missing several exclusions. Use the `Edit` tool to add them.

First, `Read` `MANIFEST.SKIP` (required before Edit). Then apply this edit:

Find:
```
\B\.git\b
\B\.gitignore\b
```

Replace with:
```
\B\.git\b
\B\.github\b
\B\.gitignore\b
```

Then find:
```
# Avoid archives of this distribution
^JSON-API-v\d+
^t/tmp
```

Replace with:
```
# ignore ci files
^ci\b

# ignore whitesource
\B\.whitesource

# Avoid archives of this distribution (accept both 'JSON-API-1.x' and 'JSON-API-v1.x')
^JSON-API-v?\d+
^t/tmp

# Avoid maintainer-only docs
^RELEASING\.md
^docs\b
```

(The `\B\.whitesource` line preempts a future inclusion since this repo has a `.whitesource` file.)

- [ ] **Step 3: Verify RELEASING.md and docs/ are excluded**

Use ExtUtils::Manifest's `maniskip` directly (this repo's `Module::Build` is older and may not have a sufficient version for `./Build manifest`):

```bash
cd /Users/gfranks/workspace/json-api
perl -MExtUtils::Manifest=maniskip -e '
    my $skip = maniskip("MANIFEST.SKIP");
    for my $f (qw(RELEASING.md docs/superpowers/specs/2026-05-04-automated-changelog-design.md docs/superpowers/plans/2026-05-04-automated-changelog.md ci/scripts/prepare-release.sh)) {
        printf "%s: %s\n", $f, $skip->($f) ? "EXCLUDED" : "INCLUDED";
    }
'
```
Expected: all four printed as `EXCLUDED`.

- [ ] **Step 4: Commit**

```bash
git add RELEASING.md MANIFEST.SKIP
git commit -m "docs: add RELEASING.md; expand MANIFEST.SKIP exclusions"
```

---

## Task 11: Convert $VERSION from v-string to quoted-string form

This is the one-time switch from `$VERSION = v1.2.0;` (Perl v-string syntax) to `$VERSION = '1.2.0';` (quoted-string form). Per spec rationale: avoids v-string binary-stringification gotchas, matches modern CPAN convention, prepares for the no-v tag scheme.

**Files:**
- Modify: `lib/JSON/API.pm` (line 12 only)

- [ ] **Step 1: Read the current line for confirmation**

Run: `grep -n VERSION /Users/gfranks/workspace/json-api/lib/JSON/API.pm`
Expected output includes:
```
12:$VERSION     = v1.2.0;
```

- [ ] **Step 2: Apply the conversion**

Use the `Edit` tool. (Read the file first if you haven't this session.)

Find:
```
$VERSION     = v1.2.0;
```

Replace with:
```
$VERSION     = '1.2.0';
```

(The leading whitespace alignment is preserved — five spaces between `$VERSION` and `=`.)

- [ ] **Step 3: Verify the existing test suite still passes**

Run:
```bash
cd /Users/gfranks/workspace/json-api
perl Build.PL >/dev/null && ./Build >/dev/null && ./Build test 2>&1 | tail -10
```
Expected: existing tests pass (`All tests successful` or similar).

(If `Build.PL` fails because `Module::Build` is too old locally, that's not a regression — it's a pre-existing local environment issue. Note it as such and skip the local test step. CI's `testsuite.yml` will catch any actual regression.)

- [ ] **Step 4: Verify the regex in prepare-release.sh matches the new form**

Spot-check that the prepare-release.sh perl regex would correctly bump the new form:

```bash
cd /Users/gfranks/workspace/json-api
perl -i.bak -pe "s/^(\\s*)\\\$VERSION\\s*=\\s*['\"]?v?[0-9.]+['\"]?;/\$1\\\$VERSION = '9.9.9';/" lib/JSON/API.pm
grep VERSION lib/JSON/API.pm | head -2
mv lib/JSON/API.pm.bak lib/JSON/API.pm
grep VERSION lib/JSON/API.pm | head -2
```
First grep should show `$VERSION     = '9.9.9';`. Second grep (after restore) should show `$VERSION     = '1.2.0';`.

- [ ] **Step 5: Commit**

```bash
git add lib/JSON/API.pm
git commit -m "refactor: convert \$VERSION from Perl v-string to quoted-string form"
```

---

## Task 12: Update publish-cpan.yml

Drop the `'refs/tags/v'` requirement; generalize the version-patch regex to handle both old v-string form (in tags pre-conversion) and new quoted form.

**Files:**
- Modify: `.github/workflows/publish-cpan.yml`

- [ ] **Step 1: Read the current workflow**

Run: `rtk read .github/workflows/publish-cpan.yml` (or use the Read tool).

- [ ] **Step 2: Apply the gate change**

Use the `Edit` tool to change the `if:` line.

Find:
```
    if: github.event_name == 'release' && github.ref_type == 'tag' && startsWith(github.ref, 'refs/tags/v')
```

Replace with:
```
    if: github.event_name == 'release' && github.ref_type == 'tag' && startsWith(github.ref, 'refs/tags/')
```

(Drops only the `v` from `refs/tags/v`, keeps the rest.)

- [ ] **Step 3: Apply the regex change**

Find:
```
      - name: update-version
        # Tag is expected as vX.Y.Z so the v-string $VERSION = vX.Y.Z; stays valid.
        env:
          REF_NAME: ${{ github.ref_name }}
        run: |
          perl -i -pe 's/^(\s*)\$VERSION\s*=\s*v[0-9.]+;/$1\$VERSION = $ENV{REF_NAME};/' lib/JSON/API.pm
```

Replace with:
```
      - name: update-version
        # Accepts both old v-string form ($VERSION = v1.2.0;) and new
        # quoted form ($VERSION = '1.2.0';) on the input side.
        # Always emits the quoted form. Tag is expected as bare X.Y.Z
        # (no 'v' prefix); old v-prefixed tags are still acceptable for
        # backwards compatibility.
        env:
          REF_NAME: ${{ github.ref_name }}
        run: |
          REF_NAME_BARE="${REF_NAME#v}"
          perl -i -pe "s/^(\\s*)\\\$VERSION\\s*=\\s*['\"]?v?[0-9.]+['\"]?;/\$1\\\$VERSION = '${REF_NAME_BARE}';/" lib/JSON/API.pm
          if ! grep -qF "\$VERSION = '${REF_NAME_BARE}';" lib/JSON/API.pm; then
              echo "publish-cpan: failed to update \$VERSION in lib/JSON/API.pm" >&2
              exit 1
          fi
```

(Note: shell var name `REF_NAME_BARE` strips any incoming `v` prefix from the tag, so a hypothetical run against the legacy `v1.2.0` tag would still produce `$VERSION = '1.2.0';`. The `[v0-9.]+` and quote-handling on the input regex side accepts old and new source forms.)

- [ ] **Step 4: Validate workflow YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/publish-cpan.yml'))" && echo OK`
Expected: `OK`.

- [ ] **Step 5: Confirm no regression in shell tests**

Run: `bash ci/scripts/tests/run.sh`
Expected: `Results: 18 passed, 0 failed`. (publish-cpan.yml change doesn't affect shell tests but confirms nothing else got disturbed.)

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/publish-cpan.yml
git commit -m "ci: publish-cpan accepts no-v tags and both \$VERSION source forms"
```

---

## Task 13: Run the backfill (manual maintainer execution)

**This task requires user confirmation before running.** It modifies `Changes` based on live GitHub release data and produces a PR for review. The implementer agent must NOT auto-run this — surface to the user and wait for explicit go-ahead.

**Files:**
- Modify: `Changes`

- [ ] **Step 1: Confirm with the user**

Stop and ask: "Ready to run the backfill against the live repo? It will fetch v1.2.0's release body, prepend a `## 1.2.0 — 2026-04-29` section to `Changes`, and stage the result on a new `chore/backfill-changes` branch."

Wait for explicit approval before continuing.

- [ ] **Step 2: Create branch and run backfill**

```bash
cd /Users/gfranks/workspace/json-api
git checkout main
git pull --ff-only
git checkout -b chore/backfill-changes
GITHUB_REPOSITORY=geofffranks/json-api \
    GH_TOKEN=$(gh auth token) \
    bash ci/scripts/backfill-changes.sh
```
Expected output ends with `backfill: done. Review the diff before committing.`

- [ ] **Step 3: Review the diff**

Run: `git diff Changes | cat -A | head -40`
Expected: a new `## 1.2.0 — 2026-04-29` section at the top of the file, plus the deprecation notice replaced. Each line ends with `$` (LF only), NO `^M$` patterns.

Spot-check the inserted body against `gh release view v1.2.0 --json body --jq '.body'` to confirm content matches.

- [ ] **Step 4: Commit and open PR**

```bash
git add Changes
git commit -m "chore: backfill Changes for release v1.2.0

Restores the entry for v1.2.0, which shipped during the period when
the Changes file was marked 'no longer updated'. Body is pulled
directly from the corresponding GitHub release via gh release view
--json body, with CRLF stripped to LF."
git push --set-upstream origin chore/backfill-changes
gh pr create \
    --base main \
    --title "Backfill Changes for v1.2.0" \
    --body "Restores the Changes entry for v1.2.0 (the only release that shipped after the 2026-04-29 freeze). Generated by ci/scripts/backfill-changes.sh."
```

- [ ] **Step 5: Verify idempotency**

After merging, optionally re-run the backfill on main to confirm it's a no-op:

```bash
git checkout main
git pull --ff-only
GITHUB_REPOSITORY=geofffranks/json-api \
    GH_TOKEN=$(gh auth token) \
    bash ci/scripts/backfill-changes.sh
```
Expected: `backfill: section for 1.2.0 already present, skipping`. No diff to `Changes`.

If a diff appears, that's a bug — investigate before re-merging.

---

## Self-Review

### Spec coverage

| Spec section | Implementing task(s) |
|---|---|
| Decision: hybrid notes (auto + optional prose) | Tasks 5, 6 (auto path); Task 7 PR template note (prose path) |
| Decision: `workflow_dispatch` → release PR → merge → tag → release | Tasks 6, 7, 8 |
| Decision: `Changes` is markdown, identical to release body | Task 6 (prepend), Task 8 (extract back) |
| Decision: `bump=patch\|minor\|major` with optional `version` override | Task 3 (lib), Task 6 (consume), Task 7 (workflow input) |
| Decision: NO `v` prefix going forward | Task 3 (`semver_validate` rejects v); Task 6 (resolved version has no v); Task 11 ($VERSION conversion); Task 12 (publish-cpan accepts no-v); Task 8 (tag write is bare version) |
| Decision: backfill v1.2.0 | Tasks 9, 13 |
| Decision: `Changes` is single source of truth | Task 7 (PR description note); Task 8 (reads `Changes`, not PR) |
| Decision: pre-backfill guard | Task 6 (guard implementation); Task 10 (RELEASING.md Prerequisites) |
| Decision: CRLF normalization | Tasks 5, 9 (both pipe through `tr -d '\r'`) |
| Decision: $VERSION conversion | Task 11 |
| Decision: publish-cpan.yml updated | Task 12 |
| Decision: MANIFEST.SKIP additions | Task 10 |
| Components: `prepare-release.yml` | Task 7 |
| Components: `finalize-release.yml` | Task 8 |
| Components: `prepare-release.sh` | Task 6 |
| Components: `build-release-notes.sh` | Task 5 |
| Components: `extract-release-section.sh` | Task 4 |
| Components: `backfill-changes.sh` | Task 9 |
| Components: `lint-release-tooling.yml` | Task 1 |
| Components: shell harness, semver lib, fixtures | Tasks 2, 3, 4 |
| Components: RELEASING.md | Task 10 |
| Error handling: tag/branch collision, no commits, empty notes | Task 6 |
| Error handling: $VERSION substitution miss | Task 6 (guard verifies match) |
| Error handling: `Changes` heading vs branch mismatch | Task 8 (verify steps) |
| Error handling: gh release create transient failure | Task 8 (workflow_dispatch retry path) |
| Testing: actionlint + shellcheck lint job | Task 1 |
| Testing: shell test harness | Task 2 |
| Testing: DRY_RUN smoke | Task 6 step 4 |
| Out of scope: lib JSON code, debian/, json-api.spec, t/, testsuite.yml, lint.yml | None modified ✓ |

All spec sections covered.

### Placeholder scan

Searched for: `TBD`, `TODO`, `implement later`, `add appropriate`, `similar to Task`, "fill in details". No matches outside of error-message strings (e.g., `"placeholder"` in error context).

### Type / signature consistency

- `semver_bump <version> <part>` — Task 3 (definition), Task 6 (`semver_bump "$LAST_VERSION" "$BUMP"`).
- `semver_validate <version>` — Task 3, Task 6.
- `extract-release-section.sh --changes-file --version-only|--out-file` — Task 4 (definition), Task 8 (workflow consumption).
- `build-release-notes.sh --new-version --previous-tag --target-commitish` — Task 5, Task 6.
- `prepare-release.sh` env contract (`BUMP`, `VERSION_OVERRIDE`, `GITHUB_REPOSITORY`, `GITHUB_OUTPUT`, `DRY_RUN`) — matches Task 7 workflow inputs.
- Workflow output names (`version`, `branch`, `pr_body_file`) — defined Task 6, consumed Task 7.

### Branch coverage

- `semver.sh` — patch / minor / major / invalid / v-prefix-input / leading-zero rejections all tested in Task 3.
- `extract-release-section.sh` — happy path, missing-heading, non-semver-heading, missing-flag-value all tested in Task 4.

### Workflow execution-order check

```
Task 1 (lint job) → green-light gate
Task 2 (test harness) → required by Tasks 3, 4
Task 3 (semver lib) → required by Task 6
Task 4 (extract-release-section) → required by Task 8
Task 5 (build-release-notes) → required by Task 6
Task 6 (prepare-release.sh) → required by Task 7
Task 7 (prepare-release.yml) → independent after Task 6
Task 8 (finalize-release.yml) → independent after Task 4
Task 9 (backfill script) → independent
Task 10 (RELEASING.md + MANIFEST.SKIP) → independent
Task 11 ($VERSION conversion) → independent (regex in Task 6 already accepts both forms)
Task 12 (publish-cpan.yml updates) → independent
Task 13 (run backfill) → requires Task 9 to be merged
```

No circular dependencies.

---

## Done criteria

- [ ] All 13 tasks complete and committed.
- [ ] `bash ci/scripts/tests/run.sh` reports `18 passed, 0 failed`.
- [ ] `actionlint .github/workflows/*.yml` exits 0.
- [ ] `shellcheck --shell=bash --severity=warning ci/scripts/**/*.sh` exits 0.
- [ ] `lib/JSON/API.pm` line 12 reads `$VERSION     = '1.2.0';` (quoted form).
- [ ] `publish-cpan.yml` no longer contains `startsWith(github.ref, 'refs/tags/v')`.
- [ ] `MANIFEST.SKIP` excludes `^ci\b`, `\B\.github\b`, `^RELEASING\.md`, `^docs\b`, and accepts `^JSON-API-v?\d+`.
- [ ] `Changes` includes the v1.2.0 section (post-Task 13).
- [ ] `prepare-release.yml` has been triggered on a non-main test branch (or fork) and produced an opened release PR with the correct `Changes` diff.
- [ ] After merging that test PR, `finalize-release.yml` produced a tag and a GitHub release whose body matches the topmost section of `Changes`.
