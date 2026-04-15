defmodule Utils do
  @moduledoc """
  Cross-cutting infrastructure helpers. Leaf of the DAG (deps: []); every
  boundary may depend on `Utils` without creating cycles.

  Today houses `Utils.Runtime` — a thin `ProcessTree`-backed accessor that
  falls back to `Application.get_env(:core, key)`. Tests override values by
  `Process.put(key, value)` in the test process; production and long-lived
  readers that need always-current values read `Application.get_env` directly.
  """

  use Boundary, deps: [], exports: [Runtime]
end
