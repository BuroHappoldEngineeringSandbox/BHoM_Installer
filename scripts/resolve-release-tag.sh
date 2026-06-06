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

    # Placeholder failing case — replaced in subsequent tasks.
    assert_equal "placeholder" "expected" "actual"

    echo
    echo "Results: $pass passed, $fail failed"
    [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--self-test" ]; then
    self_test
    exit $?
fi

resolve_main
