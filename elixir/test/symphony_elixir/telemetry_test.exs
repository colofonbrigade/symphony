defmodule SymphonyElixir.TelemetryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Telemetry.AgentEvent
  alias SymphonyElixir.Telemetry.Repo
  alias SymphonyElixir.Telemetry.Writer

  import Ecto.Query

  setup do
    Repo.delete_all(AgentEvent)
    :ok
  end

  defp sync_writer do
    # GenServer.cast is async; ping with a sync call so the writer has drained.
    _ = :sys.get_state(Writer)
    :ok
  end

  describe "turn_completed events" do
    test "persists usage and cost into a row" do
      update = %{
        event: :turn_completed,
        timestamp: DateTime.utc_now(),
        session_id: "abc-session",
        turn_id: 3,
        usage: %{
          "input_tokens" => 120,
          "output_tokens" => 45,
          "cache_creation_input_tokens" => 10,
          "cache_read_input_tokens" => 5
        },
        payload: %{
          "type" => "result",
          "total_cost_usd" => 0.0123,
          "usage" => %{"input_tokens" => 120, "output_tokens" => 45}
        }
      }

      Writer.record("issue-1", "PRE-100", update)
      sync_writer()

      [row] = Repo.all(from(e in AgentEvent, where: e.issue_id == "issue-1"))
      assert row.event_type == "turn_completed"
      assert row.session_id == "abc-session"
      assert row.issue_identifier == "PRE-100"
      assert row.turn_id == 3
      assert row.input_tokens == 120
      assert row.output_tokens == 45
      assert row.cache_creation_input_tokens == 10
      assert row.cache_read_input_tokens == 5
      assert_in_delta row.cost_usd, 0.0123, 1.0e-6
      assert row.raw_payload =~ "total_cost_usd"
    end
  end

  describe "rate_limit_event notifications" do
    test "persists status, type, resets_at, and overage flag" do
      resets_at_unix = 1_775_696_400

      update = %{
        event: :notification,
        timestamp: DateTime.utc_now(),
        session_id: "rl-session",
        turn_id: 1,
        payload: %{
          "type" => "rate_limit_event",
          "rate_limit_info" => %{
            "status" => "throttled",
            "rateLimitType" => "five_hour",
            "resetsAt" => resets_at_unix,
            "isUsingOverage" => false
          }
        }
      }

      Writer.record("issue-2", "PRE-101", update)
      sync_writer()

      [row] = Repo.all(from(e in AgentEvent, where: e.issue_id == "issue-2"))
      assert row.event_type == "rate_limit_event"
      assert row.rate_limit_status == "throttled"
      assert row.rate_limit_type == "five_hour"
      assert row.resets_at == DateTime.from_unix!(resets_at_unix)
      assert row.is_using_overage == false
    end
  end

  describe "unrelated events" do
    test "generic notifications are skipped" do
      update = %{
        event: :notification,
        timestamp: DateTime.utc_now(),
        payload: %{"type" => "assistant"}
      }

      Writer.record("issue-3", "PRE-102", update)
      sync_writer()

      assert Repo.all(from(e in AgentEvent, where: e.issue_id == "issue-3")) == []
    end

    test "session_started is skipped" do
      update = %{
        event: :session_started,
        timestamp: DateTime.utc_now(),
        session_id: "s"
      }

      Writer.record("issue-4", "PRE-103", update)
      sync_writer()

      assert Repo.all(from(e in AgentEvent, where: e.issue_id == "issue-4")) == []
    end
  end

  describe "Telemetry.record/3 disabled mode" do
    test "is a no-op when observability.telemetry_enabled is false" do
      write_workflow_file!(Workflow.workflow_file_path(), observability_telemetry_enabled: false)

      update = %{
        event: :turn_completed,
        timestamp: DateTime.utc_now(),
        usage: %{"input_tokens" => 1, "output_tokens" => 2},
        payload: %{"total_cost_usd" => 0.001}
      }

      :ok = SymphonyElixir.Telemetry.record("issue-5", "PRE-104", update)
      sync_writer()

      assert Repo.all(from(e in AgentEvent, where: e.issue_id == "issue-5")) == []
    end
  end
end
