# Local Elixir Rules (Symphony)

Project-specific boundary and structural rules for this repo. Applied in addition to the shared
ruleset in [`elixir_rules.md`](elixir_rules.md). If a rule here conflicts with the shared ruleset,
this file wins locally; consider whether the divergence should be upstreamed.

## Boundaries in this repo

- `Core` — Orchestrator, agent runner, workspace management, telemetry, workflow loader, status
  dashboard *coordinator* (the GenServer; rendering lives in `CLI`). The domain core.
- `Web` — Phoenix endpoint, LiveView dashboard, JSON observability API. Depends on `Core` +
  `Schema`.
- `Schema` — Shared structs used across boundaries (`Schema.Snapshot`, `Schema.Tracker.Issue`).
  Leaf: depends on nothing in-app.
- `Linear` — Linear tracker integration (GraphQL client, response decoder, tracker adapter).
  Implements `Linear.Tracker` (behaviour) which `Core.Tracker` dispatches to, threading
  tracker settings in at call time. Owned by the integration, not the domain core, so a
  second tracker could be added as a peer boundary without touching `Core` internals.
- `Claude` — Claude Code subprocess/SSH session client. Decoupled from Core: callers pass
  `claude` settings and `workspace_root` into `Claude.Session.start_session/2` rather than
  `Claude` reading Application env itself. Depends on `Permissions` + `Transport`.
- `Transport` — Low-level communication primitives. Today: `Transport.SSH`. Future home for
  other transports (gRPC, MQTT, etc.). Leaf-ish: reads `:ssh_config` from Application env,
  no in-app deps.
- `Permissions` — Security-sensitive pure utilities. Today: `Permissions.PathSafety` (path
  traversal / symlink-escape guards). Leaf: no state, no config, no in-app deps.
- `CLI` — Pure terminal-UI rendering. `CLI.StatusDashboard` formats an orchestrator snapshot +
  context map into an ANSI string; `Core.StatusDashboard` composes Config reads, builds the
  context, and writes the result to stdout. Future home for alternate renderers (JSON, minimal)
  or non-dashboard CLI output. Depends on `Schema`; depended on by `Core`.
- `Utils` — Cross-cutting infrastructure helpers. Today houses `Utils.Runtime`, a thin
  `ProcessTree` accessor with Application-env fallback. Leaf of the DAG; any boundary may depend
  on it. **Long-lived GenServers must not read config through `Utils.Runtime`** — the cache
  lives in their own dict and pins stale values. Such callers use `Application.get_env` directly
  (see `Core.Workflow.workflow_file_path/0`, `Core.Config.server_port/0`).

