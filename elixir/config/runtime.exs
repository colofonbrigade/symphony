import Config

# Runtime configuration. Runs once per BEAM boot, after compile, before
# applications start. Functions called here must be pure — no Application env
# reads, no GenServer calls, no side effects beyond file I/O. See
# docs/elixir_rules.md § "Runtime configuration".

# Per-boot random secret. Not persisted, not shared across boots — fine for
# the observability dashboard's session cookies, which are ephemeral.
config :core, Web.Endpoint,
  secret_key_base: Base.encode64(:crypto.strong_rand_bytes(48), padding: false)

# Optional SSH config file path. `Core.SSH` reads it through Application env.
config :core, :ssh_config, System.get_env("SYMPHONY_SSH_CONFIG")

# Workflow-driven endpoint config. The entry point (`mix symphony.run`,
# `Core.CLI`) sets SYMPHONY_WORKFLOW_FILE with `System.put_env/2` before
# invoking `Mix.Task.run("app.config")` so runtime.exs can load the workflow
# and populate Application env for the endpoint.
case System.get_env("SYMPHONY_WORKFLOW_FILE") do
  nil ->
    :ok

  path ->
    expanded = Path.expand(path)
    config :core, :workflow_file_path, expanded

    # Core.Workflow.load/1 is pure: reads the file, parses YAML, expands $VAR
    # references via System.get_env. Nothing else.
    case Core.Workflow.load(expanded) do
      {:ok, %{config: %{"server" => %{"port" => port} = server}}}
      when is_integer(port) and port >= 0 ->
        host = Map.get(server, "host", "127.0.0.1")

        ip =
          case host |> String.to_charlist() |> :inet.parse_address() do
            {:ok, ip} -> ip
            {:error, _} -> {127, 0, 0, 1}
          end

        config :core, Web.Endpoint,
          server: true,
          http: [ip: ip, port: port],
          url: [host: host]

      _ ->
        :ok
    end
end
