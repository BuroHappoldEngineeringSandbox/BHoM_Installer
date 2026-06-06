#!/usr/bin/env bash
# Resolve the release tag and downstream parameters for build-installer.yml.
#
# Reads workflow context from environment variables, computes the tag for
# the current build, runs the five conflict-prevention rules, and writes
# KEY=VALUE pairs to stdout (intended to be appended to $GITHUB_OUTPUT).
#
# Inputs (env):
#   GITHUB_EVENT_NAME    'schedule' | 'workflow_dispatch' | 'push'
#   GITHUB_REF_NAME      For 'push': the pushed tag (e.g. 'v9.2.0').
#   GITHUB_REPOSITORY    'owner/repo' for the gh API calls.
#   INPUT_RELEASE_TYPE   'alpha' | 'beta' on workflow_dispatch; empty otherwise.
#   INPUT_SOURCE_BRANCH  Branch to build from on alpha dispatch; default 'develop'.
#   GH_TOKEN             For gh api calls. Workflow's github.token is sufficient.
#
# Outputs (stdout):
#   release_type=<alpha|beta>
#   source_branch=<branch>
#   prerelease=<true|false>
#   make_latest=<true|false>
#   release_tag=<the computed tag>
#
# Exit codes:
#   0  success
#   2  conflict-prevention rule violation (message on stderr)
#   3  internal error / missing inputs

set -euo pipefail

# ─── tag-lookup IO (overridable in --self-test) ─────────────────────────────

# Print existing tag names on the current repo, one per line. Override in
# tests by redefining this function before calling resolve_main().
lookup_tags() {
    gh api "repos/${GITHUB_REPOSITORY}/git/refs/tags" --paginate \
        --jq '.[].ref | sub("^refs/tags/"; "")'
}

# Print existing published-release tag names, one per line. Override in tests.
# Distinct from lookup_tags because a tag can exist without a release.
lookup_releases() {
    gh api "repos/${GITHUB_REPOSITORY}/releases" --paginate \
        --jq '.[].tag_name'
}

# ─── core logic (filled in by subsequent tasks) ─────────────────────────────

# Print "MAJOR MINOR" extracted from the wixproj file. Errors to stderr on
# missing/invalid input.
read_wixproj_version() {
    local file="$1"
    [ -f "$file" ] || { err "wixproj file not found: $file"; return 3; }

    local major minor
    major=$(grep -oE '<MajorVersion[^>]*>[0-9]+</MajorVersion>' "$file" \
            | grep -oE '>[0-9]+<' | tr -d '><' | head -n1)
    minor=$(grep -oE '<MinorVersion[^>]*>[0-9]+</MinorVersion>' "$file" \
            | grep -oE '>[0-9]+<' | tr -d '><' | head -n1)

    [ -n "$major" ] || { err "MajorVersion not found in $file"; return 3; }
    [ -n "$minor" ] || { err "MinorVersion not found in $file"; return 3; }
    printf '%s %s\n' "$major" "$minor"
}

# Compute the alpha tag for a given Major, Minor, and date.
# Looks at existing tags via lookup_tags() to determine the intra-day counter.
compute_alpha_tag() {
    local m="$1" n="$2" date="$3"
    local prefix="v${m}.${n}.0-alpha.${date}"
    local existing
    existing=$(lookup_tags | grep -E "^${prefix}(\.[0-9]+)?\$" || true)

    if [ -z "$existing" ]; then
        printf '%s\n' "$prefix"
        return 0
    fi

    # Highest counter found (0 if only the bare 'prefix' exists with no .N).
    local max=1
    while IFS= read -r tag; do
        [ -z "$tag" ] && continue
        if [ "$tag" = "$prefix" ]; then
            continue   # counts as '.1' implicitly
        fi
        local suffix="${tag#${prefix}.}"
        if [[ "$suffix" =~ ^[0-9]+$ ]] && [ "$suffix" -gt "$max" ]; then
            max="$suffix"
        fi
    done <<< "$existing"

    printf '%s.%d\n' "$prefix" "$((max + 1))"
}

resolve_main() {
    err "resolve_main not yet implemented"
    return 3
}

err() { printf '::error::%s\n' "$*" >&2; }

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

    # ── read_wixproj_version ──
    local tmp; tmp=$(mktemp)

    cat > "$tmp" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<Project>
  <PropertyGroup>
    <MajorVersion Condition=" '$(MajorVersion)' == '' ">9</MajorVersion>
    <MinorVersion Condition=" '$(MinorVersion)' == '' ">2</MinorVersion>
  </PropertyGroup>
</Project>
EOF
    assert_equal "wixproj happy path" "9 2" "$(read_wixproj_version "$tmp")"

    cat > "$tmp" <<'EOF'
<Project>
  <PropertyGroup>
    <MajorVersion>10</MajorVersion>
    <MinorVersion>14</MinorVersion>
  </PropertyGroup>
</Project>
EOF
    assert_equal "wixproj no-condition double-digit" "10 14" "$(read_wixproj_version "$tmp")"

    cat > "$tmp" <<'EOF'
<Project><PropertyGroup><MajorVersion>9</MajorVersion></PropertyGroup></Project>
EOF
    local out; out=$(read_wixproj_version "$tmp" 2>&1 || true)
    case "$out" in
        *"MinorVersion not found"*) assert_equal "wixproj missing minor errors" "ok" "ok" ;;
        *) assert_equal "wixproj missing minor errors" "ok" "got: $out" ;;
    esac

    rm -f "$tmp"

    # ── compute_alpha_tag ──
    # Tag format: vM.N.0-alpha.YYMMDD[.counter]
    # The counter is absent on the first build of the day, '.2' on the second, etc.

    lookup_tags() { :; }   # no existing tags
    assert_equal "alpha first build of day" \
        "v9.2.0-alpha.260605" "$(compute_alpha_tag 9 2 260605)"

    lookup_tags() { printf '%s\n' "v9.2.0-alpha.260605"; }
    assert_equal "alpha second build of day" \
        "v9.2.0-alpha.260605.2" "$(compute_alpha_tag 9 2 260605)"

    lookup_tags() { printf '%s\n' "v9.2.0-alpha.260605" "v9.2.0-alpha.260605.2" "v9.2.0-alpha.260605.3"; }
    assert_equal "alpha fourth build of day" \
        "v9.2.0-alpha.260605.4" "$(compute_alpha_tag 9 2 260605)"

    # Tags from a different day or version do not influence the counter.
    lookup_tags() { printf '%s\n' "v9.2.0-alpha.260604" "v9.2.0-alpha.260604.2" "v9.3.0-alpha.260605"; }
    assert_equal "alpha ignores other-day other-version tags" \
        "v9.2.0-alpha.260605" "$(compute_alpha_tag 9 2 260605)"

    # Restore the real lookup_tags for any later tests.
    unset -f lookup_tags
    lookup_tags() {
        gh api "repos/${GITHUB_REPOSITORY}/git/refs/tags" --paginate \
            --jq '.[].ref | sub("^refs/tags/"; "")'
    }

    echo
    echo "Results: $pass passed, $fail failed"
    [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--self-test" ]; then
    self_test
    exit $?
fi

resolve_main
