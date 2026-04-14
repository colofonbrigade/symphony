defmodule Core.Telemetry.AgentEvent do
  @moduledoc """
  One persisted row per meaningful agent update: turn-completion records carrying
  usage/cost, and rate-limit events snapshotted from Claude Code.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "agent_events" do
    field(:timestamp, :utc_datetime_usec)
    field(:session_id, :string)
    field(:issue_id, :string)
    field(:issue_identifier, :string)
    field(:turn_id, :integer)
    field(:event_type, :string)
    field(:input_tokens, :integer, default: 0)
    field(:output_tokens, :integer, default: 0)
    field(:cache_creation_input_tokens, :integer, default: 0)
    field(:cache_read_input_tokens, :integer, default: 0)
    field(:cost_usd, :float, default: 0.0)
    field(:rate_limit_status, :string)
    field(:rate_limit_type, :string)
    field(:resets_at, :utc_datetime)
    field(:is_using_overage, :boolean)
    field(:raw_payload, :string)
  end

  @fields ~w(
    timestamp session_id issue_id issue_identifier turn_id event_type
    input_tokens output_tokens cache_creation_input_tokens cache_read_input_tokens
    cost_usd rate_limit_status rate_limit_type resets_at is_using_overage raw_payload
  )a

  @required ~w(timestamp issue_id event_type)a

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, @fields)
    |> validate_required(@required)
  end
end
