defmodule Schema do
  @moduledoc """
  Shared data structures used across boundary lines. Leaf of the DAG:
  depends on nothing in-app. See `docs/elixir_rules.md` § "The Schema
  boundary" for what belongs here.
  """

  use Boundary, deps: [], exports: [Snapshot, Tracker.Issue]
end
