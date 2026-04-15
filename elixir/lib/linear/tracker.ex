defmodule Linear.Tracker do
  @moduledoc """
  Behaviour implemented by Linear-shaped tracker adapters. `Linear.Adapter` is
  the production implementer. Test doubles (see `test/support/tracker_memory.ex`)
  implement the same callbacks so `Core.Tracker` can dispatch to them without
  knowing which one is live.

  Every callback takes a tracker `settings` map as its first argument.
  `Core.Tracker` builds this from workflow config on each dispatch so the
  adapter and its client never read from `Core.Config` directly — this keeps
  Linear's boundary deps at `[Schema]` (plus the `Linear.Tracker` behaviour
  itself) and lets other implementations work without touching Core internals.
  """

  alias Schema.Tracker.Issue

  @type settings :: %{
          optional(:api_key) => String.t() | nil,
          optional(:endpoint) => String.t() | nil,
          optional(:project_slug) => String.t() | nil,
          optional(:active_states) => [String.t()],
          optional(:assignee) => String.t() | nil
        }

  @callback fetch_candidate_issues(settings()) :: {:ok, [Issue.t()]} | {:error, term()}
  @callback fetch_issues_by_states(settings(), [String.t()]) ::
              {:ok, [Issue.t()]} | {:error, term()}
  @callback fetch_issue_states_by_ids(settings(), [String.t()]) ::
              {:ok, [Issue.t()]} | {:error, term()}
end
