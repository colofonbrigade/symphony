defmodule Core.Tracker do
  @moduledoc """
  Dispatches tracker reads and writes to the configured adapter.

  The adapter contract lives in `Linear.Tracker`; `Linear.Adapter` is the
  production implementer wired in by `config/config.exs`. `config/test.exs`
  overrides the adapter to `Test.Tracker.Memory` so tests don't hit the real
  Linear backend.
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: adapter().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: adapter().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: adapter().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body), do: adapter().create_comment(issue_id, body)

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name),
    do: adapter().update_issue_state(issue_id, state_name)

  @spec adapter() :: module()
  def adapter do
    Application.fetch_env!(:core, __MODULE__)[:adapter]
  end
end
