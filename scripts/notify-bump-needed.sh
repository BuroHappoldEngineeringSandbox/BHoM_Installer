#!/usr/bin/env bash
# Open or update a tracking issue when a scheduled nightly cannot publish
# because v{WIX_MAJOR}.{WIX_MINOR}.0 has already shipped on this line
# (resolve-release-tag.sh rule 3 trip in soft mode).
#
# Build + install-test ran successfully — the smoke signal is preserved —
# but no GitHub Release was created for this run. The issue prompts a
# wixproj bump on develop so the next nightly can publish normally.
#
# Deduplicates by exact-title match: if an issue with the same title is
# already open, comment on it (one comment per failing run) instead of
# opening a fresh issue. Does NOT auto-close; the coordinator closes it
# manually after the bump PR lands.
#
# Required environment:
#   GITHUB_SERVER_URL    Provided by GitHub Actions.
#   GITHUB_REPOSITORY    Provided by GitHub Actions.
#   GITHUB_RUN_ID        Provided by GitHub Actions.
#   GITHUB_SHA           Provided by GitHub Actions.
#   GH_TOKEN             Token with 'issues: write' on the repo.
#   WIX_MAJOR / WIX_MINOR  Read from the wixproj by resolve-release-tag.sh.
set -eu

today=$(date -u +%Y-%m-%d)
run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

title="[CI] Wixproj bump needed: v${WIX_MAJOR}.${WIX_MINOR}.0 already shipped"
annotation="Wixproj bump needed for v${WIX_MAJOR}.${WIX_MINOR}.0"

# Workflow-page annotation: lower bound, fires regardless of repo config.
echo "::warning title=${annotation}::See $run_url"

# Skip tracking-issue creation if the repo has Issues disabled. The
# annotation above remains the failure marker in that case.
has_issues=$(gh api "repos/$GITHUB_REPOSITORY" --jq '.has_issues // false')
if [ "$has_issues" != "true" ]; then
    echo "::notice::Issues are disabled on $GITHUB_REPOSITORY. Skipping tracking-issue creation; the workflow annotation above remains the failure marker."
    exit 0
fi

body=$(cat <<EOF
The scheduled nightly alpha build cannot publish because \`v${WIX_MAJOR}.${WIX_MINOR}.0\` has already shipped on this line. Build and install-test ran successfully — the smoke signal is preserved — but no GitHub Release was created for this run.

To unblock further nightly publishes:

1. Bump \`BHoM_Installer.wixproj\` \`MinorVersion\` (or \`MajorVersion\` for a new major) on \`develop\`.
2. The next nightly will compute its tag against the new line and publish normally.

Build / install-test on this run: ${run_url}

This issue auto-opens on every nightly that trips this condition. Each failure run posts a comment instead of opening a new issue. Close manually once the wixproj bump PR has merged and the next nightly publishes successfully.
EOF
)

existing=$(gh issue list \
    --repo "$GITHUB_REPOSITORY" \
    --search "in:title \"$title\"" \
    --state open \
    --json number --jq '.[0].number // empty')

if [ -n "$existing" ]; then
    gh issue comment "$existing" --repo "$GITHUB_REPOSITORY" --body "Nightly $today: build + install-test green, publish skipped (rule 3 soft trip). Run: ${run_url}"
    echo "Commented on existing issue #$existing"
else
    gh issue create \
        --repo "$GITHUB_REPOSITORY" \
        --title "$title" \
        --body "$body"
fi
