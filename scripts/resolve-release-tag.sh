#!/usr/bin/env bash
# Resolve the release tag and downstream parameters for build-installer.yml.
#
# Reads workflow context from environment variables, computes the tag for
# the current build, runs the five conflict-prevention rules, and writes
# KEY=VALUE pairs to stdout (intended to be appended to $GITHUB_OUTPUT).
#
# Inputs (env):
#   GITHUB_EVENT_NAME    'schedule' | 'workflow_dispatch'
#   GITHUB_REPOSITORY    'owner/repo' for the gh API calls.
#   INPUT_RELEASE_TYPE   'alpha' | 'rc' | 'final' on workflow_dispatch; empty otherwise.
#   INPUT_SOURCE_BRANCH  Branch to build from on alpha dispatch; default 'develop'.
#   GH_TOKEN             For gh api calls. Workflow's github.token is sufficient.
#
# Outputs (stdout):
#   release_type=<alpha|rc|final>
#                <alpha> for schedule and alpha dispatch
#                <rc>    for rc dispatch
#                <final> for final dispatch
#   should_publish=<true|false>
#                <false> when the scheduled-alpha path trips rule 3 (v{M}.{N}.0
#                already shipped). The build still runs (smoke-test preserved)
#                but the publish job is skipped; a tracking issue is opened.
#   wix_major / wix_minor
#                Wixproj-derived major/minor, surfaced so downstream jobs can
#                use them without re-reading the wixproj file.
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

# Derive the final release tag from the wixproj MajorVersion.MinorVersion.
# Patch component is always 0 under the no-patches model (proposal Section 4.4).
derive_final_tag() {
    local wix_m="$1" wix_n="$2"
    printf 'v%s.%s.0\n' "$wix_m" "$wix_n"
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

# Conflict rule 6: source branch must match the release type semantics.
#   rc    -> develop (release-candidate of a milestone in progress)
#   final -> main    (post develop->main merge; the released line)
# alpha allows any source branch (the input is the dispatch flag itself, no
# semantic constraint). Fail fast on mismatch instead of silently overriding
# the user's input.
assert_source_branch_matches_release_type() {
    local release_type="$1" in_branch="$2"
    case "$release_type" in
        rc)
            if [ -n "$in_branch" ] && [ "$in_branch" != "develop" ]; then
                err "RC dispatches must build from develop. Got source_branch='$in_branch'. Re-dispatch with source_branch=develop (or leave it empty), or use release_type=alpha to build from '$in_branch'."
                return 2
            fi
            ;;
        final)
            if [ -n "$in_branch" ] && [ "$in_branch" != "main" ]; then
                err "Final dispatches must build from main. Got source_branch='$in_branch'. Merge develop->main first, then re-dispatch with source_branch=main (or leave it empty)."
                return 2
            fi
            ;;
    esac
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
    local should_publish=true

    case "$event" in
        schedule)
            release_type=alpha
            source_branch=develop
            prerelease=true
            make_latest=false
            # Rule 3 is SOFT for scheduled nightlies: if v{M}.{N}.0 has already
            # shipped on this line, we still run build + install-test (smoke
            # preserved) but skip publish and emit a wixproj-bump warning.
            # The dispatched paths below treat rule 3 as a hard fail because
            # a human deliberately initiated those runs.
            if assert_no_shipped_release_for "$wix_m" "$wix_n" 2>/dev/null; then
                release_tag=$(compute_alpha_tag "$wix_m" "$wix_n" "$today")
            else
                should_publish=false
                release_tag=""
                printf '::warning title=Wixproj bump needed::v%s.%s.0 already shipped on this line. Bump BHoM_Installer.wixproj MinorVersion (or MajorVersion) on develop before the next nightly so it can publish.\n' "$wix_m" "$wix_n" >&2
            fi
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
                    prerelease=true
                    make_latest=false
                    ;;
                rc)
                    assert_source_branch_matches_release_type rc "$in_branch" || return 2
                    # RC dispatch always builds from develop regardless of input.
                    source_branch=develop
                    assert_no_shipped_release_for "$wix_m" "$wix_n" || return 2
                    release_tag=$(compute_rc_tag "$wix_m" "$wix_n")
                    # MSI PatchVersion = the RC counter (e.g. v9.2.0-rc.3 -> 3).
                    msi_patch_version="${release_tag##*-rc.}"
                    prerelease=true
                    make_latest=false
                    ;;
                final)
                    assert_source_branch_matches_release_type final "$in_branch" || return 2
                    # Final dispatch always builds from main regardless of input.
                    source_branch=main
                    release_tag=$(derive_final_tag "$wix_m" "$wix_n")
                    assert_release_not_already_published "$release_tag" || return 2
                    # MSI PatchVersion = 0 under the no-patches model.
                    msi_patch_version=0
                    prerelease=false
                    make_latest=true
                    ;;
                *)
                    err "Unknown release_type '$release_type' (expected alpha, rc, or final)"
                    return 3
                    ;;
            esac
            ;;

        *)
            err "Unsupported event '$event' (expected schedule or workflow_dispatch)"
            return 3
            ;;
    esac

    printf 'release_type=%s\n'      "$release_type"
    printf 'source_branch=%s\n'     "$source_branch"
    printf 'prerelease=%s\n'        "$prerelease"
    printf 'make_latest=%s\n'       "$make_latest"
    printf 'release_tag=%s\n'       "$release_tag"
    printf 'msi_patch_version=%s\n' "$msi_patch_version"
    printf 'should_publish=%s\n'    "$should_publish"
    printf 'wix_major=%s\n'         "$wix_m"
    printf 'wix_minor=%s\n'         "$wix_n"
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

    # ── derive_final_tag ──
    # Final tag is always vM.N.0 derived from the wixproj.

    assert_equal "final tag from wixproj 9.2"  "v9.2.0"  "$(derive_final_tag 9 2)"
    assert_equal "final tag from wixproj 10.0" "v10.0.0" "$(derive_final_tag 10 0)"
    assert_equal "final tag from wixproj 9.14" "v9.14.0" "$(derive_final_tag 9 14)"

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

    # workflow_dispatch final -> final release.
    export GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF_NAME=main \
        INPUT_RELEASE_TYPE=final INPUT_SOURCE_BRANCH=main
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ :; }; \
          resolve_main 2>/dev/null)
    assert_equal "dispatch final -> release_type=final" "final"  "$(echo "$out" | grep '^release_type='  | cut -d= -f2)"
    assert_equal "dispatch final -> source_branch=main" "main"   "$(echo "$out" | grep '^source_branch=' | cut -d= -f2)"
    assert_equal "dispatch final -> prerelease=false"   "false"  "$(echo "$out" | grep '^prerelease='    | cut -d= -f2)"
    assert_equal "dispatch final -> make_latest=true"   "true"   "$(echo "$out" | grep '^make_latest='   | cut -d= -f2)"
    assert_equal "dispatch final -> tag=v9.2.0"         "v9.2.0" "$(echo "$out" | grep '^release_tag='   | cut -d= -f2)"
    assert_equal "dispatch final -> msi_patch=0"        "0"      "$(echo "$out" | grep '^msi_patch_version=' | cut -d= -f2)"

    # workflow_dispatch final with empty source_branch -> succeeds (defaults to main).
    export INPUT_SOURCE_BRANCH=""
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ :; }; \
          resolve_main 2>/dev/null)
    assert_equal "dispatch final + empty source -> source=main" "main" \
        "$(echo "$out" | grep '^source_branch=' | cut -d= -f2)"

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

    # dispatch final when v9.2.0 already published -> rule 4 fires.
    export GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF_NAME=main \
        INPUT_RELEASE_TYPE=final INPUT_SOURCE_BRANCH=main
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ printf '%s\n' "v9.2.0"; }; \
          resolve_main 2>&1 >/dev/null; echo "exit=$?")
    case "$out" in
        *"already been released"*"exit=2") assert_equal "rule 4 trips on final dispatch when already published" "ok" "ok" ;;
        *) assert_equal "rule 4 trips on final dispatch when already published" "ok" "got: $out" ;;
    esac

    # dispatch final from develop -> rule 6 fires.
    export GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF_NAME=main \
        INPUT_RELEASE_TYPE=final INPUT_SOURCE_BRANCH=develop
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ :; }; \
          resolve_main 2>&1 >/dev/null; echo "exit=$?")
    case "$out" in
        *"Final dispatches must build from main"*"exit=2") assert_equal "rule 6: final + develop fails" "ok" "ok" ;;
        *) assert_equal "rule 6: final + develop fails" "ok" "got: $out" ;;
    esac

    # dispatch final from feature branch -> rule 6 fires.
    export INPUT_SOURCE_BRANCH=feature/X
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ :; }; \
          resolve_main 2>&1 >/dev/null; echo "exit=$?")
    case "$out" in
        *"Final dispatches must build from main"*"exit=2") assert_equal "rule 6: final + feature/X fails" "ok" "ok" ;;
        *) assert_equal "rule 6: final + feature/X fails" "ok" "got: $out" ;;
    esac

    # schedule when v9.2.0 already shipped -> rule 3 SOFT: should_publish=false,
    # no error exit, warning emitted to stderr.
    export GITHUB_EVENT_NAME=schedule GITHUB_REF_NAME=develop \
        INPUT_RELEASE_TYPE="" INPUT_SOURCE_BRANCH=""
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ printf '%s\n' "v9.2.0"; }; \
          resolve_main 2>/dev/null)
    assert_equal "schedule + v9.2.0 shipped -> should_publish=false" "false" \
        "$(echo "$out" | grep '^should_publish=' | cut -d= -f2)"
    assert_equal "schedule + v9.2.0 shipped -> release_tag empty" "" \
        "$(echo "$out" | grep '^release_tag=' | cut -d= -f2)"
    assert_equal "schedule + v9.2.0 shipped -> release_type still alpha" "alpha" \
        "$(echo "$out" | grep '^release_type=' | cut -d= -f2)"

    # And the warning is on stderr; the exit code is 0 (soft, not hard).
    err_out=$(lookup_tags()    { :; }; \
              lookup_releases(){ printf '%s\n' "v9.2.0"; }; \
              resolve_main 2>&1 >/dev/null; echo "exit=$?")
    case "$err_out" in
        *"Wixproj bump needed"*"exit=0") assert_equal "rule 3 soft on schedule emits warning, exits 0" "ok" "ok" ;;
        *) assert_equal "rule 3 soft on schedule emits warning, exits 0" "ok" "got: $err_out" ;;
    esac

    # Dispatched alpha when v9.2.0 shipped -> rule 3 HARD (user explicit).
    export GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF_NAME=develop \
        INPUT_RELEASE_TYPE=alpha INPUT_SOURCE_BRANCH=""
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ printf '%s\n' "v9.2.0"; }; \
          resolve_main 2>&1 >/dev/null; echo "exit=$?")
    case "$out" in
        *"already been released"*"exit=2") assert_equal "rule 3 hard on alpha dispatch when v9.2.0 shipped" "ok" "ok" ;;
        *) assert_equal "rule 3 hard on alpha dispatch when v9.2.0 shipped" "ok" "got: $out" ;;
    esac

    # Default schedule (no shipped release) -> should_publish=true.
    export GITHUB_EVENT_NAME=schedule GITHUB_REF_NAME=develop \
        INPUT_RELEASE_TYPE="" INPUT_SOURCE_BRANCH=""
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ :; }; \
          resolve_main 2>/dev/null)
    assert_equal "schedule + no shipped release -> should_publish=true" "true" \
        "$(echo "$out" | grep '^should_publish=' | cut -d= -f2)"
    assert_equal "schedule -> wix_major=9 wix_minor=2 surfaced" "9 2" \
        "$(echo "$out" | grep -E '^wix_(major|minor)=' | cut -d= -f2 | xargs)"

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
