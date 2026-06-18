#!/usr/bin/env bash
# Compose the release body for the publish workflow job.
#
# Reads inputs from environment variables and writes the final body to
# release-body.md in the current working directory. The body is composed
# of three parts:
#   1. A short preamble with build provenance (including separate rows for
#      installer branch and dependency branch).
#   2. A per-environment Test results table, populated from the workflow's
#      Jobs API so it picks up every matrix leg automatically.
#   3. The dependency-change section produced by generate_release_notes.py
#      and read from release-notes-section.md.
#
# This script is only invoked when the publish gate (success() on all
# dependent jobs) passed. Test results will therefore always show
# 'Passed' in current behaviour, but the table form lets users see
# which environments were exercised and click through to the per-leg job.
#
# Three-input model (see proposal.md Section 6):
#   - INSTALLER_REF      The installer-repo branch the workflow ran on. Drives
#                        the "canonical installer ref" check below — canonical
#                        means the repo's default branch (passed in via
#                        CANONICAL_INSTALLER_REF), the same branch alpha
#                        schedules run from and beta dispatches are constrained to.
#   - DEPENDENCY_BRANCH  The dep-clone try-first branch. Provenance only here.
#
# Required environment:
#   INSTALLER_REF        Installer-repo branch the workflow ran on (github.ref_name).
#   CANONICAL_INSTALLER_REF  Repo default branch (e.g. 'develop'). Sourced from
#                            github.event.repository.default_branch in the workflow.
#   DEPENDENCY_BRANCH    Dependency-branch input used by Build-Installer.ps1.
#   GITHUB_EVENT_NAME    Provided by GitHub Actions.
#   BUILT_AT             ISO8601 UTC timestamp from dep-manifest.json's built_at field.
#   GITHUB_SERVER_URL    Provided by GitHub Actions.
#   GITHUB_REPOSITORY    Provided by GitHub Actions.
#   GITHUB_RUN_ID        Provided by GitHub Actions.
#   GITHUB_SHA           Provided by GitHub Actions.
#   GH_TOKEN             Token with 'actions: read' on the repo.
#   RELEASE_TYPE         'alpha' | 'alpha-beta' | 'beta'. Drives the intro sentence.
#   IS_PRERELEASE        'true' or 'false'. Drives the intro sentence.
#
# Optional local file:
#   release-notes-section.md  Output from generate_release_notes.py.
#                             Required when the canonical render branch fires.
#                             Otherwise the non-canonical warning block is emitted.
#
# Output:
#   release-body.md      Final body, ready for softprops/action-gh-release.
set -eu

# ─── overridable IO (for --self-test) ──────────────────────────────────────

# Fetch the jobs JSON for the current workflow run. Override in tests by
# redefining this function before invoking the main body of the script.
lookup_jobs_json() {
    gh api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/jobs" --paginate
}

compose_main() {

run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

# canonical installer_ref is the repo's default branch, regardless of release
# type. For beta the rule is hard-enforced at resolve time (rule 6); for alpha
# and alpha-beta the schedule trigger and dispatch convention both land here,
# while dispatched feature-branch alphas are explicitly non-canonical.
canonical_installer_ref="${CANONICAL_INSTALLER_REF:-}"
if [ -z "$canonical_installer_ref" ]; then
    echo "::error::CANONICAL_INSTALLER_REF is required (workflow should pass github.event.repository.default_branch)." >&2
    return 3
fi
is_non_canonical="false"
if [ "${INSTALLER_REF}" != "${canonical_installer_ref}" ]; then
    is_non_canonical="true"
fi

# Intro sentence varies by flavour.
case "${RELEASE_TYPE}" in
    beta)
        intro="Release build of the BHoM installer produced by the CI pipeline."
        ;;
    alpha-beta)
        intro="Release candidate build of the BHoM installer produced by the CI pipeline during a freeze window. See the build provenance below before installing."
        ;;
    *)
        intro="Pre-release ${RELEASE_TYPE} build of the BHoM installer produced by the CI pipeline. See the build provenance below before installing."
        ;;
esac

# Per-OS test results from the workflow's Jobs API.
jobs_json=$(lookup_jobs_json)
test_results_rows=$(echo "$jobs_json" | jq -r '
    .jobs
    | map(select(.name | startswith("Install + uninstall (")))
    | sort_by(.name)
    | map(
        "| " + (.name | sub("Install \\+ uninstall \\("; "") | sub("\\)$"; ""))
        + " | ["
        + (
            if .conclusion == "success" then "Passed"
            elif .conclusion == "failure" then "Failed"
            elif .conclusion == "skipped" then "Skipped"
            elif .conclusion == "cancelled" then "Cancelled"
            else .conclusion
            end
          )
        + "](" + .html_url + ") |"
      )
    | .[]
')

if [ -z "$test_results_rows" ]; then
    test_results_rows="| (no matrix legs detected) | |"
fi

# Compose the head of the body. Installer branch and dependency branch are
# rendered as separate provenance rows so a reader can see exactly which
# branch the installer code came from versus which branch was tried on
# each dep clone (these can differ deliberately).
cat >release-body.md <<EOF
${intro}

### Build provenance

| Field | Value |
|---|---|
| Build | [#${GITHUB_RUN_ID}]($run_url) |
| Built at | \`${BUILT_AT}\` |
| Commit | \`${GITHUB_SHA}\` |
| Triggered by | \`${GITHUB_EVENT_NAME}\` |
| Installer branch | \`${INSTALLER_REF}\` |
| Dependency branch | \`${DEPENDENCY_BRANCH}\` |

### Test results

| Environment | Result |
|---|---|
${test_results_rows}

EOF

# Two render branches for the diff section.
if [ "$is_non_canonical" = "true" ]; then
    # Warning block. No diff section.
    cat >>release-body.md <<EOF
> Non-canonical installer branch. This build was produced from \`${INSTALLER_REF}\`, not the conventional \`${canonical_installer_ref}\` for ${RELEASE_TYPE}. The changelog is omitted because a non-canonical build cannot be compared meaningfully against the canonical release line.
>
> Dependency branches and commit SHAs are recorded in the attached \`dep-manifest.json\`. For canonical builds, see the [releases page](${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/releases).
EOF
else
    # Canonical path. The python script emits its own heading
    # (### Changes since {anchor} or ### Initial release).
    if [ -f release-notes-section.md ]; then
        cat release-notes-section.md >> release-body.md
    else
        printf '### Initial release\n\nNo dependency diff section was produced for this build.\n' >> release-body.md
    fi
fi

echo ""
echo "=== Release body preview (first 80 lines) ==="
head -80 release-body.md

}  # end compose_main

# ─── self-test harness ─────────────────────────────────────────────────────

self_test() {
    local pass=0 fail=0
    assert_contains() {
        local desc="$1" needle="$2" haystack="$3"
        if [[ "$haystack" == *"$needle"* ]]; then
            echo "PASS: $desc"
            pass=$((pass + 1))
        else
            echo "FAIL: $desc"
            echo "  expected to contain: $needle"
            fail=$((fail + 1))
        fi
    }
    assert_not_contains() {
        local desc="$1" needle="$2" haystack="$3"
        if [[ "$haystack" != *"$needle"* ]]; then
            echo "PASS: $desc"
            pass=$((pass + 1))
        else
            echo "FAIL: $desc"
            echo "  expected NOT to contain: $needle"
            fail=$((fail + 1))
        fi
    }
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

    # Stub gh; the canonical-path tests exercise lookup_jobs_json directly.
    lookup_jobs_json() {
        cat <<'EOF'
{
  "jobs": [
    { "name": "Install + uninstall (windows-2022)", "conclusion": "success",
      "html_url": "https://example.com/job/1" },
    { "name": "Install + uninstall (windows-2025)", "conclusion": "success",
      "html_url": "https://example.com/job/2" },
    { "name": "Build alpha installer", "conclusion": "success",
      "html_url": "https://example.com/job/3" }
  ]
}
EOF
    }

    # Shared env (workflow-style values).
    setup_env() {
        export GITHUB_SERVER_URL="https://example.com"
        export GITHUB_REPOSITORY="example-org/example-repo"
        export GITHUB_RUN_ID="123456"
        export GITHUB_SHA="abcdef1234567890"
        export GITHUB_EVENT_NAME="workflow_dispatch"
        export BUILT_AT="2026-06-18T10:00:00.0000000+00:00"
        export DEPENDENCY_BRANCH="develop"
        export IS_PRERELEASE="false"
        export CANONICAL_INSTALLER_REF="develop"
    }

    local tmpdir; tmpdir=$(mktemp -d)
    cd "$tmpdir"

    # ── Error path: empty CANONICAL_INSTALLER_REF ──
    setup_env
    export CANONICAL_INSTALLER_REF=""
    export INSTALLER_REF="develop"
    export RELEASE_TYPE="alpha"
    local out
    out=$(compose_main 2>&1 || true)
    assert_contains "missing CANONICAL_INSTALLER_REF errors" "CANONICAL_INSTALLER_REF is required" "$out"

    # ── Canonical render: alpha schedule from default branch ──
    setup_env
    export INSTALLER_REF="develop"
    export RELEASE_TYPE="alpha"
    export GITHUB_EVENT_NAME="schedule"
    rm -f release-notes-section.md release-body.md
    compose_main >/dev/null 2>&1
    local body; body=$(cat release-body.md)
    assert_contains "alpha intro present" "Pre-release alpha build" "$body"
    assert_contains "alpha schedule renders provenance"  "### Build provenance" "$body"
    assert_contains "alpha schedule renders installer branch" "| Installer branch | \`develop\` |" "$body"
    assert_contains "alpha schedule renders dependency branch" "| Dependency branch | \`develop\` |" "$body"
    assert_contains "alpha schedule renders test-results table" "### Test results" "$body"
    assert_contains "alpha schedule includes windows-2022 row" "| windows-2022 |" "$body"
    assert_contains "alpha schedule includes windows-2025 row" "| windows-2025 |" "$body"
    assert_not_contains "canonical render does NOT include non-canonical warning" \
        "Non-canonical installer branch" "$body"
    assert_contains "canonical render with no notes file falls back to initial-release stub" \
        "### Initial release" "$body"

    # ── Canonical render with release-notes-section.md present ──
    setup_env
    export INSTALLER_REF="develop"
    export RELEASE_TYPE="alpha"
    printf '### Changes since v9.1.0-beta\n\n- Dep X bumped to v2.\n' >release-notes-section.md
    rm -f release-body.md
    compose_main >/dev/null 2>&1
    body=$(cat release-body.md)
    assert_contains "canonical render emits release-notes-section content" "Changes since v9.1.0-beta" "$body"
    assert_contains "canonical render emits dep diff line" "Dep X bumped to v2" "$body"
    assert_not_contains "canonical render with notes file does NOT emit initial-release stub" \
        "### Initial release" "$body"
    rm -f release-notes-section.md

    # ── Non-canonical render: dispatched alpha from a feature branch ──
    setup_env
    export INSTALLER_REF="feature/wix-pin-test"
    export RELEASE_TYPE="alpha"
    rm -f release-body.md
    compose_main >/dev/null 2>&1
    body=$(cat release-body.md)
    assert_contains "non-canonical render emits warning" "Non-canonical installer branch" "$body"
    assert_contains "non-canonical render names the build branch" "feature/wix-pin-test" "$body"
    assert_contains "non-canonical render names the canonical branch" "conventional \`develop\`" "$body"
    assert_not_contains "non-canonical render does NOT emit dep-diff section" \
        "### Changes since" "$body"

    # ── Intro sentence varies by release type ──
    setup_env
    export INSTALLER_REF="develop"
    export RELEASE_TYPE="beta"
    rm -f release-body.md
    compose_main >/dev/null 2>&1
    body=$(cat release-body.md)
    assert_contains "beta intro: release build language" "Release build" "$body"
    assert_not_contains "beta intro does NOT use pre-release language" "Pre-release" "$body"

    setup_env
    export INSTALLER_REF="develop"
    export RELEASE_TYPE="alpha-beta"
    rm -f release-body.md
    compose_main >/dev/null 2>&1
    body=$(cat release-body.md)
    assert_contains "alpha-beta intro: release-candidate language" "Release candidate build" "$body"
    assert_contains "alpha-beta intro: freeze-window context" "freeze window" "$body"

    # ── Test-results table reflects every matrix leg present ──
    # The fixture has windows-2022 + windows-2025 + a Build leg. Only the
    # two install-test legs should appear in the table.
    setup_env
    export INSTALLER_REF="develop"
    export RELEASE_TYPE="alpha"
    rm -f release-body.md
    compose_main >/dev/null 2>&1
    body=$(cat release-body.md)
    assert_not_contains "Build leg is filtered out of test-results table" "| Build alpha installer |" "$body"

    cd - >/dev/null
    rm -rf "$tmpdir"

    echo
    echo "Results: $pass passed, $fail failed"
    [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--self-test" ]; then
    self_test
    exit $?
fi

compose_main || exit $?
