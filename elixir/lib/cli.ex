defmodule CLI do
  @moduledoc """
  Pure terminal-UI rendering helpers. Turns orchestrator snapshot data into
  ANSI-colorized strings that `Core.StatusDashboard` writes to stdout.

  Leaf of the DAG modulo `Schema`: depends on no other boundary. Future
  additions (alternate renderers, progress bars, non-dashboard CLI output)
  live here.
  """

  use Boundary, deps: [Schema], exports: [StatusDashboard, StatusDashboard.AgentMessage]
end
