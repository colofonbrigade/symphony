defmodule SymphonyElixir.Telemetry.Repo.Migrations.CreateAgentEvents do
  use Ecto.Migration

  def change do
    create table(:agent_events) do
      add :timestamp, :utc_datetime_usec, null: false
      add :session_id, :string
      add :issue_id, :string, null: false
      add :issue_identifier, :string
      add :turn_id, :integer
      add :event_type, :string, null: false
      add :input_tokens, :integer, default: 0
      add :output_tokens, :integer, default: 0
      add :cache_creation_input_tokens, :integer, default: 0
      add :cache_read_input_tokens, :integer, default: 0
      add :cost_usd, :float, default: 0.0
      add :rate_limit_status, :string
      add :rate_limit_type, :string
      add :resets_at, :utc_datetime
      add :is_using_overage, :boolean
      add :raw_payload, :text
    end

    create index(:agent_events, [:timestamp])
    create index(:agent_events, [:issue_id])
    create index(:agent_events, [:event_type])
  end
end
