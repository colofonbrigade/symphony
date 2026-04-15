defmodule Linear do
  @moduledoc """
  Linear tracker integration. Implements the `Linear.Tracker` behaviour;
  `Core.Tracker` dispatches to `Linear.Adapter` via the configured adapter
  module.

  Currently depends on `Core` for tracker settings (`Core.Config`); the plan
  is to thread settings through the adapter interface so this becomes
  `deps: [Schema]` only. Tracked in `docs/local_elixir_rules.md`.
  """

  use Boundary, deps: [Core, Schema], exports: [Adapter, Client, ResponseDecoder, Tracker]
end
