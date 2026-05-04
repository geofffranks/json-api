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
