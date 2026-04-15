defmodule Core do
  @moduledoc """
  Entry point for the Symphony orchestrator and home of domain-core
  modules (orchestrator, agent runner, workspace, telemetry, workflow
  loader, status dashboard).
  """

  use Boundary,
    deps: [Schema, Permissions, Transport, Claude],
    exports: [
      AgentRunner,
      CLI,
      Config,
      LogFile,
      ObservabilityPubSub,
      Orchestrator,
      PromptBuilder,
      Runtime,
      SpecsCheck,
      StatusDashboard,
      Telemetry.Bootstrap,
      Telemetry.Repo,
      Telemetry.Writer,
      Tracker,
      Workflow,
      WorkflowStore,
      Workspace
    ]

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Core.Orchestrator.start_link(opts)
  end
end
