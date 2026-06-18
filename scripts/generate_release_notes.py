#!/usr/bin/env python3
"""
Generate Markdown release notes for a BHoM installer release.

Diffs the current build's per-dep manifest against the previous release's
manifest and renders a categorised changelog: every PR merged across all
changed deps is grouped by its first matching `type:*` label, with the
source dep name prefixed inline ('[Repo_Name] PR title (#NNN, @author)').
Categories render in a fixed order (Breaking Changes first, then Features,
Bug Fixes, etc.); commits without a PR or labelled PRs without a `type:*`
fall under "Other Changes". Per-category cap keeps the body under GitHub's
125 KB release-body limit on large diff ranges.

For an initial publish (no previous manifest), lists every dep with its
current tip SHA so subsequent diffs have a baseline.

Inputs:
  argv[1]: path to current dep-manifest.json (required)
  argv[2]: path to previous dep-manifest.json (optional). Pass an empty
           string or omit for an initial publish.
  argv[3]: output Markdown path (defaults to release-notes-section.md)
  argv[4]: anchor tag for the diff heading (e.g. 'v9.1.0-beta'). Optional.

Environment:
  GH_TOKEN: a token with read access to every dep repo's commits/PRs.
            Workflow github.token is enough for public BHoM repos; the
            BHoM App token is needed when extended to private BHE deps.

Manifest schema (version 1):
  {
    "version":      1,
    "built_at":     "ISO8601",
    "release_type": "alpha"|"alpha-beta"|"beta",
    "deps": {
      "<owner>/<repo>": { "branch": "develop", "sha": "<40-char>" },
      ...
    }
  }
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request


GH_TOKEN = os.environ.get("GH_TOKEN", "")
if not GH_TOKEN:
    print("::error::GH_TOKEN env var is required", file=sys.stderr)
    sys.exit(1)


def api(path: str) -> dict | list | None:
    """Call GitHub REST API. Returns parsed JSON, or None on 4xx not-found."""
    url = f"https://api.github.com/{path.lstrip('/')}"
    req = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {GH_TOKEN}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "bhom-installer-release-notes",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        if e.code in (404, 422):
            return None
        # Surface other errors but do not crash the whole publish. A single
        # dep's API failure should not take down the release.
        print(f"::warning::HTTP {e.code} fetching {url}: {e.reason}", file=sys.stderr)
        return None
    except (urllib.error.URLError, TimeoutError) as e:
        print(f"::warning::Network error fetching {url}: {e}", file=sys.stderr)
        return None


def short(sha: str) -> str:
    return sha[:7] if sha else ""


def repo_short(repo: str) -> str:
    """'BHoM/Revit_Toolkit' -> 'Revit_Toolkit'."""
    return repo.split("/", 1)[-1] if "/" in repo else repo


# Category mapping. Order is canonical: a PR with multiple `type:*` labels is
# assigned to the first match in this dict. `type:question` is intentionally
# not mapped — questions track issues, not changes that ship. PRs with no
# `type:*` label, and commits not associated with any merged PR, fall under
# "Other Changes".
TYPE_LABEL_TO_CATEGORY: dict[str, str] = {
    "type:external-api-changes": "Breaking Changes",
    "type:feature":              "Features",
    "type:bug":                  "Bug Fixes",
    "type:user-experience":      "UX Improvements",
    "type:compliance":           "Compliance",
    "type:documentation":        "Documentation",
    "type:test-script":          "Tests",
}

CATEGORY_ORDER: list[str] = [
    "Breaking Changes",
    "Features",
    "Bug Fixes",
    "UX Improvements",
    "Compliance",
    "Documentation",
    "Tests",
    "Other Changes",
]

# Per-category cap. Entries beyond this on a single category overflow into a
# "...and N more" note rather than expanding the release body beyond GitHub's
# 125 KB limit on dep ranges that span many minor releases.
CATEGORY_CAP = 30


def categorise_pr(pr: dict) -> str:
    """Return the category header for a PR based on its first type:* label."""
    label_names = {lbl.get("name", "") for lbl in pr.get("labels") or []}
    for label, category in TYPE_LABEL_TO_CATEGORY.items():
        if label in label_names:
            return category
    return "Other Changes"


def render_initial_notes(curr: dict) -> str:
    n = len(curr.get("deps", {}))
    return (
        "### Initial release\n"
        "\n"
        f"No prior alpha release exists for comparison. The full set of "
        f"dependencies ({n} repositories, each with branch and tip SHA) is "
        "recorded in the attached `dep-manifest.json`. Future releases will "
        "include a per-repository PR diff against the prior build.\n"
    )


def collect_dep_entries(repo: str, prev_sha: str, curr_sha: str) -> list[dict]:
    """Walk the commit range for one dep and emit a flat list of entries.

    Each entry is one of:
      {kind: "pr",         repo, pr}      — a merged PR (carries its labels)
      {kind: "direct",     repo, sha, message, author}
                                         — a commit not associated with a PR
      {kind: "force_push", repo, prev_sha, curr_sha}
                                         — compare API returned no data
    Merge commits are skipped (the underlying PR carries the same content).
    """
    cmp_data = api(f"repos/{repo}/compare/{prev_sha}...{curr_sha}")
    if cmp_data is None:
        return [{
            "kind": "force_push",
            "repo": repo,
            "prev_sha": prev_sha,
            "curr_sha": curr_sha,
        }]

    commits = cmp_data.get("commits", [])
    if not commits:
        return []

    seen_pr_numbers: set[int] = set()
    entries: list[dict] = []

    for c in commits:
        if len(c.get("parents", [])) > 1:
            continue  # skip merge commits; PR entry covers their content
        sha = c["sha"]
        commit_prs = api(f"repos/{repo}/commits/{sha}/pulls") or []
        merged_prs = [p for p in commit_prs if p.get("merged_at")]
        if merged_prs:
            for pr in merged_prs:
                if pr["number"] in seen_pr_numbers:
                    continue
                seen_pr_numbers.add(pr["number"])
                entries.append({"kind": "pr", "repo": repo, "pr": pr})
        else:
            entries.append({
                "kind":    "direct",
                "repo":    repo,
                "sha":     sha,
                "message": c["commit"]["message"].split("\n", 1)[0],
                "author":  c["commit"]["author"]["name"],
            })

    return entries


def render_entry(entry: dict) -> str:
    """Render one entry as a markdown bullet."""
    r = repo_short(entry["repo"])
    if entry["kind"] == "pr":
        pr = entry["pr"]
        author = (pr.get("user") or {}).get("login", "?")
        return f"- [{r}] [{pr['title']}]({pr['html_url']}) (#{pr['number']}, @{author})"
    if entry["kind"] == "direct":
        return f"- [{r}] {entry['message']} ({entry['author']}) `{short(entry['sha'])}`"
    # force_push
    return (
        f"- [{r}] _commit range `{short(entry['prev_sha'])}...{short(entry['curr_sha'])}` "
        f"could not be resolved (force-push?). "
        f"[Compare]({'https://github.com/' + entry['repo'] + '/compare/' + entry['prev_sha'] + '...' + entry['curr_sha']})._"
    )


def render_categorised(all_entries: list[dict]) -> list[str]:
    """Group entries by category and render each category section."""
    by_category: dict[str, list[dict]] = {cat: [] for cat in CATEGORY_ORDER}
    for entry in all_entries:
        if entry["kind"] == "pr":
            by_category[categorise_pr(entry["pr"])].append(entry)
        else:
            # Direct commits and force-push markers have no PR label; bucket
            # them under Other Changes so they still surface.
            by_category["Other Changes"].append(entry)

    lines: list[str] = []
    for category in CATEGORY_ORDER:
        entries = by_category[category]
        if not entries:
            continue
        lines.append(f"#### {category}")
        lines.append("")
        for entry in entries[:CATEGORY_CAP]:
            lines.append(render_entry(entry))
        if len(entries) > CATEGORY_CAP:
            lines.append(f"- _...and {len(entries) - CATEGORY_CAP} more in this category._")
        lines.append("")
    return lines


def render_diff_notes(prev: dict, curr: dict, anchor_tag: str = "") -> str:
    prev_deps = prev.get("deps", {})
    curr_deps = curr.get("deps", {})
    prev_set = set(prev_deps)
    curr_set = set(curr_deps)

    changed = [
        (r, prev_deps[r]["sha"], curr_deps[r]["sha"])
        for r in sorted(prev_set & curr_set)
        if prev_deps[r]["sha"] != curr_deps[r]["sha"]
    ]
    added = sorted(curr_set - prev_set)
    removed = sorted(prev_set - curr_set)
    unchanged = sum(1 for r in prev_set & curr_set if prev_deps[r]["sha"] == curr_deps[r]["sha"])
    total = len(curr_set)

    heading = f"### Changes since {anchor_tag}" if anchor_tag else "### Dependency changes since previous release"
    lines = [heading, ""]

    if not changed and not added and not removed:
        lines.append("_No upstream changes since the previous release._")
        lines.append("")
        lines.append(f"_{total} of {total} dependencies unchanged._")
        lines.append("")
        return "\n".join(lines)

    # Collect entries across all changed deps, then render in flat
    # categorised form (Breaking Changes / Features / Bug Fixes / ...).
    all_entries: list[dict] = []
    for repo, p_sha, c_sha in changed:
        all_entries.extend(collect_dep_entries(repo, p_sha, c_sha))

    if all_entries:
        lines.extend(render_categorised(all_entries))

    if added:
        lines.append("#### Newly Included Dependencies")
        lines.append("")
        for repo in added:
            info = curr_deps[repo]
            lines.append(f"- {repo_short(repo)} `{short(info.get('sha', ''))}` _(no prior version)_")
        lines.append("")

    if removed:
        lines.append("#### Removed From Build")
        lines.append("")
        for repo in removed:
            lines.append(f"- {repo_short(repo)} _(was at `{short(prev_deps[repo].get('sha', ''))}`)_")
        lines.append("")

    lines.append(f"_{unchanged} of {total} dependencies unchanged since the previous release._")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    if len(sys.argv) < 2:
        print(
            "usage: generate_release_notes.py <current.json> [<previous.json>] [<out.md>] [<anchor_tag>]",
            file=sys.stderr,
        )
        return 2

    curr_path = sys.argv[1]
    prev_path = sys.argv[2] if len(sys.argv) > 2 else ""
    out_path = sys.argv[3] if len(sys.argv) > 3 else "release-notes-section.md"
    anchor_tag = sys.argv[4] if len(sys.argv) > 4 else ""

    with open(curr_path) as f:
        curr = json.load(f)

    if prev_path and os.path.isfile(prev_path):
        with open(prev_path) as f:
            prev = json.load(f)
        body = render_diff_notes(prev, curr, anchor_tag)
    else:
        print("::notice::No previous manifest provided. Emitting initial-publish baseline.")
        body = render_initial_notes(curr)

    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(body)

    print(f"::notice::Wrote {out_path} ({len(body)} chars)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
