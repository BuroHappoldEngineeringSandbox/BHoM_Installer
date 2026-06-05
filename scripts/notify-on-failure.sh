#!/usr/bin/env bash
# Open a GitHub Issue for a failed non-interactive build (scheduled nightly
# or tag-push release), or comment on an existing one if a same-day failure
# already produced one with the same title.
#
# Two layers of signal:
#   1. A workflow-page-visible '::error::' annotation. This is the lower
#      bound, visible regardless of whether the repo has Issues enabled.
#   2. A tracking Issue, created or updated. Skipped if Issues are
#      disabled on the calling repo (the annotation above remains the
#      failure marker in that case).
#
# Required environment:
#   GITHUB_SERVER_URL    Provided by GitHub Actions.
#   GITHUB_REPOSITORY    Provided by GitHub Actions.
#   GITHUB_RUN_ID        Provided by GitHub Actions.
#   GITHUB_SHA           Provided by GitHub Actions.
#   GITHUB_EVENT_NAME    Provided by GitHub Actions. Used to flavour the
#                        issue title.
#   GITHUB_REF_NAME      Provided by GitHub Actions. Used in the title for
#                        tag-push events.
#   GH_TOKEN             Token with 'issues: write' on the repo.
#   BUILD_RESULT         Result of the 'build' job ('success', 'failure', etc).
#   TEST_RESULT          Result of the 'install-test' matrix.
set -eu

today=$(date -u +%Y-%m-%d)
run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

case "$GITHUB_EVENT_NAME" in
    push)
        title="[CI] Release build failed for tag ${GITHUB_REF_NAME} ($today)"
        annotation="Release build failed for tag ${GITHUB_REF_NAME}"
        ;;
    *)
        title="[CI] Nightly alpha build failed ($today)"
        annotation="Nightly alpha build failed"
        ;;
esac

# Workflow-page annotation: lower bound, fires regardless of repo config.
echo "::error title=${annotation}::See $run_url"

# Skip tracking-issue creation if the repo has Issues disabled. This case
# surfaced on the sandbox repo when notify-on-failure was first smoke-tested:
# gh issue create errors with 'repository has disabled issues'. The
# annotation above remains the failure signal.
has_issues=$(gh api "repos/$GITHUB_REPOSITORY" --jq '.has_issues // false')
if [ "$has_issues" != "true" ]; then
    echo "::notice::Issues are disabled on $GITHUB_REPOSITORY. Skipping tracking-issue creation; the workflow annotation above remains the failure marker."
    exit 0
fi

case "$GITHUB_EVENT_NAME" in
    push)
        intro="The release build for tag \`${GITHUB_REF_NAME}\` failed. A coordinator pushed this tag expecting a finalised release; the workflow did not complete."
        ;;
    *)
        intro="The scheduled nightly alpha build failed."
        ;;
esac

body=$(cat <<EOF
${intro}

- **Run:** ${run_url}
- **Commit:** \`${GITHUB_SHA}\`
- **build job:** \`${BUILD_RESULT}\`
- **install-test matrix:** \`${TEST_RESULT}\`

See the run log for details. This issue auto-opens when a non-interactive
build fails; close it once the underlying problem is resolved.
EOF
)

# Avoid spamming: if an open issue already exists with this exact title
# (another failure already happened today), comment on it instead of
# opening a duplicate.
existing=$(gh issue list \
    --repo "$GITHUB_REPOSITORY" \
    --search "in:title \"$title\"" \
    --state open \
    --json number --jq '.[0].number // empty')

if [ -n "$existing" ]; then
    gh issue comment "$existing" --repo "$GITHUB_REPOSITORY" --body "$body"
    echo "Commented on existing issue #$existing"
else
    gh issue create \
        --repo "$GITHUB_REPOSITORY" \
        --title "$title" \
        --body "$body"
fi
