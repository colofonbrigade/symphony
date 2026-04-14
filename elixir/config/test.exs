import Config

config :core, Core.Telemetry.Repo,
  database: ":memory:",
  pool_size: 1,
  priv: "priv/telemetry_repo"

# Long-lived processes (WorkflowStore, Orchestrator, StatusDashboard) outlive
# individual tests; caching ProcessTree lookups in their dict would pin one
# test's value and serve it to later tests. Disable caching in test only.
config :core, Core.Runtime, cache_reads: false

# Terminal dashboard renders noisy ANSI into captured IO during tests and
# has its own snapshot coverage; skip the live render loop here.
config :core, Core.StatusDashboard, render: false
