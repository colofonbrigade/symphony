defmodule Core.Tracker do
  @moduledoc """
  Dispatches tracker reads and writes to the configured adapter, threading
  tracker settings (api_key, endpoint, project_slug, active_states,
  assignee) in on every call.

  The adapter contract lives in `Linear.Tracker`; `Linear.Adapter` is the
  production implementer wired in by `config/config.exs`. `config/test.exs`
  overrides the adapter to `Test.Tracker.Memory` so tests don't hit the real
  Linear backend.
  """

  alias Core.Config

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: adapter().fetch_candidate_issues(settings())

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: adapter().fetch_issues_by_states(settings(), states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids),
    do: adapter().fetch_issue_states_by_ids(settings(), issue_ids)

  @spec adapter() :: module()
  def adapter do
    Application.fetch_env!(:core, __MODULE__)[:adapter]
  end

  defp settings do
    tracker = Config.settings!().tracker

    %{
      api_key: tracker.api_key,
      endpoint: tracker.endpoint,
      project_slug: tracker.project_slug,
      active_states: tracker.active_states,
      assignee: tracker.assignee
    }
  end
end
