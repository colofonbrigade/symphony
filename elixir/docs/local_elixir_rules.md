# Local Elixir Rules (Symphony)

Project-specific boundary and structural rules for this repo. Applied in addition to the shared
ruleset in [`elixir_rules.md`](elixir_rules.md). If a rule here conflicts with the shared ruleset,
this file wins locally; consider whether the divergence should be upstreamed.

## Boundaries in this repo

- `Core` — Orchestrator, workspace management, Claude Code session runner, telemetry, workflow
  loader, status dashboard.
- `Web` — Phoenix endpoint, LiveView dashboard, JSON observability API. Depends on `Core`.
- `Linear` — Linear tracker integration (GraphQL client, response decoding, tracker adapter).
  Owned by the integration, not the domain core, so a second tracker can be added as a peer
  boundary without touching `Core` internals. `Core` depends on `Linear` through its public
  adapter surface only.
