defmodule SymphonyElixir.Claude.Session do
  @moduledoc """
  Long-running client for the Claude Code stream-json subprocess.

  Replaces `SymphonyElixir.Codex.AppServer`. Symphony spawns one `claude`
  process per logical session and feeds it line-delimited JSON user messages
  on stdin, reading line-delimited JSON events from stdout until each
  `result` event arrives.

  Public API mirrors `Codex.AppServer` so callers (`AgentRunner`, tests)
  swap with minimal change in PRE-9.

  Events are emitted via the `:on_message` callback in a shape compatible
  with the orchestrator's `:codex_worker_update` handler:

      %{
        event: :session_started | :notification | :turn_completed |
               :turn_failed | :startup_failed,
        timestamp: DateTime.utc_now(),
        session_id: <uuid>,           # set once known
        payload: parsed_event_map,    # decoded JSON event from claude
        raw: raw_line,                # original stdout line
        usage: extracted_usage_or_nil,
        metadata...                   # port pid, worker_host, etc.
      }
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety, SSH}

  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000

  @type session :: %{
          port: port(),
          session_id: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          metadata: map(),
          turn_count: non_neg_integer()
        }

  @type on_message :: (map() -> any())

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, port} <- start_port(expanded_workspace, worker_host) do
      base_metadata = port_metadata(port, worker_host)

      case await_system_init(port) do
        {:ok, session_id} ->
          {:ok,
           %{
             port: port,
             session_id: session_id,
             workspace: expanded_workspace,
             worker_host: worker_host,
             metadata: Map.put(base_metadata, :session_id, session_id),
             turn_count: 0
           }}

        {:error, reason} ->
          stop_port(port)
          {:error, reason}
      end
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          session_id: session_id,
          metadata: metadata,
          turn_count: turn_count
        } = session,
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    turn_id = turn_count + 1

    Logger.info("Claude session started for #{issue_context(issue)} session_id=#{session_id} turn=#{turn_id}")

    emit_message(
      on_message,
      :session_started,
      %{
        session_id: session_id,
        turn_id: turn_id
      },
      metadata
    )

    case send_user_message(port, prompt) do
      :ok ->
        await_turn_completion(port, on_message, metadata, session_id, turn_id, issue)
        |> finalize_run_turn(session, on_message, session_id, turn_id, issue)

      {:error, reason} ->
        Logger.error("Claude session failed to send user message for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

        emit_message(on_message, :startup_failed, %{reason: reason, session_id: session_id}, metadata)
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
  end

  ## --- internal helpers --------------------------------------------------

  defp finalize_run_turn({:ok, result_payload}, session, _on_message, session_id, turn_id, issue) do
    Logger.info("Claude session completed for #{issue_context(issue)} session_id=#{session_id} turn=#{turn_id}")

    {:ok,
     %{
       result: result_payload,
       session_id: session_id,
       turn_id: turn_id,
       session: %{session | turn_count: turn_id}
     }}
  end

  defp finalize_run_turn({:error, reason}, _session, on_message, session_id, turn_id, issue) do
    Logger.warning("Claude session ended with error for #{issue_context(issue)} session_id=#{session_id} turn=#{turn_id}: #{inspect(reason)}")

    emit_message(
      on_message,
      :turn_ended_with_error,
      %{session_id: session_id, turn_id: turn_id, reason: reason},
      %{}
    )

    {:error, reason}
  end

  defp send_user_message(port, prompt) when is_binary(prompt) do
    payload = %{
      "type" => "user",
      "message" => %{
        "role" => "user",
        "content" => prompt
      }
    }

    line = Jason.encode!(payload) <> "\n"

    try do
      true = Port.command(port, line)
      :ok
    rescue
      ArgumentError -> {:error, :port_closed}
    end
  end

  defp await_system_init(port) do
    receive_event_loop(
      port,
      Config.settings!().claude.read_timeout_ms,
      "",
      &handle_init_event/2
    )
  end

  defp handle_init_event(
         %{"type" => "system", "subtype" => "init", "session_id" => session_id} = _payload,
         _raw
       )
       when is_binary(session_id) do
    {:ok, session_id}
  end

  defp handle_init_event(_payload, _raw), do: :continue

  defp await_turn_completion(port, on_message, metadata, session_id, turn_id, _issue) do
    timeout_ms = Config.settings!().claude.turn_timeout_ms

    receive_event_loop(
      port,
      timeout_ms,
      "",
      &handle_turn_event(&1, &2, on_message, metadata, session_id, turn_id)
    )
  end

  defp handle_turn_event(
         %{"type" => "result"} = payload,
         raw,
         on_message,
         metadata,
         session_id,
         turn_id
       ) do
    is_error = Map.get(payload, "is_error") == true

    event_metadata =
      metadata
      |> Map.put(:session_id, session_id)
      |> Map.put(:turn_id, turn_id)
      |> maybe_put_usage(payload)

    if is_error do
      emit_message(
        on_message,
        :turn_failed,
        %{
          payload: payload,
          raw: raw,
          details: payload
        },
        event_metadata
      )

      reason = result_error_reason(payload)
      {:error, {:turn_failed, reason}}
    else
      emit_message(
        on_message,
        :turn_completed,
        %{
          payload: payload,
          raw: raw,
          details: payload
        },
        event_metadata
      )

      {:ok, payload}
    end
  end

  defp handle_turn_event(payload, raw, on_message, metadata, session_id, turn_id) do
    event_metadata =
      metadata
      |> Map.put(:session_id, session_id)
      |> Map.put(:turn_id, turn_id)
      |> maybe_put_usage(payload)

    emit_message(
      on_message,
      :notification,
      %{
        payload: payload,
        raw: raw
      },
      event_metadata
    )

    :continue
  end

  ## --- generic event receive loop ----------------------------------------

  defp receive_event_loop(port, timeout_ms, pending_line, handler) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        process_line(port, timeout_ms, complete_line, handler)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_event_loop(port, timeout_ms, pending_line <> to_string(chunk), handler)

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp process_line(port, timeout_ms, line, handler) do
    case Jason.decode(line) do
      {:ok, payload} when is_map(payload) ->
        case handler.(payload, line) do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, reason}
          :continue -> receive_event_loop(port, timeout_ms, "", handler)
        end

      {:ok, _other} ->
        log_non_protocol_line(line, "non-map JSON")
        receive_event_loop(port, timeout_ms, "", handler)

      {:error, _reason} ->
        log_non_protocol_line(line, "non-JSON output")
        receive_event_loop(port, timeout_ms, "", handler)
    end
  end

  ## --- workspace + spawn -------------------------------------------------

  # Copied from `Codex.AppServer.validate_workspace_cwd/2`. AppServer is
  # scheduled for deletion in PRE-9; we duplicate rather than couple to it.
  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp start_port(workspace, nil) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(launch_command_string())],
            cd: String.to_charlist(workspace),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp start_port(workspace, worker_host) when is_binary(worker_host) do
    remote_command =
      [
        "cd #{shell_escape(workspace)}",
        "exec #{launch_command_string()}"
      ]
      |> Enum.join(" && ")

    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp launch_command_string do
    settings = Config.settings!().claude

    base = settings.command || "claude"

    fixed_args = [
      "--print",
      "--input-format",
      "stream-json",
      "--output-format",
      "stream-json",
      "--verbose",
      "--permission-mode",
      shell_escape(settings.permission_mode),
      "--model",
      shell_escape(settings.model)
    ]

    optional_args =
      []
      |> append_optional("--effort", settings.effort)
      |> append_optional("--mcp-config", settings.mcp_config_path)

    Enum.join([base | fixed_args ++ optional_args], " ")
  end

  defp append_optional(args, _flag, nil), do: args
  defp append_optional(args, _flag, ""), do: args

  defp append_optional(args, flag, value) when is_binary(value) do
    args ++ [flag, shell_escape(value)]
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{claude_session_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  ## --- emission + extraction --------------------------------------------

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message =
      metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp default_on_message(_message), do: :ok

  defp maybe_put_usage(metadata, payload) when is_map(payload) do
    case extract_usage(payload) do
      usage when is_map(usage) -> Map.put(metadata, :usage, usage)
      _ -> metadata
    end
  end

  defp maybe_put_usage(metadata, _payload), do: metadata

  # Claude Code emits `usage` at the top level of `result` events and nested
  # inside `message` for `assistant` events.
  defp extract_usage(%{"usage" => usage}) when is_map(usage), do: usage
  defp extract_usage(%{"message" => %{"usage" => usage}}) when is_map(usage), do: usage
  defp extract_usage(_), do: nil

  defp result_error_reason(%{"result" => result}) when is_binary(result), do: result
  defp result_error_reason(%{"subtype" => subtype}) when is_binary(subtype), do: subtype
  defp result_error_reason(payload), do: payload

  defp log_non_protocol_line(data, label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Claude #{label}: #{text}")
      else
        Logger.debug("Claude #{label}: #{text}")
      end
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp shell_escape(value) when is_atom(value), do: shell_escape(Atom.to_string(value))

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp issue_context(_), do: "issue_id=unknown issue_identifier=unknown"
end
