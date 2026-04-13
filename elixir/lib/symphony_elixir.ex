defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  alias SymphonyElixir.Telemetry

  @impl true
  def start(_type, _args) do
    :ok = SymphonyElixir.LogFile.configure()
    :ok = Telemetry.Bootstrap.prepare()

    children = [
      {Phoenix.PubSub, name: SymphonyElixir.PubSub},
      {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
      Telemetry.Repo,
      Telemetry.Writer,
      SymphonyElixir.WorkflowStore,
      SymphonyElixir.Orchestrator,
      SymphonyElixir.HttpServer,
      SymphonyElixir.StatusDashboard
    ]

    with {:ok, sup} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: SymphonyElixir.Supervisor) do
      :ok = Telemetry.Bootstrap.migrate()
      {:ok, sup}
    end
  end

  @impl true
  def stop(_state) do
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end
end
