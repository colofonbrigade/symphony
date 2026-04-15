defmodule Permissions do
  @moduledoc """
  Security-sensitive pure utilities (path traversal guards, credential
  scopes, etc.). Leaf of the DAG: no state, no Application env reads,
  no in-app deps.
  """

  use Boundary, deps: [], exports: [PathSafety]
end
