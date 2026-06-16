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
#                        the canonical/non-canonical determination (canonical
#                        means develop for alpha/rc, main for final — these
#                        are the branches where release notes can be diffed
#                        meaningfully).
#   - DEPENDENCY_BRANCH  The dep-clone try-first branch. Provenance only here.
#
# Required environment:
#   INSTALLER_REF        Installer-repo branch the workflow ran on (github.ref_name).
#   DEPENDENCY_BRANCH    Dependency-branch input used by Build-Installer.ps1.
#   GITHUB_EVENT_NAME    Provided by GitHub Actions.
#   BUILT_AT             ISO8601 UTC timestamp from dep-manifest.json's built_at field.
#   GITHUB_SERVER_URL    Provided by GitHub Actions.
#   GITHUB_REPOSITORY    Provided by GitHub Actions.
#   GITHUB_RUN_ID        Provided by GitHub Actions.
#   GITHUB_SHA           Provided by GitHub Actions.
#   GH_TOKEN             Token with 'actions: read' on the repo.
#   RELEASE_TYPE         'alpha' | 'rc' | 'final'. Drives the intro sentence.
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

run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

# Decide whether this build is on the canonical lineage based on the
# installer-repo branch the workflow ran on:
#   alpha / rc -> develop
#   final      -> main (hard rule enforced at resolve)
# Anything else is a non-canonical dispatch (typically alpha from a feature
# branch), which renders a warning block instead of the diff section.
case "${RELEASE_TYPE}" in
    final)   canonical_installer_ref="main" ;;
    *)       canonical_installer_ref="develop" ;;
esac
is_non_canonical="false"
if [ "${INSTALLER_REF}" != "${canonical_installer_ref}" ]; then
    is_non_canonical="true"
fi

# Intro sentence varies by flavour.
case "${RELEASE_TYPE}" in
    final)
        intro="Release build of the BHoM installer produced by the CI pipeline."
        ;;
    rc)
        intro="Release candidate build of the BHoM installer produced by the CI pipeline during a freeze window. See the build provenance below before installing."
        ;;
    *)
        intro="Pre-release ${RELEASE_TYPE} build of the BHoM installer produced by the CI pipeline. See the build provenance below before installing."
        ;;
esac

# Per-OS test results from the workflow's Jobs API.
jobs_json=$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/jobs" --paginate)
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
