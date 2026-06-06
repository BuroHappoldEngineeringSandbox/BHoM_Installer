#!/usr/bin/env bash
# Compose the release body for the publish-alpha workflow job.
#
# Reads inputs from environment variables and writes the final body to
# release-body.md in the current working directory. The body is composed
# of three parts:
#   1. A short preamble with build provenance.
#   2. A per-environment Test results table, populated from the workflow's
#      Jobs API so it picks up every matrix leg automatically.
#   3. The dependency-change section produced by generate_release_notes.py
#      and read from release-notes-section.md.
#
# This script is only invoked when the publish gate (success() on all
# dependent jobs) passed. Test results will therefore always show
# 'Passed' in current behaviour, but the table form lets users see
# which environments were exercised and click through to the per-leg job.
# If we later add matrix legs (for example windows-11), they will
# appear automatically without further changes here.
#
# Required environment:
#   BUILT_AT             ISO8601 UTC timestamp from dep-manifest.json's built_at field.
#   GITHUB_SERVER_URL    Provided by GitHub Actions.
#   GITHUB_REPOSITORY    Provided by GitHub Actions.
#   GITHUB_RUN_ID        Provided by GitHub Actions.
#   GITHUB_SHA           Provided by GitHub Actions.
#   GITHUB_EVENT_NAME    Provided by GitHub Actions.
#   GH_TOKEN             Token with 'actions: read' on the repo.
#   RELEASE_TYPE         'alpha' or 'beta'. Drives the intro sentence.
#   IS_PRERELEASE        'true' or 'false'. Drives the intro sentence.
#   PREV_TAG             Prior release tag for the diff base, or empty
#                        string if no prior release exists.
#
# Required local file:
#   release-notes-section.md  Output from generate_release_notes.py.
#
# Output:
#   release-body.md           Final body, ready for softprops/action-gh-release.
set -eu

run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

if [ -n "$PREV_TAG" ]; then
    diff_note="Changes are computed against [\`$PREV_TAG\`](${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/releases/tag/${PREV_TAG})."
else
    diff_note="No prior release was found, so this build is published as an initial baseline."
fi

# Intro sentence varies by release flavour. Three cases:
#   alpha prerelease      'Pre-release alpha build of the BHoM installer...'
#   beta prerelease       'Pre-release beta build of the BHoM installer...'
#   beta release (tag)    'Release build of the BHoM installer...'
if [ "$IS_PRERELEASE" = "true" ]; then
    intro="Pre-release ${RELEASE_TYPE} build of the BHoM installer produced by the CI pipeline. See the build provenance below before installing."
else
    intro="Release build of the BHoM installer produced by the CI pipeline from a tagged commit on main."
fi

# Per-OS test results from the workflow's Jobs API. Filter to install-test
# matrix legs by name prefix; matrix substitution renders as
# "Install + uninstall (windows-2022)" etc.
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

cat >release-body.md <<EOF
${intro}

### Build provenance

| Field | Value |
|---|---|
| Build | [#${GITHUB_RUN_ID}]($run_url) |
| Built at | \`${BUILT_AT}\` |
| Commit | \`${GITHUB_SHA}\` |
| Triggered by | \`${GITHUB_EVENT_NAME}\` |

### Test results

| Environment | Result |
|---|---|
${test_results_rows}

### Changes

$diff_note

EOF
cat release-notes-section.md >> release-body.md

echo ""
echo "=== Release body preview (first 80 lines) ==="
head -80 release-body.md
