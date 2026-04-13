defmodule SymphonyElixir.Telemetry.Writer do
  @moduledoc """
  Async writer for the telemetry sink. Receives agent updates via `record/3`
  (cast), filters to meaningful events, and inserts rows into the
  `agent_events` table via `SymphonyElixir.Telemetry.Repo`.

  Failures inserting a single row are logged and skipped — telemetry is
  best-effort and must never block or crash the orchestrator.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.Claude.Usage
  alias SymphonyElixir.Telemetry.AgentEvent
  alias SymphonyElixir.Telemetry.Repo

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec record(String.t(), String.t() | nil, map()) :: :ok
  def record(issue_id, issue_identifier, update) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.cast(pid, {:record, issue_id, issue_identifier, update})

      _ ->
        :ok
    end
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{}}
  end

  @impl GenServer
  def handle_cast({:record, issue_id, issue_identifier, update}, state) do
    case build_attrs(issue_id, issue_identifier, update) do
      {:ok, attrs} ->
        insert(attrs)

      :skip ->
        :ok
    end

    {:noreply, state}
  end

  defp insert(attrs) do
    %AgentEvent{}
    |> AgentEvent.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, _event} ->
        :ok

      {:error, changeset} ->
        Logger.warning("telemetry insert failed: #{inspect(changeset.errors)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("telemetry insert raised: #{Exception.message(error)}")
      :ok
  end

  defp build_attrs(issue_id, issue_identifier, %{event: :turn_completed} = update) do
    payload = Map.get(update, :payload, %{})

    {:ok,
     base_attrs(issue_id, issue_identifier, update, "turn_completed")
     |> Map.merge(usage_attrs(Usage.extract_usage(update)))
     |> Map.put(:cost_usd, Usage.extract_cost_usd(update))
     |> Map.put(:raw_payload, encode_raw(payload))}
  end

  defp build_attrs(issue_id, issue_identifier, %{event: :notification, payload: payload} = update)
       when is_map(payload) do
    case Map.get(payload, "type") do
      "rate_limit_event" ->
        rate_info = Map.get(payload, "rate_limit_info") || %{}

        {:ok,
         base_attrs(issue_id, issue_identifier, update, "rate_limit_event")
         |> Map.merge(rate_limit_attrs(rate_info))
         |> Map.put(:raw_payload, encode_raw(payload))}

      _ ->
        :skip
    end
  end

  defp build_attrs(_issue_id, _issue_identifier, _update), do: :skip

  defp base_attrs(issue_id, issue_identifier, update, event_type) do
    %{
      timestamp: Map.get(update, :timestamp) || DateTime.utc_now(),
      session_id: Map.get(update, :session_id),
      issue_id: issue_id,
      issue_identifier: issue_identifier,
      turn_id: Map.get(update, :turn_id),
      event_type: event_type
    }
  end

  defp usage_attrs(usage) when is_map(usage) do
    %{
      input_tokens: integer_value(usage, "input_tokens"),
      output_tokens: integer_value(usage, "output_tokens"),
      cache_creation_input_tokens: integer_value(usage, "cache_creation_input_tokens"),
      cache_read_input_tokens: integer_value(usage, "cache_read_input_tokens")
    }
  end

  defp rate_limit_attrs(info) when is_map(info) do
    %{
      rate_limit_status: string_value(info, "status"),
      rate_limit_type: string_value(info, "rateLimitType"),
      resets_at: parse_resets_at(Map.get(info, "resetsAt")),
      is_using_overage: Map.get(info, "isUsingOverage")
    }
  end

  defp integer_value(map, key) do
    case Map.get(map, key) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  defp string_value(map, key) do
    case Map.get(map, key) do
      s when is_binary(s) -> s
      _ -> nil
    end
  end

  defp parse_resets_at(n) when is_integer(n) do
    case DateTime.from_unix(n) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp parse_resets_at(_), do: nil

  defp encode_raw(payload) do
    case Jason.encode(payload) do
      {:ok, json} -> json
      _ -> nil
    end
  end
end
