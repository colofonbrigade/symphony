import Config

config :phoenix, :json_library, Jason

config :core, Web.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: Web.ErrorHTML, json: Web.ErrorJSON],
    layout: false
  ],
  pubsub_server: Core.PubSub,
  live_view: [signing_salt: "symphony-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: false,
  orchestrator: Core.Orchestrator,
  snapshot_timeout_ms: 15_000

config :core, Core.Tracker, adapter: Linear.Adapter

config :core, Core.StatusDashboard, render: true

config :core, ecto_repos: [Core.Telemetry.Repo]

config :core, Core.Telemetry.Repo,
  database: Path.join(System.user_home!() || System.tmp_dir!(), ".symphony/telemetry.db"),
  journal_mode: :wal,
  pool_size: 1,
  priv: "priv/telemetry_repo"

import_config "#{config_env()}.exs"
