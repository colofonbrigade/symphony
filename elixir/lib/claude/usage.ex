defmodule Claude.Usage do
  @moduledoc """
  Pure helpers for extracting usage and cost from Claude Code stream-json
  event payloads. `Claude.Session` already lifts the canonical `usage` map
  onto each update via its `:usage` key; this module exposes that map plus
  the top-level `total_cost_usd` field from `result` events.
  """

  @spec extract_usage(map()) :: map()
  def extract_usage(%{usage: %{} = usage}), do: usage
  def extract_usage(_update), do: %{}

  @spec extract_cost_usd(map()) :: float()
  def extract_cost_usd(%{payload: %{"total_cost_usd" => cost}}) when is_number(cost), do: cost * 1.0
  def extract_cost_usd(_update), do: 0.0
end
