---
name: linear
description: |
  Interact with Linear (issues, comments, projects, workflow states) via the
  official Linear MCP server. Use this skill for any Linear operation Symphony's
  agents need: looking up tickets, transitioning state, posting/updating the
  workpad comment, attaching links, uploading files, and creating follow-up
  issues.
---

# Linear

Use this skill for all Linear operations during Symphony orchestration.
Symphony configures the official Linear MCP server in the Claude Code session,
which exposes a curated set of typed tools. There is no raw GraphQL tool — work
with the curated tools below.

## Tool surface

The official Linear MCP exposes its tools under the `mcp__claude_ai_Linear__*`
namespace. The ones Symphony uses most:

- `get_issue` — fetch a single issue by identifier (`MT-625`) or UUID
- `list_issues` — search/filter issues
- `list_comments` — list comments on an issue (used to find the workpad)
- `save_comment` — create a comment, or update one by passing `id`
- `save_issue` — create or update an issue (state, links, assignee, labels, etc.)
- `list_issue_statuses` — list workflow states for a team
- `get_team` / `list_teams` — team metadata
- `get_project` / `list_projects` — project metadata
- `create_attachment` — upload a file (base64) as an issue attachment
- `list_users` / `get_user` — user lookups (assignee resolution)

For anything outside this set, see "When you cannot complete the operation" at the bottom.

## Lookup an issue

Always start with the smallest call that gets you what you need.

```
get_issue(id: "MT-625")
```

`get_issue` accepts either the human identifier (`MT-625`) or the internal
UUID. The returned shape includes `id`, `identifier`, `title`, `state`,
`project`, `description`, `url`, `gitBranchName`, `labels`, `attachments`, and
related metadata.

If you do not know the exact identifier, fall back to `list_issues` with a
query:

```
list_issues(query: "auth bug", team: "MT", limit: 5)
```

## Workpad comment (find / create / update)

Symphony uses a single persistent comment per issue (`## Claude Workpad`) as
the source of truth for in-flight work. The protocol:

1. **Find the workpad**: call `list_comments(issueId: "MT-625")` and search for
   the comment whose body starts with `## Claude Workpad`. Ignore resolved
   comments.
2. **Reuse** if found — capture its `id` so you can update in place.
3. **Create** if missing: `save_comment(issueId: "MT-625", body: "## Claude Workpad\n\n…")`
4. **Update** during execution: `save_comment(id: "<workpad-id>", body: "<full new body>")`

`save_comment` updates take the **full** new body — there is no partial-update
or append. Always render the entire workpad content in each update so the
checklist stays consistent.

Never create a second workpad on the same issue. Capture the workpad ID once
and reuse it for every update during the session.

## Transition issue state

`save_issue` accepts the `state` field by name, ID, or type, so the common
case is a one-call update:

```
save_issue(id: "MT-625", state: "In Progress")
```

If a state name is ambiguous across teams, look up the exact ID first via
`list_issue_statuses(team: "MT")` and pass the ID.

## Attach a link to an issue

For PR URLs and other generic links, use `save_issue` with the `links`
parameter (append-only — existing links are not removed):

```
save_issue(
  id: "MT-625",
  links: [{url: "https://github.com/org/repo/pull/123", title: "PR #123"}]
)
```

**Note on GitHub PRs**: Linear's built-in GitHub integration auto-attaches PRs
when the branch name contains the issue identifier (Symphony enforces this
convention via `gitBranchName`). You usually do **not** need to call
`save_issue` to attach a PR — Linear creates a rich PR attachment with status
sync (open / merged / closed) automatically. Use `save_issue` with `links`
only when the auto-attachment is unavailable or you need to attach a non-branch
URL.

## Upload a file or image as an attachment

Use `create_attachment` with base64-encoded content:

```
create_attachment(
  issue: "MT-625",
  filename: "screenshot.png",
  contentType: "image/png",
  base64Content: "<base64 string>",
  title: "Repro screenshot"
)
```

This handles the upload flow end-to-end — there is no separate "request signed
URL then PUT" dance needed.

## Create a follow-up issue (out-of-scope work)

When you discover work that is out of scope and should be tracked separately,
file a new issue rather than expanding the current one's scope:

```
save_issue(
  team: "MT",
  title: "Refactor X for Y",
  description: "## Context\n…\n\n## Acceptance\n…",
  project: "ayudante",
  state: "Backlog",
  relatedTo: ["MT-625"],
  blockedBy: ["MT-625"]
)
```

`save_issue` without `id` creates a new issue. With `id` it updates an existing
one. Use `relatedTo` to link the follow-up to the current ticket; add
`blockedBy` only when the follow-up genuinely depends on the current work.

## Issue assignment

Use the `assignee` field on `save_issue` (accepts user ID, name, email, or
"me"):

```
save_issue(id: "MT-625", assignee: "me")
save_issue(id: "MT-625", assignee: null)   # remove
```

## Labels

Add labels via `save_issue`:

```
save_issue(id: "MT-625", labels: ["symphony", "backend"])
```

## Usage rules

- Prefer the narrowest call that gets you what you need: `get_issue` over
  `list_issues`, `save_comment(id: …)` over creating a duplicate.
- Workpad comments are **edited in place** — never create a second workpad on
  the same issue. Capture the workpad ID via `list_comments` once and reuse it
  for every update.
- For state transitions, pass the state name to `save_issue` directly. Only
  fall back to `list_issue_statuses` when the name is ambiguous or rejected.
- Do not call `gh api`, `curl`, or any shell helpers for Linear operations —
  use the MCP tools.
- The MCP handles authentication transparently via Symphony's session OAuth.
  Do not look up or pass `LINEAR_API_KEY` directly.

## When you cannot complete the operation

If a Linear operation you need is not available through the tools above, do
not invent a workaround (no shell calls, no `gh api`, no raw HTTP). The
correct escalation path is:

1. Update the `## Claude Workpad` comment with a short blocker note describing
   what you tried to do, which tool you reached for, and why it did not work.
2. Move the issue to `Human Review` via `save_issue(id: …, state: "Human Review")`.

This surfaces the gap to a human who can either expand the available tooling
or perform the operation manually. Do not stay stuck retrying the same
unavailable operation.
