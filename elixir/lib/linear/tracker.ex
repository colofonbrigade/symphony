defmodule Linear.Tracker do
  @moduledoc """
  Behaviour implemented by Linear-shaped tracker adapters. `Linear.Adapter` is
  the production implementer. Test doubles (see `test/support/tracker_memory.ex`)
  implement the same callbacks so `Core.Tracker` can dispatch to them without
  knowing which one is live.
  """

  alias Schema.Tracker.Issue

  @callback fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
end
