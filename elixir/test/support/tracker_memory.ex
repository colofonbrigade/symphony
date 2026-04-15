defmodule Test.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests. Implements `Linear.Tracker` via
  Application env-driven issue data so tests can exercise `Core.Tracker`
  dispatch without hitting a real Linear backend.

  The `settings` argument on each callback is ignored — Memory reads its
  issue list from `:memory_tracker_issues` in Application env.
  """

  use Boundary, deps: [Linear, Schema]
  @behaviour Linear.Tracker

  alias Schema.Tracker.Issue

  @impl Linear.Tracker
  def fetch_candidate_issues(_settings) do
    {:ok, issue_entries()}
  end

  @impl Linear.Tracker
  def fetch_issues_by_states(_settings, state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{state: state} ->
       MapSet.member?(normalized_states, normalize_state(state))
     end)}
  end

  @impl Linear.Tracker
  def fetch_issue_states_by_ids(_settings, issue_ids) do
    wanted_ids = MapSet.new(issue_ids)

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{id: id} ->
       MapSet.member?(wanted_ids, id)
     end)}
  end

  defp configured_issues do
    Application.get_env(:core, :memory_tracker_issues, [])
  end

  defp issue_entries do
    Enum.filter(configured_issues(), &match?(%Issue{}, &1))
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
