# Automated Changelog — Design Spec (JSON::API)

**Date:** 2026-05-04
**Status:** Approved (pending user review of this written spec)
**Owner:** Geoff Franks
**Prior art:** `test-mockmodule` shipped this same flow; see `docs/superpowers/specs/2026-05-04-automated-changelog-design.md` in the test-mockmodule repo for the architecture rationale that's reused here. This spec details the `JSON::API`-specific adaptations.

## Problem

The `Changes` file in `JSON::API` was deprecated on 2026-04-29 (commit `98d068b`). Since then, release `v1.2.0` (2026-04-29) has shipped to CPAN with a `Changes` file that doesn't describe it. The CPAN tarball — what end users see when they install — therefore contains a stale changelog.

We're resuming automated maintenance with the same three guarantees as test-mockmodule:

1. The `Changes` content for a release matches the GitHub Release body exactly.
2. `Changes` is updated *before* the release commit, so the CPAN tarball produced by `publish-cpan.yml` contains the new entry.
3. The maintainer can review and edit release notes before they go out, in a normal PR review flow.

Bundled with this resumption: a one-time conversion of `$VERSION` from Perl v-string syntax to quoted-string form, and a corresponding drop of the `v` prefix from the project's tag/release/tarball naming convention going forward.

## Constraints and decisions

- **Notes content is hybrid (auto + optional prose).** Auto from GitHub's "generate release notes" API; optional prose added by editing `Changes` directly in the release PR.
- **Release flow:** `workflow_dispatch` → release PR → merge → tag → GitHub release. Same as test-mockmodule.
- **`Changes` is markdown, identical to the release body.** Section header is `## <version> — <YYYY-MM-DD>`.
- **Version selected by `bump=patch|minor|major`** (default `minor`), with optional `version` string override.
- **Tags and version strings have NO `v` prefix going forward** (`1.3.0`, not `v1.3.0`). This is a change from the existing convention. Old `v*` tags stay as historical.
- **`$VERSION` line in `lib/JSON/API.pm` converts from v-string to quoted-string form** (one-time): `$VERSION = v1.2.0;` → `$VERSION = '1.2.0';`. CPAN-compatible; consumers see the same version number.
- **`publish-cpan.yml` updated** to drop the `startsWith('refs/tags/v')` gate and to accept the new quoted-string regex form (with backwards-compat for the v-string form).
- **The single missing release (v1.2.0) is backfilled** from its existing GitHub release body. Section heading uses no-v form (`## 1.2.0 — 2026-04-29`) even though the GitHub tag is `v1.2.0`, since the project's canonical version going forward has no prefix.
- **`Changes` is the single source of truth for the release body.** PR description is initialized from it but never read back. `finalize-release` extracts the topmost section.
- **Pre-backfill guard (lesson from test-mockmodule):** `prepare-release.sh` fails loudly if `Changes` has no `## X.Y.Z` heading anywhere. Without this, the section-extraction awk would read to EOF and embed the entire legacy changelog into a release.

## Why drop the `v`?

- Modern CPAN convention is no-prefix. `Test::MockModule` (this maintainer's other module) is already on no-prefix.
- v-string syntax (`$VERSION = v1.2.0;`) stringifies as binary characters (`\x01\x02\x00`), which trips up some toolchains.
- Quoted-string form is the dominant style in modern Perl.
- One-time conversion cost; cleaner forever after.

**Confirmed safe:**
- PAUSE/MetaCPAN treat both forms as semantically identical version numbers.
- Consumers depend on a version number, not source-syntax form.
- PAUSE compares version numbers, not strings — so `1.3.0 > v1.2.0` is computed correctly. No "version went backwards" warnings.
- Old GitHub tags stay where they are; existing links continue to work.

## Architecture

Same shape as test-mockmodule. New files:

```
.github/workflows/
  prepare-release.yml       # NEW: workflow_dispatch  → opens release PR
  finalize-release.yml      # NEW: PR-merge trigger   → tags + creates GH release
  lint-release-tooling.yml  # NEW: actionlint, shellcheck, shell-tests
  publish-cpan.yml          # MODIFIED: drop v-prefix gate, update version regex
ci/scripts/
  prepare-release.sh        # NEW: orchestrator
  build-release-notes.sh    # NEW: gh-api wrapper
  extract-release-section.sh # NEW: extract topmost ## X.Y.Z section
  backfill-changes.sh       # NEW: one-shot for v1.2.0
  lib/semver.sh             # NEW: semver_validate / semver_bump
  tests/run.sh              # NEW: shell test harness
  tests/test_semver.sh
  tests/test_extract_release_section.sh
  tests/fixtures/Changes.fixture.md
RELEASING.md                # NEW: maintainer-facing release flow doc
MANIFEST.SKIP               # MODIFIED: add ^ci\b, ^docs\b, ^RELEASING\.md, .github exclusion, JSON-API-no-v dist pattern
lib/JSON/API.pm             # MODIFIED: $VERSION = v1.2.0; → $VERSION = '1.2.0';
Changes                     # MODIFIED via backfill: prepend 1.2.0 entry, replace deprecation notice
```

### End-to-end flow (identical to test-mockmodule)

1. Maintainer dispatches `prepare-release` with `bump=minor` (default) or `version` override.
2. Workflow computes target version, calls GitHub `generate-notes` API for `<last-tag>..main`, prepends a section to `Changes`, bumps `$VERSION` in `lib/JSON/API.pm`, commits to `release/<version>`, opens PR titled `Release <version>`.
3. Maintainer reviews. Edits to `Changes` are canonical. PR description is display-only.
4. Merge. `finalize-release` extracts the topmost `Changes` section, tags the merge commit `<version>`, creates the GitHub release with that body.
5. `publish-cpan.yml` (existing, lightly modified) fires on release-created and uploads to CPAN.

### `publish-cpan.yml` modifications

Two changes from the current workflow:

1. **Drop the `v` requirement from the gate.** Change `startsWith(github.ref, 'refs/tags/v')` to `startsWith(github.ref, 'refs/tags/')`. Without this, the workflow would never fire for new no-v tags.

2. **Update the version-patch regex.** Current:
   ```
   s/^(\s*)\$VERSION\s*=\s*v[0-9.]+;/$1\$VERSION = $ENV{REF_NAME};/
   ```
   New:
   ```
   s/^(\s*)\$VERSION\s*=\s*['"]?v?[0-9.]+['"]?;/$1\$VERSION = '$ENV{REF_NAME}';/
   ```
   Accepts old v-string form OR new quoted form on the input side; always produces quoted form on output. The `$ENV{REF_NAME}` value comes from `github.ref_name` which equals the bare tag (e.g. `1.3.0`).

### `MANIFEST.SKIP` additions

Current `MANIFEST.SKIP` lacks several exclusions that the new files need:

```
# add explicit github exclusion
\B\.github\b

# exclude release tooling
^ci\b

# exclude maintainer docs
^RELEASING\.md
^docs\b

# accept both old and new dist tarball naming (was: ^JSON-API-v\d+)
^JSON-API-v?\d+
```

### `lib/JSON/API.pm` `$VERSION` conversion

Current line 12:
```perl
$VERSION     = v1.2.0;
```

New:
```perl
$VERSION     = '1.2.0';
```

This conversion is a single, mechanical edit committed alongside the rest of the work. It does NOT bump the version — that's the job of `prepare-release` for the next release. The `1.2.0` value here just preserves the current version-of-record between this PR's merge and the first new release.

### Backfill scope

One section to prepend:
```
## 1.2.0 — 2026-04-29

<body from `gh release view v1.2.0 --json body --jq '.body'`>
```

The script also replaces the existing deprecation notice:
```
# NOTE: Starting on Apr 29, 2026, this file will no longer be updated. Please see
  the release notes for versions of this module published on GitHub: 
  https://github.com/geofffranks/json-api/releases
```
with:
```
# NOTE: Automated tracking resumed 2026-05-04. See https://github.com/geofffranks/json-api/releases for any older entries pre-1.2.0.
```

### CRLF normalization (lesson from test-mockmodule)

GitHub stores release bodies with CRLF line endings (textarea source). Both `backfill-changes.sh` and `build-release-notes.sh` pipe `gh` output through `tr -d '\r'` so the file in the CPAN tarball uses LF only.

### Source-of-truth rule

`Changes` is the canonical source. The PR description is initialized from `Changes` for review convenience but is never read back. `finalize-release` extracts the topmost `## X.Y.Z` section of `Changes` and uses *that* for the GitHub release body. This guarantees by construction that the file in the tarball, the git-tagged content, and the GitHub release page all match. No drift, no two-way sync.

### Pre-backfill guard

`prepare-release.sh` checks for at least one `^## [0-9]+\.[0-9]+\.[0-9]+` heading in `Changes` before mutating. If none exists, fail with a message instructing the maintainer to run the backfill first. Same guard as test-mockmodule.

## Components

Helper scripts and lib are essentially copies of test-mockmodule's, with these adaptations:

| Component | Adaptation for JSON::API |
|---|---|
| `prepare-release.sh` | Perl regex updated to match `$VERSION = v1.2.0;` OR `$VERSION = '1.2.0';` and emit quoted-string form. Verifies substitution succeeded. |
| `extract-release-section.sh` | Section-heading regex stays `^## [0-9]+\.[0-9]+\.[0-9]+` (no v). |
| `build-release-notes.sh` | Default `--target-commitish=main` (matches default branch). Pipes through `tr -d '\r'` (CRLF fix). |
| `backfill-changes.sh` | `VERSIONS=(1.2.0)`. Tag fetch uses `v1.2.0` format on GitHub side; section heading writes `1.2.0` (no v). Pipes through `tr -d '\r'`. |
| `lib/semver.sh` | Identical to test-mockmodule (already rejects v-prefix; bumps decimal-safe). |
| Test harness, fixtures, tests | Identical structure. Fixture content updated for JSON::API context if needed (or kept abstract). |
| `lint-release-tooling.yml` | Identical. |
| `prepare-release.yml` | Identical aside from the repo name in any hardcoded references (currently there are none — uses `${{ github.repository }}`). |
| `finalize-release.yml` | Identical. Triggers on `pull_request: branches: [main]`. |
| `RELEASING.md` | Adapted — references JSON::API in prose, includes the same Prerequisites section pointing at the backfill. |

## Data flow

Identical to test-mockmodule. See the prior spec for the full diagram.

## Error handling

| Condition | Handler | Behavior |
|---|---|---|
| Tag `<version>` already exists | `prepare-release.sh` | Exit 1, "Tag X.Y.Z already exists. Aborting." |
| Branch `release/<version>` already exists | `prepare-release.sh` | Same. |
| No commits since last tag | `prepare-release.sh` | Exit 1, "Nothing to release since <last-tag>." |
| `Changes` has no `## X.Y.Z` heading | `prepare-release.sh` | Exit 1, "Changes file is in legacy format. Run backfill first." |
| `gh api generate-notes` returns empty body | `prepare-release.sh` | Continue with placeholder; warn. |
| `Changes` heading version mismatches branch name | `extract-release-section.sh` / `finalize-release.yml` | Exit 1. |
| Perl `$VERSION` substitution didn't take effect | `prepare-release.sh` | Exit 1, "regex didn't match — has the line format changed?" |
| `gh release create` transient failure | `finalize-release.yml` | Tag is already pushed; manual `workflow_dispatch` retry creates the release using the same extracted body. |

## Testing

Same as test-mockmodule:

1. **Static checks** in `lint-release-tooling.yml`: `actionlint` over `.github/workflows/*.yml`, `shellcheck` over `ci/scripts/**/*.sh`, run shell test harness.
2. **Local dry-run** of helpers via `DRY_RUN=1`.
3. **End-to-end on a fork or test branch** before declaring shipped.

## Implementation preflight

1. **Test runner.** Existing Perl tests: `./Build test`. New shell tests: `bash ci/scripts/tests/run.sh`. Lint: `actionlint`, `shellcheck`.
2. **Test seams.** Shell helpers expose `DRY_RUN=1`. Mutating ops gated; file mutations exercised so the dry-run is meaningful.
3. **Subagent model assignments.** Single-session implementation; no subagent dispatch for the work itself.
4. **Build/lint gating.** `actionlint` + `shellcheck` + harness must pass before each commit. New `lint-release-tooling.yml` enforces on push/PR.
5. **Scope boundaries.**
   - **In scope:** new workflows, helper scripts, helper lib, RELEASING.md, MANIFEST.SKIP additions, `publish-cpan.yml` regex+gate updates, one-time `$VERSION` syntax conversion in `lib/JSON/API.pm`, backfill of v1.2.0.
   - **Out of scope:** anything else in `lib/JSON/API.pm` (the actual JSON API logic), `debian/`, `json-api.spec`, `t/`, `testsuite.yml`, `lint.yml`.

## Open questions

None at design time. The maintainer-facing decisions (release frequency, branch protection, CI-runner pinning) are out of scope.
