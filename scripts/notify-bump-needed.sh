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

# ─── overridable IO (for --self-test) ──────────────────────────────────────

# Print 'true' or 'false' depending on whether the repo has Issues enabled.
lookup_has_issues() {
    gh api "repos/$GITHUB_REPOSITORY" --jq '.has_issues // false'
}

# Print the number of an open issue whose title matches $1 exactly, or
# empty string if none exists.
lookup_existing_issue() {
    local title="$1"
    gh issue list \
        --repo "$GITHUB_REPOSITORY" \
        --search "in:title \"$title\"" \
        --state open \
        --json number --jq '.[0].number // empty'
}

# Post a comment on issue $1 with body $2.
post_comment() {
    local issue="$1" body="$2"
    gh issue comment "$issue" --repo "$GITHUB_REPOSITORY" --body "$body"
}

# Create a new issue with title $1 and body $2.
create_issue() {
    local title="$1" body="$2"
    gh issue create --repo "$GITHUB_REPOSITORY" --title "$title" --body "$body"
}

# ─── core logic ─────────────────────────────────────────────────────────────

notify_main() {
    local today; today=$(date -u +%Y-%m-%d)
    local run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

    local title="[CI] Wixproj bump needed: v${WIX_MAJOR}.${WIX_MINOR}.0-beta already shipped"
    local annotation="Wixproj bump needed for v${WIX_MAJOR}.${WIX_MINOR}.0-beta"

    # Workflow-page annotation: lower bound, fires regardless of repo config.
    echo "::warning title=${annotation}::See $run_url"

    # Skip tracking-issue creation if the repo has Issues disabled. The
    # annotation above remains the failure marker in that case.
    local has_issues; has_issues=$(lookup_has_issues)
    if [ "$has_issues" != "true" ]; then
        echo "::notice::Issues are disabled on $GITHUB_REPOSITORY. Skipping tracking-issue creation; the workflow annotation above remains the failure marker."
        return 0
    fi

    local body
    body=$(cat <<EOF
The scheduled nightly alpha build cannot publish because \`v${WIX_MAJOR}.${WIX_MINOR}.0-beta\` has already shipped on this line. Build and install-test ran successfully — the smoke signal is preserved — but no GitHub Release was created for this run.

To unblock further nightly publishes:

1. Bump \`BHoM_Installer.wixproj\` \`MinorVersion\` (or \`MajorVersion\` for a new major) on \`develop\`.
2. The next nightly will compute its tag against the new line and publish normally.

Build / install-test on this run: ${run_url}

This issue auto-opens on every nightly that trips this condition. Each failure run posts a comment instead of opening a new issue. Close manually once the wixproj bump PR has merged and the next nightly publishes successfully.
EOF
)

    local existing; existing=$(lookup_existing_issue "$title")

    if [ -n "$existing" ]; then
        post_comment "$existing" "Nightly $today: build + install-test green, publish skipped (rule 3 soft trip). Run: ${run_url}"
        echo "Commented on existing issue #$existing"
    else
        create_issue "$title" "$body"
    fi
}

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

    setup_env() {
        export GITHUB_SERVER_URL="https://example.com"
        export GITHUB_REPOSITORY="example-org/example-repo"
        export GITHUB_RUN_ID="123456"
        export GITHUB_SHA="abcdef1234567890"
        export WIX_MAJOR="9"
        export WIX_MINOR="2"
    }

    # ── has_issues=false short-circuits ──
    setup_env
    lookup_has_issues() { echo "false"; }
    # These should NOT be called when has_issues=false:
    lookup_existing_issue() { echo "::error::lookup_existing_issue was called when has_issues=false" >&2; echo ""; }
    post_comment()         { echo "::error::post_comment was called when has_issues=false" >&2; }
    create_issue()         { echo "::error::create_issue was called when has_issues=false" >&2; }

    local out err
    out=$(notify_main 2>&1)
    assert_contains "annotation emitted (always)" "::warning title=Wixproj bump needed for v9.2.0-beta::" "$out"
    assert_contains "has_issues=false path: notice printed" "Issues are disabled on example-org/example-repo" "$out"
    assert_not_contains "has_issues=false path: no create_issue call" "create_issue was called" "$out"
    assert_not_contains "has_issues=false path: no post_comment call" "post_comment was called" "$out"

    # ── No existing issue: create_issue called ──
    setup_env
    lookup_has_issues()     { echo "true"; }
    lookup_existing_issue() { echo ""; }   # no existing
    local captured_title="" captured_body=""
    create_issue() {
        captured_title="$1"
        captured_body="$2"
        echo "create_issue: title=$1"
    }
    post_comment() { echo "::error::post_comment was called when no existing issue" >&2; }

    out=$(notify_main 2>&1)
    assert_contains "create path: create_issue invoked" "create_issue: title=" "$out"
    # captured_title is unavailable in the subshell — re-run via process substitution
    # to capture inside the same shell.
    setup_env
    lookup_has_issues()     { echo "true"; }
    lookup_existing_issue() { echo ""; }
    create_issue() { captured_title="$1"; captured_body="$2"; }
    post_comment() { :; }
    notify_main >/dev/null 2>&1
    assert_contains "title format includes wixproj version + line"     "[CI] Wixproj bump needed: v9.2.0-beta already shipped" "$captured_title"
    assert_contains "body includes run URL"                              "actions/runs/123456" "$captured_body"
    assert_contains "body includes wixproj bump instruction"             "Bump \`BHoM_Installer.wixproj\` \`MinorVersion\`" "$captured_body"
    assert_contains "body explains soft-trip behaviour"                  "smoke signal is preserved" "$captured_body"
    assert_contains "body mentions tag form vM.N.0-beta"                 "v9.2.0-beta\` has already shipped" "$captured_body"

    # ── Existing issue: post_comment called, create_issue NOT called ──
    setup_env
    lookup_has_issues()     { echo "true"; }
    lookup_existing_issue() { echo "42"; }
    local captured_comment_target="" captured_comment_body=""
    post_comment() { captured_comment_target="$1"; captured_comment_body="$2"; }
    create_issue() { echo "::error::create_issue was called when existing issue present" >&2; }

    out=$(notify_main 2>&1)
    assert_contains "dedup path: confirms commented on existing issue" "Commented on existing issue #42" "$out"
    assert_not_contains "dedup path: no create_issue call" "create_issue was called" "$out"

    setup_env
    lookup_has_issues()     { echo "true"; }
    lookup_existing_issue() { echo "42"; }
    post_comment() { captured_comment_target="$1"; captured_comment_body="$2"; }
    create_issue() { :; }
    notify_main >/dev/null 2>&1
    [ "$captured_comment_target" = "42" ] && \
        { echo "PASS: dedup path: comment posted on issue #42"; pass=$((pass + 1)); } || \
        { echo "FAIL: dedup path: comment posted on issue #42 (got: $captured_comment_target)"; fail=$((fail + 1)); }
    assert_contains "dedup comment includes run URL"      "actions/runs/123456"  "$captured_comment_body"
    assert_contains "dedup comment mentions rule 3 soft"  "rule 3 soft trip"     "$captured_comment_body"

    # ── Title format is sensitive to wix version ──
    setup_env
    export WIX_MAJOR="10"; export WIX_MINOR="14"
    lookup_has_issues()     { echo "true"; }
    lookup_existing_issue() { echo ""; }
    create_issue() { captured_title="$1"; }
    post_comment() { :; }
    notify_main >/dev/null 2>&1
    assert_contains "title reflects WIX_MAJOR/WIX_MINOR (10.14)" "v10.14.0-beta already shipped" "$captured_title"

    echo
    echo "Results: $pass passed, $fail failed"
    [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--self-test" ]; then
    self_test
    exit $?
fi

notify_main || exit $?
