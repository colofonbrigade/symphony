defmodule CLI.StatusDashboard.AgentMessage do
  @moduledoc """
  Pure payload → prose transformations for the status dashboard. Maps
  Claude Code stream-json events (`type` of `system`, `assistant`, `user`,
  `result`, `rate_limit_event`) and Symphony's own `:event` tags
  (`:session_started`, `:turn_completed`, `:turn_failed`, etc.) into the
  short human-readable strings shown in the running-session rows.
  """

  @doc """
  Render an agent event message into a short human-readable string for the
  dashboard. Accepts the `last_agent_message` shape stored on running entries
  by the orchestrator (`%{event: atom, message: payload, timestamp: dt}`),
  the bare wrapped form (`%{message: payload}`), or a raw payload map.
  """
  @spec humanize_agent_message(term()) :: String.t()
  def humanize_agent_message(nil), do: "no agent activity yet"

  def humanize_agent_message(%{event: event, message: message}) do
    payload = unwrap_agent_payload(message)

    (humanize_agent_event(event, payload) || humanize_agent_payload(payload))
    |> truncate(140)
  end

  def humanize_agent_message(%{message: message}) do
    message
    |> unwrap_agent_payload()
    |> humanize_agent_payload()
    |> truncate(140)
  end

  def humanize_agent_message(message) do
    message
    |> unwrap_agent_payload()
    |> humanize_agent_payload()
    |> truncate(140)
  end

  ## Event-level dispatch — matches the on_message :event tag emitted by
  ## Claude.Session (:session_started, :notification, :turn_completed,
  ## :turn_failed, :turn_ended_with_error, :startup_failed). Returns nil
  ## for events that should fall through to payload-level dispatch.

  defp humanize_agent_event(:session_started, payload) do
    case map_value(payload, ["session_id", :session_id]) do
      sid when is_binary(sid) -> "session started (#{short_session(sid)})"
      _ -> "session started"
    end
  end

  defp humanize_agent_event(:turn_completed, payload), do: summarize_result_payload(payload)

  defp humanize_agent_event(:turn_failed, payload),
    do: "turn failed: #{format_reason(payload)}"

  defp humanize_agent_event(:turn_ended_with_error, payload),
    do: "turn ended with error: #{format_reason(payload)}"

  defp humanize_agent_event(:startup_failed, payload),
    do: "startup failed: #{format_reason(payload)}"

  defp humanize_agent_event(_event, _payload), do: nil

  ## Payload-level dispatch — matches Claude Code's stream-json `type` field.

  defp humanize_agent_payload(%{} = payload) do
    case map_value(payload, ["type", :type]) do
      "system" -> humanize_system_payload(payload)
      "assistant" -> humanize_assistant_payload(payload)
      "user" -> humanize_user_payload(payload)
      "result" -> summarize_result_payload(payload)
      "rate_limit_event" -> humanize_rate_limit_payload(payload)
      type when is_binary(type) -> "agent event: #{type}"
      _ -> "agent event"
    end
  end

  defp humanize_agent_payload(payload) when is_binary(payload), do: inline_text(payload)
  defp humanize_agent_payload(payload), do: payload |> inspect(limit: 6) |> inline_text()

  defp humanize_system_payload(payload) do
    case map_value(payload, ["subtype", :subtype]) do
      "init" -> "session ready"
      sub when is_binary(sub) -> "system: #{sub}"
      _ -> "system event"
    end
  end

  defp humanize_assistant_payload(payload) do
    case assistant_first_content(payload) do
      %{"type" => "text", "text" => text} when is_binary(text) ->
        "assistant: #{inline_text(text)}"

      %{"type" => "thinking"} ->
        "thinking…"

      %{"type" => "tool_use", "name" => name} when is_binary(name) ->
        "tool: #{name}"

      %{"type" => type} when is_binary(type) ->
        "assistant: <#{type}>"

      _ ->
        "assistant"
    end
  end

  defp assistant_first_content(payload) do
    with message when is_map(message) <- map_value(payload, ["message", :message]),
         content when is_list(content) <- map_value(message, ["content", :content]),
         [first | _] <- content,
         true <- is_map(first) do
      first
    else
      _ -> nil
    end
  end

  defp humanize_user_payload(payload) do
    case assistant_first_content(payload) do
      %{"type" => "tool_result"} -> "tool result"
      %{"type" => type} when is_binary(type) -> "user: <#{type}>"
      _ -> "user"
    end
  end

  defp summarize_result_payload(payload) do
    if result_error?(payload) do
      "result error: #{format_reason(payload)}"
    else
      "turn completed#{result_usage_part(payload)}#{result_cost_part(payload)}"
    end
  end

  defp result_error?(payload) do
    Map.get(payload, "is_error") == true or Map.get(payload, :is_error) == true
  end

  defp result_usage_part(payload) do
    with %{} = usage <- map_value(payload, ["usage", :usage]),
         summary when summary != "" <- format_usage_summary(usage) do
      " " <> summary
    else
      _ -> ""
    end
  end

  defp result_cost_part(payload) do
    case map_value(payload, ["total_cost_usd", :total_cost_usd]) do
      cost when is_number(cost) and cost > 0 -> " $#{format_cost(cost)}"
      _ -> ""
    end
  end

  defp humanize_rate_limit_payload(payload) do
    case map_value(payload, ["rate_limit_info", :rate_limit_info]) do
      %{} = info ->
        case map_value(info, ["status", :status]) do
          status when is_binary(status) -> "rate limit: #{status}"
          _ -> "rate limit event"
        end

      _ ->
        "rate limit event"
    end
  end

  defp format_usage_summary(usage) do
    input = map_value(usage, ["input_tokens", :input_tokens])
    output = map_value(usage, ["output_tokens", :output_tokens])

    parts =
      []
      |> append_if_int("in", input)
      |> append_if_int("out", output)

    if parts == [], do: "", else: "(" <> Enum.join(parts, " ") <> ")"
  end

  defp append_if_int(parts, _label, value) when not is_integer(value), do: parts
  defp append_if_int(parts, label, value), do: parts ++ ["#{label} #{format_int(value)}"]

  defp format_cost(value) when is_number(value) do
    :erlang.float_to_binary(value * 1.0, decimals: 4)
  end

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp short_session(sid) when is_binary(sid) do
    case String.split(sid, "-", parts: 2) do
      [head | _] -> head
      _ -> String.slice(sid, 0, 8)
    end
  end

  defp unwrap_agent_payload(%{} = message) do
    case map_value(message, ["payload", :payload]) do
      %{} = payload -> payload
      _ -> message
    end
  end

  defp unwrap_agent_payload(message), do: message

  defp format_reason(message) when is_map(message) do
    case map_value(message, ["reason", :reason]) do
      nil -> message |> inspect(limit: 10) |> inline_text()
      reason -> format_error_value(reason)
    end
  end

  defp format_reason(other), do: format_error_value(other)

  defp format_error_value(%{"message" => message}) when is_binary(message), do: message
  defp format_error_value(%{message: message}) when is_binary(message), do: message
  defp format_error_value(error), do: error |> inspect(limit: 10) |> inline_text()

  defp inline_text(text) when is_binary(text) do
    text
    |> sanitize_terminal_output()
    |> String.replace("\n", " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # Strips ANSI escape sequences (CSI / OSC) and control bytes from agent
  # output. Real `claude` sessions emit colorized output via tools like
  # `ls --color` and `git diff` that would otherwise corrupt the dashboard
  # row rendering.
  defp sanitize_terminal_output(text) when is_binary(text) do
    text
    |> String.replace(~r/\e\[[0-9;?]*[ -\/]*[@-~]/, "")
    |> String.replace(~r/\e\][^\a]*(\a|\e\\)/, "")
    |> String.replace(~r/[\x00-\x08\x0B-\x1F\x7F]/, "")
  end

  defp map_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp map_value(_map, _keys), do: nil

  defp truncate(value, max) when byte_size(value) > max do
    value |> String.slice(0, max) |> Kernel.<>("...")
  end

  defp truncate(value, _max), do: value
end
