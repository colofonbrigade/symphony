defmodule Utils.Runtime do
  @moduledoc """
  Process-tree-scoped accessor for Symphony runtime values.

  Reads fall back from `Process.get/1` (walked up the process ancestry via
  `ProcessTree`) to `Application.get_env(:core, key)` to the caller-supplied
  default. Tests override a value with `Process.put/2` in the test process,
  which reaches short-lived callers (controllers, pure functions) via
  ancestry without mutating BEAM-global Application env.

  Caching is always on — ProcessTree's default. This is intentional: the
  cache lives in each caller's own dict, so it dies with that process. The
  one shape this doesn't fit — a long-lived GenServer that reads the same
  key repeatedly across test runs — is handled by having those processes
  read `Application.get_env` directly instead of going through here.

  Third-party libraries (Phoenix endpoint, Ecto repo) read their own config
  via Application env without touching this module.
  """

  @spec get(atom(), term()) :: term()
  def get(key, default \\ nil) when is_atom(key) do
    ProcessTree.get(key, default: Application.get_env(:core, key, default))
  end
end
