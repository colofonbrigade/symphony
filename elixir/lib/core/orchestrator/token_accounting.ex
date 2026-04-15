defmodule Core.Orchestrator.TokenAccounting do
  @moduledoc """
  Pure helpers for integrating an `agent_worker_update` into a running entry's
  token/cost/session metadata, and for applying the resulting deltas to the
  orchestrator's aggregate `agent_totals`.

  No GenServer state mutation — every function takes the current running entry
  or state map and returns an updated one.
  """

  alias Claude.Usage

  @empty_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0,
    cost_usd: 0.0
  }

  @type token_delta :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer(),
          input_reported: non_neg_integer(),
          output_reported: non_neg_integer(),
          total_reported: non_neg_integer()
        }

  @doc "Starting value for the orchestrator's `agent_totals` aggregate."
  @spec empty_totals() :: map()
  def empty_totals, do: @empty_totals

  @doc """
  Merge an agent update into a running entry. Returns `{updated_entry,
  token_delta, cost_delta}`; the orchestrator then applies those deltas to
  the state-level aggregate via `apply_agent_token_delta/2` and
  `apply_agent_cost_delta/2`.
  """
  @spec integrate_update(map(), map()) :: {map(), token_delta(), number()}
  def integrate_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    cost_delta = extract_cost_delta(update)
    agent_input_tokens = Map.get(running_entry, :agent_input_tokens, 0)
    agent_output_tokens = Map.get(running_entry, :agent_output_tokens, 0)
    agent_total_tokens = Map.get(running_entry, :agent_total_tokens, 0)
    agent_cost_usd = Map.get(running_entry, :agent_cost_usd, 0.0)
    agent_pid = Map.get(running_entry, :agent_pid)
    last_reported_input = Map.get(running_entry, :agent_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :agent_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :agent_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        last_agent_timestamp: timestamp,
        last_agent_message: summarize_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_agent_event: event,
        agent_pid: agent_pid_for_update(agent_pid, update),
        agent_input_tokens: agent_input_tokens + token_delta.input_tokens,
        agent_output_tokens: agent_output_tokens + token_delta.output_tokens,
        agent_total_tokens: agent_total_tokens + token_delta.total_tokens,
        agent_cost_usd: agent_cost_usd + cost_delta,
        agent_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        agent_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        agent_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update),
        rate_limit_info:
          extract_rate_limit_info(update) || Map.get(running_entry, :rate_limit_info)
      }),
      token_delta,
      cost_delta
    }
  end

  @doc "Add token counts from `token_delta` to the state-level aggregate."
  @spec apply_agent_token_delta(map(), token_delta()) :: map()
  def apply_agent_token_delta(
        %{agent_totals: agent_totals} = state,
        %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
      )
      when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | agent_totals: apply_token_delta(agent_totals, token_delta)}
  end

  def apply_agent_token_delta(state, _token_delta), do: state

  @doc "Add a positive cost delta to the state-level aggregate."
  @spec apply_agent_cost_delta(map(), number()) :: map()
  def apply_agent_cost_delta(%{agent_totals: agent_totals} = state, cost_delta)
      when is_number(cost_delta) and cost_delta > 0 do
    current_cost = Map.get(agent_totals, :cost_usd, 0.0)
    %{state | agent_totals: Map.put(agent_totals, :cost_usd, current_cost + cost_delta)}
  end

  def apply_agent_cost_delta(state, _cost_delta), do: state

  @doc "Merge a token_delta (possibly with `:seconds_running`) into a totals map."
  @spec apply_token_delta(map(), map()) :: map()
  def apply_token_delta(agent_totals, token_delta) do
    input_tokens = Map.get(agent_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(agent_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(agent_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(agent_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running),
      cost_usd: Map.get(agent_totals, :cost_usd, 0.0)
    }
  end

  defp extract_rate_limit_info(%{
         event: :notification,
         payload: %{"type" => "rate_limit_event"} = payload
       }) do
    case Map.get(payload, "rate_limit_info") do
      %{} = info -> info
      _ -> nil
    end
  end

  defp extract_rate_limit_info(_update), do: nil

  defp agent_pid_for_update(_existing, %{claude_session_pid: pid}) when is_binary(pid), do: pid

  defp agent_pid_for_update(_existing, %{claude_session_pid: pid}) when is_integer(pid),
    do: Integer.to_string(pid)

  defp agent_pid_for_update(_existing, %{claude_session_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp agent_pid_for_update(_existing, %{agent_pid: pid}) when is_binary(pid), do: pid
  defp agent_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = Usage.extract_usage(update)

    input = compute_token_delta(running_entry, :input, usage, :agent_last_reported_input_tokens)
    output = compute_token_delta(running_entry, :output, usage, :agent_last_reported_output_tokens)
    total = compute_token_delta(running_entry, :total, usage, :agent_last_reported_total_tokens)

    %{
      input_tokens: input.delta,
      output_tokens: output.delta,
      total_tokens: total.delta,
      input_reported: input.reported,
      output_reported: output.reported,
      total_reported: total.reported
    }
  end

  defp extract_cost_delta(%{event: _, timestamp: _} = update) do
    case Usage.extract_cost_usd(update) do
      cost when cost > 0 -> cost
      _ -> 0.0
    end
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)
    delta = max(next_total - prev_reported, 0)
    %{delta: delta, reported: next_total}
  end

  # Claude Code's `usage` shape always uses string keys with integer values
  # (see `Claude.Session.extract_usage/1`). Cache breakdown fields exist but
  # are intentionally not rolled into the running totals here.
  defp get_token_usage(usage, :input), do: read_token_count(usage, "input_tokens")
  defp get_token_usage(usage, :output), do: read_token_count(usage, "output_tokens")

  defp get_token_usage(usage, :total) do
    # Claude Code's usage block doesn't include `total_tokens`. Compute from
    # input + output so the running total is still meaningful.
    get_token_usage(usage, :input) + get_token_usage(usage, :output)
  end

  defp read_token_count(usage, key) when is_map(usage) do
    case Map.get(usage, key) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end
end
