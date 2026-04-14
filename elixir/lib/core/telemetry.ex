defmodule Core.Telemetry do
  @moduledoc """
  Public interface for the telemetry sink. Orchestrator forwards agent updates
  here via `record/3`; the Writer GenServer persists meaningful ones asynchronously.

  Meaningful events are:

  * `:turn_completed` — carries the final `usage` + `total_cost_usd` for a turn
  * `:notification` where `payload["type"] == "rate_limit_event"` — carries
    Claude Code's `rate_limit_info` snapshot

  Other events are dropped at the writer to keep the table focused on data that
  is useful for quota/usage analysis across process restarts.
  """

  alias Core.Telemetry.Writer

  @spec record(String.t(), String.t() | nil, map()) :: :ok
  def record(issue_id, issue_identifier, update) when is_binary(issue_id) and is_map(update) do
    if enabled?() do
      Writer.record(issue_id, issue_identifier, update)
    end

    :ok
  end

  @spec enabled?() :: boolean()
  def enabled? do
    case Core.Config.settings() do
      {:ok, %{observability: %{telemetry_enabled: enabled}}} -> enabled == true
      _ -> false
    end
  end
end
