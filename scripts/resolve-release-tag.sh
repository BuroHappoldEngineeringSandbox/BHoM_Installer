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
#   INPUT_RELEASE_TYPE   'alpha' | 'rc' on workflow_dispatch; empty otherwise.
#   INPUT_SOURCE_BRANCH  Branch to build from on alpha dispatch; default 'develop'.
#   GH_TOKEN             For gh api calls. Workflow's github.token is sufficient.
#
# Outputs (stdout):
#   release_type=<alpha|rc|beta>
#                <alpha> for schedule and alpha dispatch
#                <rc>    for rc dispatch
#                <beta>  for tag-push (final release)
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

# Compute the RC pre-release tag for a given Major, Minor.
# Tag format: vM.N.0-rc.counter where counter is monotonic per (M,N,0).
compute_rc_tag() {
    local m="$1" n="$2"
    local prefix="v${m}.${n}.0-rc"
    local existing
    existing=$(lookup_tags | grep -E "^${prefix}\\.[0-9]+\$" || true)

    local max=0
    while IFS= read -r tag; do
        [ -z "$tag" ] && continue
        local suffix="${tag#${prefix}.}"
        if [[ "$suffix" =~ ^[0-9]+$ ]] && [ "$suffix" -gt "$max" ]; then
            max="$suffix"
        fi
    done <<< "$existing"

    printf '%s.%d\n' "$prefix" "$((max + 1))"
}

# Validate that a pushed tag is of form v{M}.{N}.{P} (no pre-release suffix)
# and that its M.N matches the wixproj. Exits non-zero with an ::error:: on
# failure; prints the tag on success.
validate_release_tag() {
    local tag="$1" wix_m="$2" wix_n="$3"

    if ! [[ "$tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        err "Pushed tag '$tag' is not of form v{major}.{minor}.{patch} with no pre-release suffix. Final release tags only — push pre-release builds via workflow_dispatch instead."
        return 2
    fi

    local tag_m="${BASH_REMATCH[1]}" tag_n="${BASH_REMATCH[2]}"
    if [ "$tag_m" != "$wix_m" ] || [ "$tag_n" != "$wix_n" ]; then
        err "Pushed tag '$tag' (${tag_m}.${tag_n}) does not match BHoM_Installer.wixproj MajorVersion.MinorVersion (${wix_m}.${wix_n}). Either bump the wixproj before pushing, or push a v${wix_m}.${wix_n}.x tag."
        return 2
    fi

    printf '%s\n' "$tag"
}

# Conflict rule 3: a pre-release build is being attempted while a release
# for v{wix_m}.{wix_n}.0 has already shipped. Bump wixproj or quit.
assert_no_shipped_release_for() {
    local wix_m="$1" wix_n="$2"
    local target="v${wix_m}.${wix_n}.0"
    if lookup_releases | grep -Fxq "$target"; then
        err "Wixproj MajorVersion.MinorVersion (${wix_m}.${wix_n}) maps to ${target} which has already been released. Bump MajorVersion or MinorVersion in BHoM_Installer.wixproj before publishing further pre-releases."
        return 2
    fi
}

# Conflict rule 4: the pushed tag has already been published as a release.
# softprops/action-gh-release would fail later; surface it now.
assert_release_not_already_published() {
    local tag="$1"
    if lookup_releases | grep -Fxq "$tag"; then
        err "${tag} has already been released. To re-release, delete the existing release in the GitHub UI first; to ship a follow-up, push a new tag (e.g. the next patch)."
        return 2
    fi
}

# Conflict rule 6: RC dispatches must build from develop. The silent
# override in earlier versions was a UX bug. The user's source_branch input
# was discarded with no signal. Fail fast instead so the user notices.
assert_rc_source_branch_is_develop() {
    local in_branch="$1"
    if [ -n "$in_branch" ] && [ "$in_branch" != "develop" ]; then
        err "RC dispatches must build from develop. Got source_branch='$in_branch'. Re-dispatch with source_branch=develop (or leave it empty), or use release_type=alpha to build from '$in_branch'."
        return 2
    fi
}

# Top-level orchestrator. Reads workflow context from env, computes the
# tag and outputs, runs conflict-prevention rules. Writes KEY=VALUE pairs
# to stdout (intended to be appended to $GITHUB_OUTPUT).
resolve_main() {
    local event="${GITHUB_EVENT_NAME:-}"
    local ref="${GITHUB_REF_NAME:-}"
    local in_type="${INPUT_RELEASE_TYPE:-}"
    local in_branch="${INPUT_SOURCE_BRANCH:-}"

    local wixproj="${WIXPROJ_PATH:-BHoM_Installer/BHoM_Installer.wixproj}"
    local mn; mn=$(read_wixproj_version "$wixproj") || return 3
    local wix_m wix_n; read -r wix_m wix_n <<< "$mn"

    local today="${TODAY_OVERRIDE:-$(date -u +%y%m%d)}"

    local release_type source_branch prerelease make_latest release_tag msi_patch_version=""

    case "$event" in
        schedule)
            release_type=alpha
            source_branch=develop
            prerelease=true
            make_latest=false
            assert_no_shipped_release_for "$wix_m" "$wix_n" || return 2
            release_tag=$(compute_alpha_tag "$wix_m" "$wix_n" "$today")
            # msi_patch_version="" — Build-Installer.ps1 defaults to yyMMdd.
            ;;

        workflow_dispatch)
            release_type="${in_type:-alpha}"
            case "$release_type" in
                alpha)
                    source_branch="${in_branch:-develop}"
                    assert_no_shipped_release_for "$wix_m" "$wix_n" || return 2
                    release_tag=$(compute_alpha_tag "$wix_m" "$wix_n" "$today")
                    # msi_patch_version="" — Build-Installer.ps1 defaults to yyMMdd.
                    ;;
                rc)
                    assert_rc_source_branch_is_develop "$in_branch" || return 2
                    # RC dispatch always builds from develop regardless of input.
                    source_branch=develop
                    assert_no_shipped_release_for "$wix_m" "$wix_n" || return 2
                    release_tag=$(compute_rc_tag "$wix_m" "$wix_n")
                    # MSI PatchVersion = the RC counter (e.g. v9.2.0-rc.3 -> 3).
                    msi_patch_version="${release_tag##*-rc.}"
                    ;;
                *)
                    err "Unknown release_type '$release_type' (expected alpha or rc)"
                    return 3
                    ;;
            esac
            prerelease=true
            make_latest=false
            ;;

        push)
            release_type=beta
            source_branch=main
            prerelease=false
            make_latest=true
            release_tag=$(validate_release_tag "$ref" "$wix_m" "$wix_n") || return 2
            assert_release_not_already_published "$release_tag" || return 2
            # MSI PatchVersion = the patch component of the pushed tag.
            if [[ "$release_tag" =~ ^v[0-9]+\.[0-9]+\.([0-9]+)$ ]]; then
                msi_patch_version="${BASH_REMATCH[1]}"
            else
                msi_patch_version=0
            fi
            ;;

        *)
            err "Unsupported event '$event'"
            return 3
            ;;
    esac

    printf 'release_type=%s\n'      "$release_type"
    printf 'source_branch=%s\n'     "$source_branch"
    printf 'prerelease=%s\n'        "$prerelease"
    printf 'make_latest=%s\n'       "$make_latest"
    printf 'release_tag=%s\n'       "$release_tag"
    printf 'msi_patch_version=%s\n' "$msi_patch_version"
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

    # ── compute_rc_tag ──
    # Tag format: vM.N.0-rc.counter, counter starts at 1.

    lookup_tags() { :; }
    assert_equal "rc first" "v9.2.0-rc.1" "$(compute_rc_tag 9 2)"

    lookup_tags() { printf '%s\n' "v9.2.0-rc.1"; }
    assert_equal "rc second" "v9.2.0-rc.2" "$(compute_rc_tag 9 2)"

    lookup_tags() { printf '%s\n' "v9.2.0-rc.1" "v9.2.0-rc.2" "v9.2.0-rc.5"; }
    assert_equal "rc after gap" "v9.2.0-rc.6" "$(compute_rc_tag 9 2)"

    # Alpha tags do not influence the rc counter.
    lookup_tags() { printf '%s\n' "v9.2.0-alpha.260605" "v9.2.0-alpha.260605.2"; }
    assert_equal "rc ignores alpha tags" "v9.2.0-rc.1" "$(compute_rc_tag 9 2)"

    unset -f lookup_tags
    lookup_tags() {
        gh api "repos/${GITHUB_REPOSITORY}/git/refs/tags" --paginate \
            --jq '.[].ref | sub("^refs/tags/"; "")'
    }

    # ── validate_release_tag ──
    # Pushed tag must be v{M}.{N}.{P} (no pre-release suffix), where {M}.{N}
    # matches wixproj. Errors otherwise.

    assert_equal "release tag happy v9.2.0" "ok" \
        "$(validate_release_tag "v9.2.0" 9 2 >/dev/null 2>&1 && echo ok || echo fail)"

    assert_equal "release tag happy v9.2.5 patch" "ok" \
        "$(validate_release_tag "v9.2.5" 9 2 >/dev/null 2>&1 && echo ok || echo fail)"

    assert_equal "release tag rejects pre-release suffix" "fail" \
        "$(validate_release_tag "v9.2.0-rc.1" 9 2 >/dev/null 2>&1 && echo ok || echo fail)"

    assert_equal "release tag rejects M.N mismatch" "fail" \
        "$(validate_release_tag "v9.3.0" 9 2 >/dev/null 2>&1 && echo ok || echo fail)"

    assert_equal "release tag rejects malformed" "fail" \
        "$(validate_release_tag "v9.2" 9 2 >/dev/null 2>&1 && echo ok || echo fail)"

    # ── assert_no_shipped_release_for + assert_release_not_already_published ──

    lookup_releases() { :; }
    assert_equal "no released v9.2.0 - pre-releases ok" "ok" \
        "$(assert_no_shipped_release_for 9 2 >/dev/null 2>&1 && echo ok || echo fail)"

    lookup_releases() { printf '%s\n' "v9.2.0"; }
    assert_equal "v9.2.0 already shipped blocks pre-release" "fail" \
        "$(assert_no_shipped_release_for 9 2 >/dev/null 2>&1 && echo ok || echo fail)"

    lookup_releases() { printf '%s\n' "v9.1.0" "v9.2.0-alpha.260601"; }
    assert_equal "v9.2.0-alpha published does not block more alphas" "ok" \
        "$(assert_no_shipped_release_for 9 2 >/dev/null 2>&1 && echo ok || echo fail)"

    lookup_releases() { :; }
    assert_equal "rule 4: tag not yet released ok" "ok" \
        "$(assert_release_not_already_published "v9.2.0" >/dev/null 2>&1 && echo ok || echo fail)"

    lookup_releases() { printf '%s\n' "v9.2.0"; }
    assert_equal "rule 4: tag already released blocks push" "fail" \
        "$(assert_release_not_already_published "v9.2.0" >/dev/null 2>&1 && echo ok || echo fail)"

    unset -f lookup_releases
    lookup_releases() {
        gh api "repos/${GITHUB_REPOSITORY}/releases" --paginate \
            --jq '.[].tag_name'
    }

    # ── resolve_main integration ──
    # Drive resolve_main via env vars and capture stdout. Override
    # lookup_tags/lookup_releases per case.

    local wixproj_tmp; wixproj_tmp=$(mktemp)
    cat > "$wixproj_tmp" <<'EOF'
<Project><PropertyGroup>
  <MajorVersion>9</MajorVersion>
  <MinorVersion>2</MinorVersion>
</PropertyGroup></Project>
EOF
    export WIXPROJ_PATH="$wixproj_tmp"
    export TODAY_OVERRIDE="260605"

    # Schedule -> alpha pre-release for today.
    export GITHUB_EVENT_NAME=schedule GITHUB_REF_NAME=develop \
        INPUT_RELEASE_TYPE="" INPUT_SOURCE_BRANCH=""
    local out; out=$(lookup_tags()    { :; }; \
                     lookup_releases(){ :; }; \
                     resolve_main 2>/dev/null)
    assert_equal "schedule -> release_type=alpha"     "alpha"                "$(echo "$out" | grep '^release_type='  | cut -d= -f2)"
    assert_equal "schedule -> source_branch=develop"  "develop"              "$(echo "$out" | grep '^source_branch=' | cut -d= -f2)"
    assert_equal "schedule -> prerelease=true"        "true"                 "$(echo "$out" | grep '^prerelease='    | cut -d= -f2)"
    assert_equal "schedule -> make_latest=false"      "false"                "$(echo "$out" | grep '^make_latest='   | cut -d= -f2)"
    assert_equal "schedule -> release_tag computed"   "v9.2.0-alpha.260605"  "$(echo "$out" | grep '^release_tag='   | cut -d= -f2)"

    # workflow_dispatch rc -> rc pre-release.
    export GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF_NAME=develop \
        INPUT_RELEASE_TYPE=rc INPUT_SOURCE_BRANCH=develop
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ :; }; \
          resolve_main 2>/dev/null)
    assert_equal "dispatch rc -> release_type=rc"          "rc"              "$(echo "$out" | grep '^release_type='  | cut -d= -f2)"
    assert_equal "dispatch rc -> source_branch=develop"    "develop"         "$(echo "$out" | grep '^source_branch=' | cut -d= -f2)"
    assert_equal "dispatch rc -> tag=v9.2.0-rc.1"          "v9.2.0-rc.1"     "$(echo "$out" | grep '^release_tag='   | cut -d= -f2)"

    # workflow_dispatch alpha with source_branch.
    export GITHUB_EVENT_NAME=workflow_dispatch \
        INPUT_RELEASE_TYPE=alpha INPUT_SOURCE_BRANCH=feature/foo
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ :; }; \
          resolve_main 2>/dev/null)
    assert_equal "dispatch alpha source_branch passes through" "feature/foo" \
        "$(echo "$out" | grep '^source_branch=' | cut -d= -f2)"

    # push v9.2.0 -> release.
    export GITHUB_EVENT_NAME=push GITHUB_REF_NAME=v9.2.0 \
        INPUT_RELEASE_TYPE="" INPUT_SOURCE_BRANCH=""
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ :; }; \
          resolve_main 2>/dev/null)
    assert_equal "push v9.2.0 -> release_type=beta"   "beta"     "$(echo "$out" | grep '^release_type='  | cut -d= -f2)"
    assert_equal "push v9.2.0 -> prerelease=false"    "false"    "$(echo "$out" | grep '^prerelease='    | cut -d= -f2)"
    assert_equal "push v9.2.0 -> make_latest=true"    "true"     "$(echo "$out" | grep '^make_latest='   | cut -d= -f2)"
    assert_equal "push v9.2.0 -> tag=v9.2.0"          "v9.2.0"   "$(echo "$out" | grep '^release_tag='   | cut -d= -f2)"
    assert_equal "push v9.2.0 -> msi_patch=0"         "0"        "$(echo "$out" | grep '^msi_patch_version=' | cut -d= -f2)"

    # push v9.2.5 -> patch carried through.
    export GITHUB_EVENT_NAME=push GITHUB_REF_NAME=v9.2.5
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ :; }; \
          resolve_main 2>/dev/null)
    assert_equal "push v9.2.5 -> msi_patch=5"         "5"        "$(echo "$out" | grep '^msi_patch_version=' | cut -d= -f2)"

    # workflow_dispatch rc -> msi_patch equals the counter.
    export GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF_NAME=develop \
        INPUT_RELEASE_TYPE=rc INPUT_SOURCE_BRANCH=""
    out=$(lookup_tags()    { printf '%s\n' "v9.2.0-rc.1" "v9.2.0-rc.2"; }; \
          lookup_releases(){ :; }; \
          resolve_main 2>/dev/null)
    assert_equal "rc dispatch -> msi_patch=3 (next counter)" "3" \
        "$(echo "$out" | grep '^msi_patch_version=' | cut -d= -f2)"

    # workflow_dispatch alpha -> msi_patch empty (Build-Installer.ps1 defaults to yyMMdd).
    export GITHUB_EVENT_NAME=workflow_dispatch INPUT_RELEASE_TYPE=alpha
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ :; }; \
          resolve_main 2>/dev/null)
    assert_equal "alpha dispatch -> msi_patch empty" "" \
        "$(echo "$out" | grep '^msi_patch_version=' | cut -d= -f2)"

    # push v9.2.0 when already-published -> rule 4 fires.
    export GITHUB_EVENT_NAME=push GITHUB_REF_NAME=v9.2.0 \
        INPUT_RELEASE_TYPE="" INPUT_SOURCE_BRANCH=""
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ printf '%s\n' "v9.2.0"; }; \
          resolve_main 2>&1 >/dev/null; echo "exit=$?")
    case "$out" in
        *"already been released"*"exit=2") assert_equal "rule 4 trips on push of published tag" "ok" "ok" ;;
        *) assert_equal "rule 4 trips on push of published tag" "ok" "got: $out" ;;
    esac

    # schedule when v9.2.0 already shipped -> rule 3 fires.
    export GITHUB_EVENT_NAME=schedule GITHUB_REF_NAME=develop \
        INPUT_RELEASE_TYPE="" INPUT_SOURCE_BRANCH=""
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ printf '%s\n' "v9.2.0"; }; \
          resolve_main 2>&1 >/dev/null; echo "exit=$?")
    case "$out" in
        *"already been released"*"exit=2") assert_equal "rule 3 trips on alpha when v9.2.0 shipped" "ok" "ok" ;;
        *) assert_equal "rule 3 trips on alpha when v9.2.0 shipped" "ok" "got: $out" ;;
    esac

    # Rule 6: rc dispatch with feature branch -> exit 2
    export GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF_NAME=develop \
        INPUT_RELEASE_TYPE=rc INPUT_SOURCE_BRANCH=feature/X
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ :; }; \
          resolve_main 2>&1 >/dev/null; echo "exit=$?")
    case "$out" in
        *"RC dispatches must build from develop"*"exit=2") assert_equal "rule 6: rc + feature/X fails" "ok" "ok" ;;
        *) assert_equal "rule 6: rc + feature/X fails" "ok" "got: $out" ;;
    esac

    # Rule 6: rc dispatch with main -> exit 2
    export INPUT_SOURCE_BRANCH=main
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ :; }; \
          resolve_main 2>&1 >/dev/null; echo "exit=$?")
    case "$out" in
        *"RC dispatches must build from develop"*"exit=2") assert_equal "rule 6: rc + main fails" "ok" "ok" ;;
        *) assert_equal "rule 6: rc + main fails" "ok" "got: $out" ;;
    esac

    # Rule 6: rc dispatch with empty source_branch -> succeeds
    export INPUT_SOURCE_BRANCH=""
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ :; }; \
          resolve_main 2>/dev/null)
    assert_equal "rule 6: rc + empty source_branch succeeds" "rc" \
        "$(echo "$out" | grep '^release_type=' | cut -d= -f2)"

    rm -f "$wixproj_tmp"
    unset WIXPROJ_PATH TODAY_OVERRIDE GITHUB_EVENT_NAME GITHUB_REF_NAME INPUT_RELEASE_TYPE INPUT_SOURCE_BRANCH

    echo
    echo "Results: $pass passed, $fail failed"
    [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--self-test" ]; then
    self_test
    exit $?
fi

resolve_main
