defmodule SymphonyElixir.Telemetry.Repo do
  @moduledoc """
  Ecto repo backing the telemetry sink. SQLite3 file-based store of per-session
  agent events (token usage, cost, rate-limit snapshots).
  """

  use Ecto.Repo,
    otp_app: :symphony_elixir,
    adapter: Ecto.Adapters.SQLite3

  @doc """
  Directory containing this repo's migrations, relative to :symphony_elixir's priv.
  """
  @spec priv() :: String.t()
  def priv, do: "priv/telemetry_repo"
end
