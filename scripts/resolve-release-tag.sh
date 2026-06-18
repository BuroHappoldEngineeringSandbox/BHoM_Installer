#!/usr/bin/env bash
# Resolve the release tag and downstream parameters for build-installer.yml.
#
# Reads workflow context from environment variables, computes the tag for
# the current build, runs the conflict-prevention rules, and writes
# KEY=VALUE pairs to stdout (intended to be appended to $GITHUB_OUTPUT).
#
# Three-input model (see proposal.md Section 6):
#   1. Installer branch  : GITHUB_REF (the workflow's ref, set by GHA dispatch
#                          via --ref or 'Use workflow from Branch' in the UI).
#                          For 'beta' the workflow ref must equal the repo's
#                          default branch (passed in via INPUT_DEFAULT_BRANCH).
#                          For 'alpha'/'alpha-beta' any branch is accepted.
#   2. Release type      : INPUT_RELEASE_TYPE input (alpha | alpha-beta | beta).
#   3. Dependency branch : INPUT_DEPENDENCY_BRANCH input. Tried on each dep
#                          clone; falls back to each dep's actual default
#                          branch if not found. Convention is 'develop' for
#                          alpha-beta and beta dispatches; a non-conventional
#                          value surfaces a warning but is not blocked.
#
# Tier model (SemVer perpetual pre-release):
#   alpha       — nightly / dev pre-release. Tag: vM.N.0-alpha.YYMMDD[.N]
#   alpha-beta  — release candidate. Tag: vM.N.0-alpha.beta.N
#   beta        — shipped release. Tag: vM.N.0-beta (no counter, singular per (M,N))
#
# Inputs (env):
#   GITHUB_EVENT_NAME       'schedule' | 'workflow_dispatch'
#   GITHUB_REPOSITORY       'owner/repo' for the gh API calls.
#   GITHUB_REF              Full ref the workflow runs on (e.g. refs/heads/main).
#   INPUT_RELEASE_TYPE      'alpha' | 'alpha-beta' | 'beta' on workflow_dispatch.
#   INPUT_DEPENDENCY_BRANCH Branch to try first on each dep clone; defaults to
#                           'develop' for both schedule and dispatch when empty.
#   INPUT_DEFAULT_BRANCH    Repo default branch (e.g. 'develop'). Required when
#                           INPUT_RELEASE_TYPE=beta; ignored otherwise. Sourced
#                           from github.event.repository.default_branch in the
#                           workflow. The rule-6 check compares the workflow
#                           ref against refs/heads/${INPUT_DEFAULT_BRANCH}.
#   GH_TOKEN                For gh api calls. Workflow's github.token suffices.
#
# Outputs (stdout):
#   release_type=<alpha|alpha-beta|beta>
#   dependency_branch=<branch>
#   prerelease=<true|false>
#   make_latest=<true|false>
#   release_tag=<the computed tag>
#   msi_patch_version=<value>
#   should_publish=<true|false>
#   wix_major / wix_minor
#
# Exit codes:
#   0  success (warnings may be emitted to stderr; check those for non-blocking issues)
#   2  hard rule violation (message on stderr)
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

# ─── core logic ─────────────────────────────────────────────────────────────

# Print "MAJOR MINOR" extracted from the wixproj file. Errors to stderr on
# missing/invalid input.
read_wixproj_version() {
    local file="$1"
    [ -f "$file" ] || { err "wixproj file not found: $file"; return 3; }

    local major minor
    major=$(sed -nE 's|.*<MajorVersion[^>]*>([0-9]+)</MajorVersion>.*|\1|p' "$file" | head -n1)
    minor=$(sed -nE 's|.*<MinorVersion[^>]*>([0-9]+)</MinorVersion>.*|\1|p' "$file" | head -n1)

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

# Compute the alpha-beta (release candidate) pre-release tag for a given Major, Minor.
# Tag format: vM.N.0-alpha.beta.counter where counter is monotonic per (M,N,0).
# Uses SemVer's example chain identifier 'alpha.beta' for ordering: SemVer spec
# orders alpha < alpha.beta < beta strictly, which matches the project's tier model.
compute_alpha_beta_tag() {
    local m="$1" n="$2"
    local prefix="v${m}.${n}.0-alpha.beta"
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

# Derive the shipped beta release tag from the wixproj MajorVersion.MinorVersion.
# Patch component is always 0 under the no-patches model (proposal Section 4.4).
# Tag is singular per (M,N) line — no counter. The next 'beta' build requires
# a wixproj MajorVersion or MinorVersion bump.
derive_beta_tag() {
    local wix_m="$1" wix_n="$2"
    printf 'v%s.%s.0-beta\n' "$wix_m" "$wix_n"
}

# Conflict rule 3: a pre-release build is being attempted while the shipped
# beta for v{wix_m}.{wix_n}.0 has already been released. Bump wixproj or quit.
# Under the SemVer perpetual-pre-release model the shipped tag is
# 'v{M}.{N}.0-beta' (no plain 'v{M}.{N}.0' is ever produced).
assert_no_shipped_release_for() {
    local wix_m="$1" wix_n="$2"
    local target="v${wix_m}.${wix_n}.0-beta"
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

# Conflict rule 6: beta dispatches must run with the workflow ref pointing
# at the repo's default branch. This enforces the "shipped releases come from
# a known canonical branch" invariant for user-facing releases. Alpha and
# alpha-beta are not constrained — they can dispatch from any branch (useful
# for feature-branch builds and pre-release testing).
#
# The tag created by softprops/action-gh-release lands on the workflow's
# commit, which is GITHUB_REF's HEAD at checkout time. So enforcing the
# workflow ref also constrains where the v{M}.{N}.0-beta tag lands.
assert_workflow_ref_is_default_for_beta() {
    local release_type="$1" workflow_ref="$2" default_branch="$3"
    if [ "$release_type" = "beta" ] && [ "$workflow_ref" != "refs/heads/${default_branch}" ]; then
        err "Beta dispatches must run with the workflow ref set to refs/heads/${default_branch} (the repo's default branch). Got '${workflow_ref}'. Re-dispatch via: gh workflow run build-installer.yml --ref ${default_branch} -f release_type=beta."
        return 2
    fi
}

# Soft convention warning: the dependency_branch input is unconventional for
# an alpha-beta or beta build. The convention is 'develop' (a workflow-level value;
# not derived per-dep). Surfaces as a ::warning:: annotation in the run log
# and is also visible in the release body's provenance section.
#
# Alpha dispatches are intentionally NOT warned — alphas are flexible by
# design (e.g. multi-repo feature-branch builds).
warn_non_conventional_dependency_branch() {
    local release_type="$1" dep_branch="$2"
    local expected="develop"
    case "$release_type" in
        alpha-beta|beta)
            if [ -n "$dep_branch" ] && [ "$dep_branch" != "$expected" ]; then
                printf '::warning title=Non-conventional dependency_branch::Building %s with dependency_branch=%s; convention is %s. Confirm intent before publishing.\n' \
                    "$release_type" "$dep_branch" "$expected" >&2
            fi
            ;;
    esac
}

# Top-level orchestrator. Reads workflow context from env, computes the
# tag and outputs, runs conflict-prevention rules. Writes KEY=VALUE pairs
# to stdout (intended to be appended to $GITHUB_OUTPUT).
resolve_main() {
    local event="${GITHUB_EVENT_NAME:-}"
    local workflow_ref="${GITHUB_REF:-}"
    local in_type="${INPUT_RELEASE_TYPE:-}"
    local in_dep_branch="${INPUT_DEPENDENCY_BRANCH:-}"
    local in_default_branch="${INPUT_DEFAULT_BRANCH:-}"

    local wixproj="${WIXPROJ_PATH:-BHoM_Installer/BHoM_Installer.wixproj}"
    local mn; mn=$(read_wixproj_version "$wixproj") || return 3
    local wix_m wix_n; read -r wix_m wix_n <<< "$mn"

    local today="${TODAY_OVERRIDE:-$(date -u +%y%m%d)}"

    local release_type dependency_branch prerelease make_latest release_tag msi_patch_version=""
    local should_publish=true

    case "$event" in
        schedule)
            release_type=alpha
            dependency_branch=develop
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
                printf '::warning title=Wixproj bump needed::v%s.%s.0-beta already shipped on this line. Bump BHoM_Installer.wixproj MinorVersion (or MajorVersion) on develop before the next nightly so it can publish.\n' "$wix_m" "$wix_n" >&2
            fi
            # msi_patch_version="" — Build-Installer.ps1 defaults to yyMMdd.
            ;;

        workflow_dispatch)
            release_type="${in_type:-alpha}"
            # dependency_branch defaults to 'develop' when input is empty.
            # The value flows through to Build-Installer.ps1 as the try-first
            # branch on each dep clone; missing branches fall back to each
            # dep's actual default branch.
            dependency_branch="${in_dep_branch:-develop}"

            case "$release_type" in
                alpha)
                    assert_no_shipped_release_for "$wix_m" "$wix_n" || return 2
                    release_tag=$(compute_alpha_tag "$wix_m" "$wix_n" "$today")
                    # msi_patch_version="" — Build-Installer.ps1 defaults to yyMMdd.
                    prerelease=true
                    make_latest=false
                    ;;
                alpha-beta)
                    warn_non_conventional_dependency_branch alpha-beta "$dependency_branch"
                    assert_no_shipped_release_for "$wix_m" "$wix_n" || return 2
                    release_tag=$(compute_alpha_beta_tag "$wix_m" "$wix_n")
                    # MSI PatchVersion = the alpha.beta counter (e.g. v9.2.0-alpha.beta.3 -> 3).
                    msi_patch_version="${release_tag##*-alpha.beta.}"
                    prerelease=true
                    make_latest=false
                    ;;
                beta)
                    if [ -z "$in_default_branch" ]; then
                        err "INPUT_DEFAULT_BRANCH is required for beta dispatches (the workflow should pass github.event.repository.default_branch)."
                        return 3
                    fi
                    assert_workflow_ref_is_default_for_beta beta "$workflow_ref" "$in_default_branch" || return 2
                    warn_non_conventional_dependency_branch beta "$dependency_branch"
                    release_tag=$(derive_beta_tag "$wix_m" "$wix_n")
                    assert_release_not_already_published "$release_tag" || return 2
                    # MSI PatchVersion = 0 under the no-patches model.
                    msi_patch_version=0
                    prerelease=false
                    make_latest=true
                    ;;
                *)
                    err "Unknown release_type '$release_type' (expected alpha, alpha-beta, or beta)"
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
    printf 'dependency_branch=%s\n' "$dependency_branch"
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

    # ── compute_alpha_beta_tag ──
    # Tag format: vM.N.0-alpha.beta.counter, counter starts at 1.

    lookup_tags() { :; }
    assert_equal "alpha-beta first" "v9.2.0-alpha.beta.1" "$(compute_alpha_beta_tag 9 2)"

    lookup_tags() { printf '%s\n' "v9.2.0-alpha.beta.1"; }
    assert_equal "alpha-beta second" "v9.2.0-alpha.beta.2" "$(compute_alpha_beta_tag 9 2)"

    lookup_tags() { printf '%s\n' "v9.2.0-alpha.beta.1" "v9.2.0-alpha.beta.2" "v9.2.0-alpha.beta.5"; }
    assert_equal "alpha-beta after gap" "v9.2.0-alpha.beta.6" "$(compute_alpha_beta_tag 9 2)"

    # Alpha tags do not influence the alpha-beta counter.
    lookup_tags() { printf '%s\n' "v9.2.0-alpha.260605" "v9.2.0-alpha.260605.2"; }
    assert_equal "alpha-beta ignores alpha tags" "v9.2.0-alpha.beta.1" "$(compute_alpha_beta_tag 9 2)"

    unset -f lookup_tags
    lookup_tags() {
        gh api "repos/${GITHUB_REPOSITORY}/git/refs/tags" --paginate \
            --jq '.[].ref | sub("^refs/tags/"; "")'
    }

    # ── derive_beta_tag ──

    assert_equal "beta tag from wixproj 9.2"  "v9.2.0-beta"  "$(derive_beta_tag 9 2)"
    assert_equal "beta tag from wixproj 10.0" "v10.0.0-beta" "$(derive_beta_tag 10 0)"
    assert_equal "beta tag from wixproj 9.14" "v9.14.0-beta" "$(derive_beta_tag 9 14)"

    # ── assert_no_shipped_release_for + assert_release_not_already_published ──

    lookup_releases() { :; }
    assert_equal "no released v9.2.0-beta - pre-releases ok" "ok" \
        "$(assert_no_shipped_release_for 9 2 >/dev/null 2>&1 && echo ok || echo fail)"

    lookup_releases() { printf '%s\n' "v9.2.0-beta"; }
    assert_equal "v9.2.0-beta already shipped blocks pre-release" "fail" \
        "$(assert_no_shipped_release_for 9 2 >/dev/null 2>&1 && echo ok || echo fail)"

    lookup_releases() { printf '%s\n' "v9.1.0-beta" "v9.2.0-alpha.260601"; }
    assert_equal "v9.2.0-alpha published does not block more alphas" "ok" \
        "$(assert_no_shipped_release_for 9 2 >/dev/null 2>&1 && echo ok || echo fail)"

    lookup_releases() { :; }
    assert_equal "rule 4: tag not yet released ok" "ok" \
        "$(assert_release_not_already_published "v9.2.0-beta" >/dev/null 2>&1 && echo ok || echo fail)"

    lookup_releases() { printf '%s\n' "v9.2.0-beta"; }
    assert_equal "rule 4: tag already released blocks push" "fail" \
        "$(assert_release_not_already_published "v9.2.0-beta" >/dev/null 2>&1 && echo ok || echo fail)"

    unset -f lookup_releases
    lookup_releases() {
        gh api "repos/${GITHUB_REPOSITORY}/releases" --paginate \
            --jq '.[].tag_name'
    }

    # ── assert_workflow_ref_is_default_for_beta ──

    assert_equal "rule 6: beta + ref=refs/heads/develop + default=develop passes" "ok" \
        "$(assert_workflow_ref_is_default_for_beta beta refs/heads/develop develop >/dev/null 2>&1 && echo ok || echo fail)"

    assert_equal "rule 6: beta + ref=refs/heads/main + default=develop fails" "fail" \
        "$(assert_workflow_ref_is_default_for_beta beta refs/heads/main develop >/dev/null 2>&1 && echo ok || echo fail)"

    assert_equal "rule 6: beta + ref=refs/heads/feature/x + default=develop fails" "fail" \
        "$(assert_workflow_ref_is_default_for_beta beta refs/heads/feature/x develop >/dev/null 2>&1 && echo ok || echo fail)"

    assert_equal "rule 6: beta + ref=refs/tags/v9.2.0-beta + default=develop fails" "fail" \
        "$(assert_workflow_ref_is_default_for_beta beta refs/tags/v9.2.0-beta develop >/dev/null 2>&1 && echo ok || echo fail)"

    # Rule auto-follows the default branch — if the repo flipped to 'main',
    # the rule now accepts main and rejects develop. Exercises the dynamic path.
    assert_equal "rule 6: beta + ref=refs/heads/main + default=main passes (dynamic)" "ok" \
        "$(assert_workflow_ref_is_default_for_beta beta refs/heads/main main >/dev/null 2>&1 && echo ok || echo fail)"

    assert_equal "rule 6: beta + ref=refs/heads/develop + default=main fails (dynamic)" "fail" \
        "$(assert_workflow_ref_is_default_for_beta beta refs/heads/develop main >/dev/null 2>&1 && echo ok || echo fail)"

    # alpha and alpha-beta are not constrained by the ref check, regardless of default branch.
    assert_equal "rule 6: alpha + ref=refs/heads/feature/x + default=develop passes" "ok" \
        "$(assert_workflow_ref_is_default_for_beta alpha refs/heads/feature/x develop >/dev/null 2>&1 && echo ok || echo fail)"

    assert_equal "rule 6: alpha-beta + ref=refs/heads/feature/x + default=develop passes" "ok" \
        "$(assert_workflow_ref_is_default_for_beta alpha-beta refs/heads/feature/x develop >/dev/null 2>&1 && echo ok || echo fail)"

    # ── warn_non_conventional_dependency_branch ──
    # Soft warning: returns 0 always, but emits ::warning:: to stderr when
    # release_type is alpha-beta/beta AND dep_branch is non-conventional.

    assert_equal "warn: alpha-beta + dep_branch=develop is silent" "" \
        "$(warn_non_conventional_dependency_branch alpha-beta develop 2>&1)"

    assert_equal "warn: alpha-beta + dep_branch=main emits warning" "warning" \
        "$(warn_non_conventional_dependency_branch alpha-beta main 2>&1 | grep -oE '^::warning' | head -1 | tr -d ':')"

    assert_equal "warn: beta + dep_branch=develop is silent" "" \
        "$(warn_non_conventional_dependency_branch beta develop 2>&1)"

    assert_equal "warn: beta + dep_branch=feature/x emits warning" "warning" \
        "$(warn_non_conventional_dependency_branch beta feature/x 2>&1 | grep -oE '^::warning' | head -1 | tr -d ':')"

    # alpha never warns regardless of dep_branch
    assert_equal "warn: alpha + dep_branch=main is silent" "" \
        "$(warn_non_conventional_dependency_branch alpha main 2>&1)"

    assert_equal "warn: alpha + dep_branch=feature/x is silent" "" \
        "$(warn_non_conventional_dependency_branch alpha feature/x 2>&1)"

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
    export GITHUB_EVENT_NAME=schedule GITHUB_REF=refs/heads/develop \
        INPUT_RELEASE_TYPE="" INPUT_DEPENDENCY_BRANCH=""
    local out; out=$(lookup_tags()    { :; }; \
                     lookup_releases(){ :; }; \
                     resolve_main 2>/dev/null)
    assert_equal "schedule -> release_type=alpha"     "alpha"                "$(echo "$out" | grep '^release_type='      | cut -d= -f2)"
    assert_equal "schedule -> dependency_branch=develop"  "develop"          "$(echo "$out" | grep '^dependency_branch=' | cut -d= -f2)"
    assert_equal "schedule -> prerelease=true"        "true"                 "$(echo "$out" | grep '^prerelease='        | cut -d= -f2)"
    assert_equal "schedule -> make_latest=false"      "false"                "$(echo "$out" | grep '^make_latest='       | cut -d= -f2)"
    assert_equal "schedule -> release_tag computed"   "v9.2.0-alpha.260605"  "$(echo "$out" | grep '^release_tag='       | cut -d= -f2)"

    # workflow_dispatch alpha-beta -> alpha-beta pre-release. Convention path: dependency_branch=develop.
    export GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/develop \
        INPUT_RELEASE_TYPE=alpha-beta INPUT_DEPENDENCY_BRANCH=develop
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ :; }; \
          resolve_main 2>/dev/null)
    assert_equal "dispatch alpha-beta -> release_type=alpha-beta"              "alpha-beta"           "$(echo "$out" | grep '^release_type='      | cut -d= -f2)"
    assert_equal "dispatch alpha-beta -> dependency_branch=develop"            "develop"              "$(echo "$out" | grep '^dependency_branch=' | cut -d= -f2)"
    assert_equal "dispatch alpha-beta -> tag=v9.2.0-alpha.beta.1"              "v9.2.0-alpha.beta.1"  "$(echo "$out" | grep '^release_tag='       | cut -d= -f2)"

    # workflow_dispatch alpha with dependency_branch passes through unchanged.
    export GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/develop \
        INPUT_RELEASE_TYPE=alpha INPUT_DEPENDENCY_BRANCH=feature/foo
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ :; }; \
          resolve_main 2>/dev/null)
    assert_equal "dispatch alpha dependency_branch passes through" "feature/foo" \
        "$(echo "$out" | grep '^dependency_branch=' | cut -d= -f2)"

    # workflow_dispatch beta from develop (default branch) with conventional dep_branch.
    export GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/develop \
        INPUT_RELEASE_TYPE=beta INPUT_DEPENDENCY_BRANCH=develop INPUT_DEFAULT_BRANCH=develop
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ :; }; \
          resolve_main 2>/dev/null)
    assert_equal "dispatch beta -> release_type=beta"            "beta"         "$(echo "$out" | grep '^release_type='      | cut -d= -f2)"
    assert_equal "dispatch beta -> dependency_branch=develop"    "develop"      "$(echo "$out" | grep '^dependency_branch=' | cut -d= -f2)"
    assert_equal "dispatch beta -> prerelease=false"             "false"        "$(echo "$out" | grep '^prerelease='        | cut -d= -f2)"
    assert_equal "dispatch beta -> make_latest=true"             "true"         "$(echo "$out" | grep '^make_latest='       | cut -d= -f2)"
    assert_equal "dispatch beta -> tag=v9.2.0-beta"              "v9.2.0-beta"  "$(echo "$out" | grep '^release_tag='       | cut -d= -f2)"
    assert_equal "dispatch beta -> msi_patch=0"                  "0"            "$(echo "$out" | grep '^msi_patch_version=' | cut -d= -f2)"

    # workflow_dispatch beta with empty INPUT_DEPENDENCY_BRANCH defaults to develop.
    export GITHUB_REF=refs/heads/develop INPUT_DEPENDENCY_BRANCH="" INPUT_DEFAULT_BRANCH=develop
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ :; }; \
          resolve_main 2>/dev/null)
    assert_equal "dispatch beta + empty dep_branch -> dependency_branch=develop" "develop" \
        "$(echo "$out" | grep '^dependency_branch=' | cut -d= -f2)"

    # workflow_dispatch alpha-beta msi_patch equals the counter.
    export GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/develop \
        INPUT_RELEASE_TYPE=alpha-beta INPUT_DEPENDENCY_BRANCH=""
    out=$(lookup_tags()    { printf '%s\n' "v9.2.0-alpha.beta.1" "v9.2.0-alpha.beta.2"; }; \
          lookup_releases(){ :; }; \
          resolve_main 2>/dev/null)
    assert_equal "alpha-beta dispatch -> msi_patch=3 (next counter)" "3" \
        "$(echo "$out" | grep '^msi_patch_version=' | cut -d= -f2)"

    # workflow_dispatch alpha msi_patch empty (Build-Installer.ps1 defaults to yyMMdd).
    export GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/develop \
        INPUT_RELEASE_TYPE=alpha INPUT_DEPENDENCY_BRANCH=""
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ :; }; \
          resolve_main 2>/dev/null)
    assert_equal "alpha dispatch -> msi_patch empty" "" \
        "$(echo "$out" | grep '^msi_patch_version=' | cut -d= -f2)"

    # dispatch beta when v9.2.0-beta already published -> rule 4 fires.
    export GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/develop \
        INPUT_RELEASE_TYPE=beta INPUT_DEPENDENCY_BRANCH=develop INPUT_DEFAULT_BRANCH=develop
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ printf '%s\n' "v9.2.0-beta"; }; \
          resolve_main 2>&1 >/dev/null; echo "exit=$?")
    case "$out" in
        *"already been released"*"exit=2") assert_equal "rule 4 trips on beta dispatch when already published" "ok" "ok" ;;
        *) assert_equal "rule 4 trips on beta dispatch when already published" "ok" "got: $out" ;;
    esac

    # dispatch beta from main ref (non-default) -> rule 6 fires (hard).
    export GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/main \
        INPUT_RELEASE_TYPE=beta INPUT_DEPENDENCY_BRANCH=develop INPUT_DEFAULT_BRANCH=develop
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ :; }; \
          resolve_main 2>&1 >/dev/null; echo "exit=$?")
    case "$out" in
        *"Beta dispatches must run with the workflow ref"*"exit=2") assert_equal "rule 6: beta + ref=main fails" "ok" "ok" ;;
        *) assert_equal "rule 6: beta + ref=main fails" "ok" "got: $out" ;;
    esac

    # dispatch beta from feature branch ref (non-default) -> rule 6 fires.
    export GITHUB_REF=refs/heads/feature/X INPUT_DEFAULT_BRANCH=develop
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ :; }; \
          resolve_main 2>&1 >/dev/null; echo "exit=$?")
    case "$out" in
        *"Beta dispatches must run with the workflow ref"*"exit=2") assert_equal "rule 6: beta + ref=feature/X fails" "ok" "ok" ;;
        *) assert_equal "rule 6: beta + ref=feature/X fails" "ok" "got: $out" ;;
    esac

    # dispatch beta from tag ref (non-branch) -> rule 6 fires.
    export GITHUB_REF=refs/tags/v9.2.0-beta INPUT_DEFAULT_BRANCH=develop
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ :; }; \
          resolve_main 2>&1 >/dev/null; echo "exit=$?")
    case "$out" in
        *"Beta dispatches must run with the workflow ref"*"exit=2") assert_equal "rule 6: beta + ref=refs/tags/v9.2.0-beta fails" "ok" "ok" ;;
        *) assert_equal "rule 6: beta + ref=refs/tags/v9.2.0-beta fails" "ok" "got: $out" ;;
    esac

    # dispatch beta with INPUT_DEFAULT_BRANCH unset -> internal error (exit 3).
    export GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/develop \
        INPUT_RELEASE_TYPE=beta INPUT_DEPENDENCY_BRANCH=develop INPUT_DEFAULT_BRANCH=""
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ :; }; \
          resolve_main 2>&1 >/dev/null; echo "exit=$?")
    case "$out" in
        *"INPUT_DEFAULT_BRANCH is required"*"exit=3") assert_equal "beta dispatch with empty INPUT_DEFAULT_BRANCH errors" "ok" "ok" ;;
        *) assert_equal "beta dispatch with empty INPUT_DEFAULT_BRANCH errors" "ok" "got: $out" ;;
    esac

    # dispatch alpha-beta with dep_branch=main -> succeeds with warning.
    export GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/develop \
        INPUT_RELEASE_TYPE=alpha-beta INPUT_DEPENDENCY_BRANCH=main INPUT_DEFAULT_BRANCH=develop
    local stderr_out
    stderr_out=$(lookup_tags()    { :; }; \
                 lookup_releases(){ :; }; \
                 resolve_main 2>&1 >/dev/null; echo "exit=$?")
    case "$stderr_out" in
        *"Non-conventional dependency_branch"*"exit=0") assert_equal "alpha-beta + dep_branch=main warns but succeeds" "ok" "ok" ;;
        *) assert_equal "alpha-beta + dep_branch=main warns but succeeds" "ok" "got: $stderr_out" ;;
    esac

    # dispatch alpha-beta with dep_branch=feature/X -> succeeds with warning.
    export INPUT_DEPENDENCY_BRANCH=feature/X
    stderr_out=$(lookup_tags()    { :; }; \
                 lookup_releases(){ :; }; \
                 resolve_main 2>&1 >/dev/null; echo "exit=$?")
    case "$stderr_out" in
        *"Non-conventional dependency_branch"*"exit=0") assert_equal "alpha-beta + dep_branch=feature/X warns but succeeds" "ok" "ok" ;;
        *) assert_equal "alpha-beta + dep_branch=feature/X warns but succeeds" "ok" "got: $stderr_out" ;;
    esac

    # dispatch beta with dep_branch=main -> succeeds with warning (ref=default, dep_branch unconventional).
    export GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/develop \
        INPUT_RELEASE_TYPE=beta INPUT_DEPENDENCY_BRANCH=main INPUT_DEFAULT_BRANCH=develop
    stderr_out=$(lookup_tags()    { :; }; \
                 lookup_releases(){ :; }; \
                 resolve_main 2>&1 >/dev/null; echo "exit=$?")
    case "$stderr_out" in
        *"Non-conventional dependency_branch"*"exit=0") assert_equal "beta + dep_branch=main warns but succeeds" "ok" "ok" ;;
        *) assert_equal "beta + dep_branch=main warns but succeeds" "ok" "got: $stderr_out" ;;
    esac

    # alpha with non-conventional dep_branch -> no warning (alphas are flexible).
    export GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/develop \
        INPUT_RELEASE_TYPE=alpha INPUT_DEPENDENCY_BRANCH=main
    stderr_out=$(lookup_tags()    { :; }; \
                 lookup_releases(){ :; }; \
                 resolve_main 2>&1 >/dev/null)
    case "$stderr_out" in
        *"Non-conventional dependency_branch"*) assert_equal "alpha + dep_branch=main does NOT warn" "ok" "WARNED (unexpected)" ;;
        *) assert_equal "alpha + dep_branch=main does NOT warn" "ok" "ok" ;;
    esac

    # schedule when v9.2.0-beta already shipped -> rule 3 SOFT: should_publish=false.
    export GITHUB_EVENT_NAME=schedule GITHUB_REF=refs/heads/develop \
        INPUT_RELEASE_TYPE="" INPUT_DEPENDENCY_BRANCH=""
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ printf '%s\n' "v9.2.0-beta"; }; \
          resolve_main 2>/dev/null)
    assert_equal "schedule + v9.2.0-beta shipped -> should_publish=false" "false" \
        "$(echo "$out" | grep '^should_publish=' | cut -d= -f2)"
    assert_equal "schedule + v9.2.0-beta shipped -> release_tag empty" "" \
        "$(echo "$out" | grep '^release_tag=' | cut -d= -f2)"
    assert_equal "schedule + v9.2.0-beta shipped -> release_type still alpha" "alpha" \
        "$(echo "$out" | grep '^release_type=' | cut -d= -f2)"

    # And the warning is on stderr; the exit code is 0 (soft, not hard).
    local err_out
    err_out=$(lookup_tags()    { :; }; \
              lookup_releases(){ printf '%s\n' "v9.2.0-beta"; }; \
              resolve_main 2>&1 >/dev/null; echo "exit=$?")
    case "$err_out" in
        *"Wixproj bump needed"*"exit=0") assert_equal "rule 3 soft on schedule emits warning, exits 0" "ok" "ok" ;;
        *) assert_equal "rule 3 soft on schedule emits warning, exits 0" "ok" "got: $err_out" ;;
    esac

    # Dispatched alpha when v9.2.0-beta shipped -> rule 3 HARD (user explicit).
    export GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/develop \
        INPUT_RELEASE_TYPE=alpha INPUT_DEPENDENCY_BRANCH=""
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ printf '%s\n' "v9.2.0-beta"; }; \
          resolve_main 2>&1 >/dev/null; echo "exit=$?")
    case "$out" in
        *"already been released"*"exit=2") assert_equal "rule 3 hard on alpha dispatch when v9.2.0-beta shipped" "ok" "ok" ;;
        *) assert_equal "rule 3 hard on alpha dispatch when v9.2.0-beta shipped" "ok" "got: $out" ;;
    esac

    # Default schedule (no shipped release) -> should_publish=true.
    export GITHUB_EVENT_NAME=schedule GITHUB_REF=refs/heads/develop \
        INPUT_RELEASE_TYPE="" INPUT_DEPENDENCY_BRANCH=""
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ :; }; \
          resolve_main 2>/dev/null)
    assert_equal "schedule + no shipped release -> should_publish=true" "true" \
        "$(echo "$out" | grep '^should_publish=' | cut -d= -f2)"
    assert_equal "schedule -> wix_major=9 wix_minor=2 surfaced" "9 2" \
        "$(echo "$out" | grep -E '^wix_(major|minor)=' | cut -d= -f2 | xargs)"

    # Alpha dispatched from any branch ref (no constraint).
    export GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/feature/X \
        INPUT_RELEASE_TYPE=alpha INPUT_DEPENDENCY_BRANCH=develop
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ :; }; \
          resolve_main 2>/dev/null)
    assert_equal "alpha + ref=feature/X succeeds" "alpha" \
        "$(echo "$out" | grep '^release_type=' | cut -d= -f2)"

    # alpha-beta dispatched from any branch ref (no constraint).
    export GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/main \
        INPUT_RELEASE_TYPE=alpha-beta INPUT_DEPENDENCY_BRANCH=develop
    out=$(lookup_tags()    { :; }; \
          lookup_releases(){ :; }; \
          resolve_main 2>/dev/null)
    assert_equal "alpha-beta + ref=main succeeds (no hard rule)" "alpha-beta" \
        "$(echo "$out" | grep '^release_type=' | cut -d= -f2)"

    rm -f "$wixproj_tmp"
    unset WIXPROJ_PATH TODAY_OVERRIDE GITHUB_EVENT_NAME GITHUB_REF INPUT_RELEASE_TYPE INPUT_DEPENDENCY_BRANCH INPUT_DEFAULT_BRANCH

    echo
    echo "Results: $pass passed, $fail failed"
    [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--self-test" ]; then
    self_test
    exit $?
fi

resolve_main
