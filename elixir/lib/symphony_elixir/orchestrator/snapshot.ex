defmodule SymphonyElixir.Orchestrator.Snapshot do
  @moduledoc """
  Pure projection of orchestrator state into the read-only snapshot map that
  the status dashboard, LiveView dashboard, and HTTP observability API
  consume via `SymphonyElixirWeb.Presenter`.

  The orchestrator's `handle_call(:snapshot, ...)` calls `build/3` after
  refreshing its runtime config; everything else in this module is a pure
  function over state.
  """

  @type snapshot :: %{
          running: [map()],
          retrying: [map()],
          agent_totals: map(),
          polling: %{
            checking?: boolean(),
            next_poll_in_ms: non_neg_integer() | nil,
            poll_interval_ms: pos_integer()
          }
        }

  @spec build(map(), DateTime.t(), integer()) :: snapshot()
  def build(state, %DateTime{} = now, now_ms) when is_integer(now_ms) do
    %{
      running: Enum.map(state.running, &project_running(&1, now)),
      retrying: Enum.map(state.retry_attempts, &project_retrying(&1, now_ms)),
      agent_totals: state.agent_totals,
      polling: %{
        checking?: state.poll_check_in_progress == true,
        next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
        poll_interval_ms: state.poll_interval_ms
      }
    }
  end

  defp project_running({issue_id, metadata}, now) do
    %{
      issue_id: issue_id,
      identifier: metadata.identifier,
      state: metadata.issue.state,
      worker_host: Map.get(metadata, :worker_host),
      workspace_path: Map.get(metadata, :workspace_path),
      session_id: metadata.session_id,
      agent_pid: metadata.agent_pid,
      agent_input_tokens: metadata.agent_input_tokens,
      agent_output_tokens: metadata.agent_output_tokens,
      agent_total_tokens: metadata.agent_total_tokens,
      agent_cost_usd: metadata.agent_cost_usd,
      turn_count: Map.get(metadata, :turn_count, 0),
      started_at: metadata.started_at,
      last_agent_timestamp: metadata.last_agent_timestamp,
      last_agent_message: metadata.last_agent_message,
      last_agent_event: metadata.last_agent_event,
      rate_limit_info: Map.get(metadata, :rate_limit_info),
      runtime_seconds: running_seconds(metadata.started_at, now)
    }
  end

  defp project_retrying({issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry}, now_ms) do
    %{
      issue_id: issue_id,
      attempt: attempt,
      due_in_ms: max(0, due_at_ms - now_ms),
      identifier: Map.get(retry, :identifier),
      error: Map.get(retry, :error),
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0
end
