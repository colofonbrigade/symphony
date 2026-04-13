defmodule SymphonyElixir.Telemetry.Bootstrap do
  @moduledoc """
  Prepares the telemetry database before the Repo starts, and runs migrations
  after it does.
  """

  require Logger

  alias SymphonyElixir.Telemetry.Repo

  @spec prepare() :: :ok
  def prepare do
    db_path = Application.get_env(:symphony_elixir, Repo, [])[:database]

    cond do
      db_path in [nil, ":memory:"] ->
        :ok

      is_binary(db_path) ->
        db_path |> Path.dirname() |> File.mkdir_p!()
        :ok
    end

    :ok
  end

  @spec migrate() :: :ok
  def migrate do
    migrations_path = Path.join([:code.priv_dir(:symphony_elixir), "telemetry_repo", "migrations"])
    Ecto.Migrator.run(Repo, migrations_path, :up, all: true, log: false)
    :ok
  rescue
    error ->
      Logger.warning("telemetry migrations failed: #{Exception.message(error)}")
      :ok
  end
end
