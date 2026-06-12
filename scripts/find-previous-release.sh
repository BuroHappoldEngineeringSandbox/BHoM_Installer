#!/usr/bin/env bash
# Resolve the anchor tag for the release body's "Changes since {anchor}" section.
#
# Given the release tag being published and the set of existing releases,
# returns the anchor tag and a kind label. Pure function: source_branch
# handling is done at render time in compose-release-body.sh, not here.
#
# Inputs (env):
#   GITHUB_REPOSITORY    For gh API calls.
#   GH_TOKEN             For gh API calls. Workflow's github.token is sufficient.
#
# Outputs (stdout, KEY=VALUE, intended for $GITHUB_OUTPUT):
#   anchor_tag=v9.1.2    (empty when anchor_kind=none)
#   anchor_kind=stable|none
#
# Exit codes:
#   0  success
#   3  missing input or internal error

set -euo pipefail

err() { printf '::error::%s\n' "$*" >&2; }

# Override hook for tests. Returns the unsorted set of release tags on stdout.
# SemVer sorting happens in select_anchor, not here.
lookup_releases() {
    gh release list --repo "${GITHUB_REPOSITORY}" --limit 100 \
        --json tagName --jq '.[].tagName'
}

# Parse a stable tag (vM.N.P) into M N P components.
# Returns non-zero on a non-stable tag.
parse_stable_tag() {
    local tag="$1"
    if [[ "$tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        printf '%s %s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
        return 0
    fi
    return 1
}

# Parse the release tag being published. Sets globals REQ_M, REQ_N, REQ_P,
# REQ_IS_PRERELEASE.
parse_release_tag() {
    local tag="$1"
    if [[ "$tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)-(alpha|beta|rc)(\.[0-9a-zA-Z.]+)?$ ]]; then
        REQ_M="${BASH_REMATCH[1]}"
        REQ_N="${BASH_REMATCH[2]}"
        REQ_P="${BASH_REMATCH[3]}"
        REQ_IS_PRERELEASE=true
        return 0
    elif [[ "$tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        REQ_M="${BASH_REMATCH[1]}"
        REQ_N="${BASH_REMATCH[2]}"
        REQ_P="${BASH_REMATCH[3]}"
        REQ_IS_PRERELEASE=false
        return 0
    fi
    err "Invalid release tag format: '$tag'"
    return 3
}

# Select the anchor tag using rules A and B from the design spec.
# Reads REQ_M, REQ_N, REQ_P, REQ_IS_PRERELEASE set by parse_release_tag.
# Writes anchor_tag and anchor_kind to stdout as KEY=VALUE pairs.
select_anchor() {
    local current_tag="$1"
    local m="$REQ_M" n="$REQ_N" p="$REQ_P"
    local is_prerelease="$REQ_IS_PRERELEASE"

    # Collect stable candidates from lookup_releases, parsed as (M N P tag) rows.
    local candidates=()
    local tag stable_m stable_n stable_p
    while IFS= read -r tag; do
        [ -z "$tag" ] && continue
        [ "$tag" = "$current_tag" ] && continue   # Self-exclusion
        if read -r stable_m stable_n stable_p < <(parse_stable_tag "$tag" 2>/dev/null); then
            candidates+=("$stable_m $stable_n $stable_p $tag")
        fi
    done < <(lookup_releases)

    if [ "${#candidates[@]}" -eq 0 ]; then
        printf 'anchor_tag=\n'
        printf 'anchor_kind=none\n'
        return 0
    fi

    # Rule B: patches (P > 0 on a stable tag, no prerelease).
    if [ "$is_prerelease" = "false" ] && [ "$p" -gt 0 ]; then
        local target="v${m}.${n}.0"
        local c
        for c in "${candidates[@]}"; do
            local c_tag="${c##* }"
            if [ "$c_tag" = "$target" ]; then
                printf 'anchor_tag=%s\n' "$target"
                printf 'anchor_kind=stable\n'
                return 0
            fi
        done
        printf 'anchor_tag=\n'
        printf 'anchor_kind=none\n'
        return 0
    fi

    # Rule A: pre-releases and v{M}.{N}.0 finals.
    # Filter to candidates strictly below the current M.N, then pick the
    # SemVer-highest (M', N', P') tuple.
    local best_m=-1 best_n=-1 best_p=-1 best_tag=""
    local c c_m c_n c_p c_tag
    for c in "${candidates[@]}"; do
        # shellcheck disable=SC2206
        local parts=($c)
        c_m="${parts[0]}"
        c_n="${parts[1]}"
        c_p="${parts[2]}"
        c_tag="${parts[3]}"
        # Strict (M', N') < (M, N).
        if [ "$c_m" -lt "$m" ] \
           || { [ "$c_m" -eq "$m" ] && [ "$c_n" -lt "$n" ]; }; then
            # SemVer-descending pick.
            if [ "$c_m" -gt "$best_m" ] \
               || { [ "$c_m" -eq "$best_m" ] && [ "$c_n" -gt "$best_n" ]; } \
               || { [ "$c_m" -eq "$best_m" ] && [ "$c_n" -eq "$best_n" ] && [ "$c_p" -gt "$best_p" ]; }; then
                best_m="$c_m"
                best_n="$c_n"
                best_p="$c_p"
                best_tag="$c_tag"
            fi
        fi
    done

    if [ -n "$best_tag" ]; then
        printf 'anchor_tag=%s\n' "$best_tag"
        printf 'anchor_kind=stable\n'
    else
        printf 'anchor_tag=\n'
        printf 'anchor_kind=none\n'
    fi
}

main() {
    local tag="${1:-}"
    [ -n "$tag" ] || { err "release_tag argument required"; return 3; }
    parse_release_tag "$tag" || return $?
    select_anchor "$tag"
}

# ─── self-test harness ─────────────────────────────────────────────────────

self_test() {
    local pass=0 fail=0
    assert_equal() {
        local desc="$1" expected="$2" actual="$3"
        if [ "$expected" = "$actual" ]; then
            echo "PASS: $desc"
            pass=$((pass + 1))
        else
            echo "FAIL: $desc"
            echo "  expected: $expected"
            echo "  actual:   $actual"
            fail=$((fail + 1))
        fi
    }

    # Case 1: no prior stable releases -> kind=none
    lookup_releases() { :; }
    local out
    out=$(main "v9.2.0-alpha.260605")
    assert_equal "case 1: no prior stable -> anchor_kind=none" \
        "anchor_kind=none" \
        "$(echo "$out" | grep '^anchor_kind=')"
    assert_equal "case 1: no prior stable -> anchor_tag empty" \
        "anchor_tag=" \
        "$(echo "$out" | grep '^anchor_tag=')"

    # Case 2: v9.1.0 prior -> v9.1.0
    lookup_releases() { printf '%s\n' "v9.1.0"; }
    out=$(main "v9.2.0-alpha.260605")
    assert_equal "case 2: v9.1.0 prior -> v9.1.0" \
        "anchor_tag=v9.1.0" \
        "$(echo "$out" | grep '^anchor_tag=')"

    # Case 3: v9.1.0 + v9.1.2 prior -> v9.1.2 (highest patch in M.N wins)
    lookup_releases() { printf '%s\n' "v9.1.0" "v9.1.2"; }
    out=$(main "v9.2.0-alpha.260605")
    assert_equal "case 3: v9.1.0 and v9.1.2 prior -> v9.1.2" \
        "anchor_tag=v9.1.2" \
        "$(echo "$out" | grep '^anchor_tag=')"

    # Case 12: SemVer sort beats back-port publish order
    lookup_releases() { printf '%s\n' "v9.1.3" "v9.2.0" "v9.1.0"; }
    out=$(main "v9.3.0-alpha.260801")
    assert_equal "case 12: SemVer sort beats back-port publish order" \
        "anchor_tag=v9.2.0" \
        "$(echo "$out" | grep '^anchor_tag=')"

    # Case 4: ignores alpha/beta/rc tags as candidates
    lookup_releases() { printf '%s\n' "v9.1.0-alpha.260101" "v9.1.0-beta.1" "v9.1.0-rc.1" "v9.1.0"; }
    out=$(main "v9.2.0-alpha.260605")
    assert_equal "case 4: only stable tags are candidates" \
        "anchor_tag=v9.1.0" \
        "$(echo "$out" | grep '^anchor_tag=')"

    # Case 4b: rc release-tag parses correctly (regression guard for the
    # PR #14 rename that originally missed this script).
    lookup_releases() { printf '%s\n' "v9.1.0"; }
    out=$(main "v9.2.0-rc.4")
    assert_equal "case 4b: rc tag parses, anchors against v9.1.0" \
        "anchor_tag=v9.1.0" \
        "$(echo "$out" | grep '^anchor_tag=')"

    # Case 5: final v9.2.0 with v9.1.0 + v9.1.2 prior -> v9.1.2
    lookup_releases() { printf '%s\n' "v9.1.0" "v9.1.2"; }
    out=$(main "v9.2.0")
    assert_equal "case 5: final v9.2.0 anchors against v9.1.2" \
        "anchor_tag=v9.1.2" \
        "$(echo "$out" | grep '^anchor_tag=')"

    # Case 9: current tag never anchored to itself
    lookup_releases() { printf '%s\n' "v9.2.0-alpha.260605" "v9.1.0"; }
    out=$(main "v9.2.0-alpha.260605")
    assert_equal "case 9: self never returned as anchor" \
        "anchor_tag=v9.1.0" \
        "$(echo "$out" | grep '^anchor_tag=')"

    # Case 10: double-digit version
    lookup_releases() { printf '%s\n' "v10.13.5"; }
    out=$(main "v10.14.0-alpha.270101")
    assert_equal "case 10: double-digit version anchors correctly" \
        "anchor_tag=v10.13.5" \
        "$(echo "$out" | grep '^anchor_tag=')"

    # Case 11: v9.3.0-alpha with v9.2.5 latest stable -> v9.2.5
    lookup_releases() { printf '%s\n' "v9.2.0" "v9.2.5" "v9.1.0"; }
    out=$(main "v9.3.0-alpha.260801")
    assert_equal "case 11: v9.3.0-alpha anchors against highest M.N stable v9.2.5" \
        "anchor_tag=v9.2.5" \
        "$(echo "$out" | grep '^anchor_tag=')"

    # Case 6: patch v9.2.1 with v9.2.0 shipped -> v9.2.0
    lookup_releases() { printf '%s\n' "v9.1.0" "v9.2.0"; }
    out=$(main "v9.2.1")
    assert_equal "case 6: patch v9.2.1 -> v9.2.0" \
        "anchor_tag=v9.2.0" \
        "$(echo "$out" | grep '^anchor_tag=')"

    # Case 7: patch v9.2.5 with v9.2.0-v9.2.4 -> v9.2.0 (cumulative within patch series)
    lookup_releases() { printf '%s\n' "v9.1.0" "v9.2.0" "v9.2.1" "v9.2.2" "v9.2.3" "v9.2.4"; }
    out=$(main "v9.2.5")
    assert_equal "case 7: patch v9.2.5 -> v9.2.0 (cumulative)" \
        "anchor_tag=v9.2.0" \
        "$(echo "$out" | grep '^anchor_tag=')"

    # Case 8: patch with no v{M}.{N}.0 (defensive) -> kind=none
    lookup_releases() { printf '%s\n' "v9.1.0"; }
    out=$(main "v9.2.1")
    assert_equal "case 8: patch with no v.0 -> anchor_kind=none" \
        "anchor_kind=none" \
        "$(echo "$out" | grep '^anchor_kind=')"

    echo
    echo "Results: $pass passed, $fail failed"
    [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--self-test" ]; then
    self_test
    exit $?
fi

main "$@"
