defmodule Claude.Session do
  @moduledoc """
  Long-running client for the Claude Code stream-json subprocess.

  Symphony spawns one `claude` process per logical session and feeds it
  line-delimited JSON user messages on stdin, reading line-delimited JSON
  events from stdout until each `result` event arrives.

  Events are emitted via the `:on_message` callback in a shape compatible
  with the orchestrator's `:agent_worker_update` handler:

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
  alias Permissions.PathSafety
  alias Transport.SSH

  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000

  @type claude_settings :: %{
          optional(:command) => String.t() | nil,
          optional(:permission_mode) => String.t(),
          optional(:model) => String.t(),
          optional(:effort) => String.t() | nil,
          optional(:mcp_config_path) => String.t() | nil,
          required(:turn_timeout_ms) => non_neg_integer()
        }

  @type session :: %{
          port: port(),
          session_id: String.t() | nil,
          workspace: Path.t(),
          worker_host: String.t() | nil,
          claude: claude_settings(),
          metadata: map(),
          turn_count: non_neg_integer()
        }

  @type on_message :: (map() -> any())

  @doc """
  Start a Claude Code session in the given workspace.

  `opts` must include:
    * `:claude` — a `claude_settings()` map (command, permission_mode, model,
      effort, mcp_config_path, turn_timeout_ms).

  `opts` may include:
    * `:worker_host` — SSH host for remote sessions. Default: nil (local).
    * `:workspace_root` — required for local sessions. Used to validate the
      workspace path stays under the configured root. Ignored when
      `:worker_host` is set (remote paths are validated separately).
  """
  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    claude = Keyword.fetch!(opts, :claude)
    workspace_root = Keyword.get(opts, :workspace_root)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host, workspace_root),
         {:ok, port} <- start_port(expanded_workspace, worker_host, claude) do
      base_metadata = port_metadata(port, worker_host)

      # NOTE: Claude Code's `--print --input-format stream-json` mode does not
      # emit any events on stdout until it receives the first user message on
      # stdin. We used to wait for a `system` init event here, which deadlocked
      # forever (well, until read_timeout_ms). The session_id is captured
      # lazily by `run_turn/4` from the first system init event that arrives
      # in the receive loop after the first user message is written.
      {:ok,
       %{
         port: port,
         session_id: nil,
         workspace: expanded_workspace,
         worker_host: worker_host,
         claude: claude,
         metadata: base_metadata,
         turn_count: 0
       }}
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          session_id: existing_session_id,
          claude: %{turn_timeout_ms: turn_timeout_ms},
          metadata: metadata,
          turn_count: turn_count
        } = session,
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    turn_id = turn_count + 1

    case send_user_message(port, prompt) do
      :ok ->
        initial_state = %{
          session_id: existing_session_id,
          session_started_emitted?: false
        }

        port
        |> await_turn_completion(on_message, metadata, initial_state, turn_id, issue, turn_timeout_ms)
        |> finalize_run_turn(session, on_message, turn_id, issue)

      {:error, reason} ->
        Logger.error("Claude session failed to send user message for #{issue_context(issue)} session_id=#{existing_session_id || "n/a"}: #{inspect(reason)}")

        emit_message(
          on_message,
          :startup_failed,
          %{reason: reason, session_id: existing_session_id},
          metadata
        )

        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
  end

  ## --- internal helpers --------------------------------------------------

  defp finalize_run_turn({:ok, result_payload, final_state}, session, _on_message, turn_id, issue) do
    session_id = final_state.session_id

    Logger.info("Claude session completed for #{issue_context(issue)} session_id=#{session_id || "n/a"} turn=#{turn_id}")

    updated_session = %{
      session
      | turn_count: turn_id,
        session_id: session_id,
        metadata: maybe_update_session_metadata(session.metadata, session_id)
    }

    {:ok,
     %{
       result: result_payload,
       session_id: session_id,
       turn_id: turn_id,
       session: updated_session
     }}
  end

  defp finalize_run_turn({:error, reason, final_state}, session, on_message, turn_id, issue) do
    session_id = final_state.session_id

    Logger.warning("Claude session ended with error for #{issue_context(issue)} session_id=#{session_id || "n/a"} turn=#{turn_id}: #{inspect(reason)}")

    emit_message(
      on_message,
      :turn_ended_with_error,
      %{session_id: session_id, turn_id: turn_id, reason: reason},
      %{}
    )

    # Even on error, advance turn_count and capture any session_id we learned
    # so a follow-up retry doesn't start from a stale state.
    _updated_session = %{
      session
      | turn_count: turn_id,
        session_id: session_id,
        metadata: maybe_update_session_metadata(session.metadata, session_id)
    }

    {:error, reason}
  end

  defp maybe_update_session_metadata(metadata, nil), do: metadata
  defp maybe_update_session_metadata(metadata, session_id), do: Map.put(metadata, :session_id, session_id)

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

  defp await_turn_completion(port, on_message, metadata, initial_state, turn_id, _issue, timeout_ms) do
    receive_event_loop(
      port,
      timeout_ms,
      "",
      initial_state,
      &handle_turn_event(&1, &2, &3, on_message, metadata, turn_id)
    )
  end

  # Result event — terminal. Returns {:ok, payload, state} on success or
  # {:error, reason, state} on a Claude-side error.
  defp handle_turn_event(
         %{"type" => "result"} = payload,
         raw,
         state,
         on_message,
         metadata,
         turn_id
       ) do
    is_error = Map.get(payload, "is_error") == true
    state = update_session_id(state, payload)

    event_metadata =
      metadata
      |> put_session_id(state.session_id)
      |> Map.put(:turn_id, turn_id)
      |> maybe_put_usage(payload)

    if is_error do
      emit_message(
        on_message,
        :turn_failed,
        %{payload: payload, raw: raw, details: payload},
        event_metadata
      )

      {:error, {:turn_failed, result_error_reason(payload)}, state}
    else
      emit_message(
        on_message,
        :turn_completed,
        %{payload: payload, raw: raw, details: payload},
        event_metadata
      )

      {:ok, payload, state}
    end
  end

  # System init event — captures session_id (lazily, only once per session)
  # and emits the :session_started boundary event before the receive loop
  # continues into the assistant/result events.
  defp handle_turn_event(
         %{"type" => "system", "subtype" => "init"} = payload,
         raw,
         state,
         on_message,
         metadata,
         turn_id
       ) do
    state = update_session_id(state, payload)

    state =
      if state.session_id && not state.session_started_emitted? do
        emit_message(
          on_message,
          :session_started,
          %{session_id: state.session_id, turn_id: turn_id},
          put_session_id(metadata, state.session_id)
        )

        %{state | session_started_emitted?: true}
      else
        state
      end

    event_metadata =
      metadata
      |> put_session_id(state.session_id)
      |> Map.put(:turn_id, turn_id)
      |> maybe_put_usage(payload)

    emit_message(
      on_message,
      :notification,
      %{payload: payload, raw: raw},
      event_metadata
    )

    {:continue, state}
  end

  # Generic notification (assistant/user/rate_limit_event/etc.).
  defp handle_turn_event(payload, raw, state, on_message, metadata, turn_id) do
    state = update_session_id(state, payload)

    event_metadata =
      metadata
      |> put_session_id(state.session_id)
      |> Map.put(:turn_id, turn_id)
      |> maybe_put_usage(payload)

    emit_message(
      on_message,
      :notification,
      %{payload: payload, raw: raw},
      event_metadata
    )

    {:continue, state}
  end

  defp update_session_id(state, %{"session_id" => session_id}) when is_binary(session_id) do
    %{state | session_id: session_id}
  end

  defp update_session_id(state, _payload), do: state

  defp put_session_id(metadata, nil), do: metadata
  defp put_session_id(metadata, session_id), do: Map.put(metadata, :session_id, session_id)

  ## --- generic event receive loop ----------------------------------------

  # Threads `state` through the receive loop. The handler receives
  # `(payload, raw, state)` and returns one of:
  #   {:continue, new_state}      — more events expected
  #   {:ok, result, new_state}    — terminal success
  #   {:error, reason, new_state} — terminal error
  #
  # Terminal results carry the final state so callers can capture data
  # accumulated during the receive loop (e.g. session_id from a `system`
  # init event).
  defp receive_event_loop(port, timeout_ms, pending_line, state, handler) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        process_line(port, timeout_ms, complete_line, state, handler)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_event_loop(port, timeout_ms, pending_line <> to_string(chunk), state, handler)

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}, state}
    after
      timeout_ms ->
        {:error, :turn_timeout, state}
    end
  end

  defp process_line(port, timeout_ms, line, state, handler) do
    case Jason.decode(line) do
      {:ok, payload} when is_map(payload) ->
        case handler.(payload, line, state) do
          {:ok, result, new_state} -> {:ok, result, new_state}
          {:error, reason, new_state} -> {:error, reason, new_state}
          {:continue, new_state} -> receive_event_loop(port, timeout_ms, "", new_state, handler)
        end

      {:ok, _other} ->
        log_non_protocol_line(line, "non-map JSON")
        receive_event_loop(port, timeout_ms, "", state, handler)

      {:error, _reason} ->
        log_non_protocol_line(line, "non-JSON output")
        receive_event_loop(port, timeout_ms, "", state, handler)
    end
  end

  ## --- workspace + spawn -------------------------------------------------

  defp validate_workspace_cwd(workspace, nil, workspace_root)
       when is_binary(workspace) and is_binary(workspace_root) do
    case PathSafety.validate_workspace_in_root(workspace, workspace_root) do
      {:ok, canonical_workspace} ->
        {:ok, canonical_workspace}

      {:error, {:workspace_equals_root, canonical_workspace, _canonical_root}} ->
        {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

      {:error, {:symlink_escape, expanded_workspace, canonical_root}} ->
        {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

      {:error, {:outside_root, canonical_workspace, canonical_root}} ->
        {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}

      {:error, {:path_unreadable, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host, _workspace_root)
       when is_binary(workspace) and is_binary(worker_host) do
    case PathSafety.validate_remote_workspace(workspace) do
      :ok ->
        {:ok, workspace}

      {:error, :empty} ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      {:error, :invalid_characters} ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}
    end
  end

  defp start_port(workspace, nil, claude) do
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
            args: [~c"-lc", String.to_charlist(launch_command_string(claude))],
            cd: String.to_charlist(workspace),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp start_port(workspace, worker_host, claude) when is_binary(worker_host) do
    remote_command =
      [
        "cd #{shell_escape(workspace)}",
        "exec #{launch_command_string(claude)}"
      ]
      |> Enum.join(" && ")

    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp launch_command_string(settings) do
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
