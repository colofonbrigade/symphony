defmodule Core.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
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
      Core.HttpServer,
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
