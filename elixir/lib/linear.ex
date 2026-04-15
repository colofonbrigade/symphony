defmodule Linear do
  @moduledoc """
  Linear tracker integration. Implements the `Linear.Tracker` behaviour;
  `Core.Tracker` dispatches to `Linear.Adapter` with settings threaded in
  at call time.
  """

  use Boundary, deps: [Schema], exports: [Adapter, Client, ResponseDecoder, Tracker]
end
