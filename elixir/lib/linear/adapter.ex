defmodule Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter. Read-only today (fetch candidate issues,
  fetch state for tracked issues); write-side tracker operations were removed
  when Claude Code started owning Linear interactions via MCP.
  """

  @behaviour Linear.Tracker

  alias Linear.Client

  @impl Linear.Tracker
  def fetch_candidate_issues(settings), do: client_module().fetch_candidate_issues(settings)

  @impl Linear.Tracker
  def fetch_issues_by_states(settings, states),
    do: client_module().fetch_issues_by_states(settings, states)

  @impl Linear.Tracker
  def fetch_issue_states_by_ids(settings, issue_ids),
    do: client_module().fetch_issue_states_by_ids(settings, issue_ids)

  defp client_module do
    Application.get_env(:core, :linear_client_module, Client)
  end
end
