defmodule Core.Runtime do
  @moduledoc """
  Process-tree-scoped accessor for Symphony runtime values.

  Reads fall back from `Process.get/1` (walked up the process ancestry via
  `ProcessTree`) to `Application.get_env(:core, key)` to the caller-supplied
  default. This lets tests override a value with `Process.put/2` in their own
  process without mutating BEAM-global Application env, which keeps
  `async: true` viable and avoids `on_exit` cleanup churn.

  Use this for config our own code reads. Values consumed by third-party
  libraries (Phoenix endpoint http/secret_key_base, Ecto repo) still live in
  Application env because those libraries don't route through this module.

  Caching is controlled by `config :core, Core.Runtime, cache_reads: boolean`.
  On by default for production performance; off in `:test` so long-lived
  processes like `Core.WorkflowStore` don't pin a stale value into their own
  dict across tests.
  """

  @cache_reads? Application.compile_env!(:core, __MODULE__)[:cache_reads]

  @spec get(atom(), term()) :: term()
  def get(key, default \\ nil) when is_atom(key) do
    ProcessTree.get(key,
      default: Application.get_env(:core, key, default),
      cache: @cache_reads?
    )
  end
end
