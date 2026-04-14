defmodule Symphony.Application do
  @moduledoc """
  OTP application entrypoint. This is the composition root: it wires together
  children from every boundary (`Core`, `Web`, and their peers) and is the
  only module allowed to reach across all of them.
  """

  use Application

  alias Core.Telemetry

  @impl true
  def start(_type, _args) do
    :ok = Core.LogFile.configure()
    :ok = Telemetry.Bootstrap.prepare()

    children = [
      {Phoenix.PubSub, name: Core.PubSub},
      {Task.Supervisor, name: Core.TaskSupervisor},
      Telemetry.Repo,
      Telemetry.Writer,
      Core.WorkflowStore,
      Core.Orchestrator,
      Web.HttpServer,
      Core.StatusDashboard
    ]

    with {:ok, sup} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: Core.Supervisor) do
      :ok = Telemetry.Bootstrap.migrate()
      {:ok, sup}
    end
  end

  @impl true
  def stop(_state) do
    Core.StatusDashboard.render_offline_status()
    :ok
  end
end
