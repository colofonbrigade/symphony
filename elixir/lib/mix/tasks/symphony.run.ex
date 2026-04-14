defmodule Mix.Tasks.Symphony.Run do
  use Mix.Task

  alias Core.LogFile

  @moduledoc """
  Starts Symphony against a specified workflow file without going through the
  escript entry point. Useful for local dev and smoke tests where NIF-backed
  deps (e.g. SQLite) can't load from inside an escript archive.

      mix symphony.run workflows/smoke-test.md
      mix symphony.run --logs-root ~/tmp/symphony-logs --port 4001 workflows/smoke-test.md
  """
  @shortdoc "Run Symphony against a workflow file (no escript, no banner)"

  @switches [logs_root: :string, port: :integer]
  @preferred_cli_env [run: :dev]

  @impl Mix.Task
  def run(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, [workflow_path], []} ->
        start(Path.expand(workflow_path), opts)

      _ ->
        Mix.raise(
          "Usage: mix symphony.run [--logs-root <path>] [--port <port>] <path-to-workflow.md>"
        )
    end
  end

  defp start(workflow_path, opts) do
    unless File.regular?(workflow_path) do
      Mix.raise("Workflow file not found: #{workflow_path}")
    end

    # Publish the workflow path to runtime.exs via the OS env, then run
    # app.config so runtime.exs picks it up and populates Application env
    # (workflow_file_path + derived Web.Endpoint settings).
    System.put_env("SYMPHONY_WORKFLOW_FILE", workflow_path)
    Mix.Task.run("app.config")

    apply_logs_root(opts)
    apply_port_override(opts)

    case Application.ensure_all_started(:core) do
      {:ok, _started} ->
        wait_for_shutdown()

      {:error, reason} ->
        Mix.raise("Failed to start Symphony: #{inspect(reason)}")
    end
  end

  defp apply_logs_root(opts) do
    case Keyword.get(opts, :logs_root) do
      nil -> :ok
      "" -> Mix.raise("--logs-root must not be empty")
      value -> Application.put_env(:core, :log_file, LogFile.default_log_file(Path.expand(value)))
    end
  end

  defp apply_port_override(opts) do
    case Keyword.get(opts, :port) do
      nil -> :ok
      port when is_integer(port) and port >= 0 -> Application.put_env(:core, :server_port_override, port)
      _ -> Mix.raise("--port must be a non-negative integer")
    end
  end

  defp wait_for_shutdown do
    case Process.whereis(Core.Supervisor) do
      nil ->
        Mix.raise("Symphony supervisor is not running")

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, :normal} -> :ok
          {:DOWN, ^ref, :process, ^pid, reason} -> Mix.raise("Symphony exited: #{inspect(reason)}")
        end
    end
  end
end
