defmodule Core.StatusDashboardSnapshotTest do
  use Core.TestSupport

  alias Core.TestSupport.Snapshot

  @terminal_columns 115

  test "snapshot fixture: idle dashboard" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
       }}

    Snapshot.assert_dashboard_snapshot!("idle", render_snapshot(snapshot_data, 0.0))
  end

  test "snapshot fixture: idle dashboard with observability url" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
       }}

    rendered = render_snapshot(snapshot_data, 0.0, %{dashboard_port: 4000})

    Snapshot.assert_dashboard_snapshot!("idle_with_dashboard_url", rendered)
  end

  test "snapshot fixture: super busy dashboard" do
    snapshot_data =
      {:ok,
       %{
         running: [
           running_entry(%{
             identifier: "MT-101",
             agent_total_tokens: 120_450,
             runtime_seconds: 785,
             turn_count: 11,
             last_agent_event: :turn_completed,
             last_agent_message: turn_completed_message("completed")
           }),
           running_entry(%{
             identifier: "MT-102",
             session_id: "thread-abcdef1234567890",
             agent_pid: "5252",
             agent_total_tokens: 89_200,
             runtime_seconds: 412,
             turn_count: 4,
             last_agent_event: :session_started,
             last_agent_message: exec_command_message("mix test --cover")
           })
         ],
         retrying: [],
         agent_totals: %{
           input_tokens: 250_000,
           output_tokens: 18_500,
           total_tokens: 268_500,
           seconds_running: 4_321
         }
       }}

    Snapshot.assert_dashboard_snapshot!("super_busy", render_snapshot(snapshot_data, 1_842.7))
  end

  test "snapshot fixture: backoff queue pressure" do
    snapshot_data =
      {:ok,
       %{
         running: [
           running_entry(%{
             identifier: "MT-638",
             state: "retrying",
             agent_total_tokens: 14_200,
             runtime_seconds: 1_225,
             turn_count: 7,
             last_agent_event: :notification,
             last_agent_message: agent_message_delta("waiting on rate-limit backoff window")
           })
         ],
         retrying: [
           retry_entry(%{
             identifier: "MT-450",
             attempt: 4,
             due_in_ms: 1_250,
             error: "rate limit exhausted"
           }),
           retry_entry(%{
             identifier: "MT-451",
             attempt: 2,
             due_in_ms: 3_900,
             error: "retrying after API timeout with jitter"
           }),
           retry_entry(%{
             identifier: "MT-452",
             attempt: 6,
             due_in_ms: 8_100,
             error: "worker crashed\nrestarting cleanly"
           }),
           retry_entry(%{
             identifier: "MT-453",
             attempt: 1,
             due_in_ms: 11_000,
             error: "fourth queued retry should also render after removing the top-three limit"
           })
         ],
         agent_totals: %{input_tokens: 18_000, output_tokens: 2_200, total_tokens: 20_200, seconds_running: 2_700}
       }}

    Snapshot.assert_dashboard_snapshot!("backoff_queue", render_snapshot(snapshot_data, 15.4))
  end

  test "backoff queue row escapes escaped newline sequences" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [
           retry_entry(%{
             identifier: "MT-980",
             attempt: 1,
             due_in_ms: 1_500,
             error: "error with \\nnewline"
           })
         ],
         agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
       }}

    rendered = render_snapshot(snapshot_data, 0.0)
    backoff_lines = rendered |> String.split("\n") |> Enum.filter(&String.contains?(&1, "MT-980"))

    assert length(backoff_lines) == 1

    [backoff_line] = backoff_lines

    assert backoff_line =~ "error=error with newline"
    refute backoff_line =~ "\\n"
  end

  test "snapshot fixture: unlimited credits variant" do
    snapshot_data =
      {:ok,
       %{
         running: [
           running_entry(%{
             identifier: "MT-777",
             state: "running",
             agent_total_tokens: 3_200,
             runtime_seconds: 75,
             turn_count: 7,
             last_agent_event: :notification,
             last_agent_message: token_usage_message(90, 12, 102)
           })
         ],
         retrying: [],
         agent_totals: %{input_tokens: 90, output_tokens: 12, total_tokens: 102, seconds_running: 75}
       }}

    Snapshot.assert_dashboard_snapshot!("credits_unlimited", render_snapshot(snapshot_data, 42.0))
  end

  defp render_snapshot(snapshot_data, tps, context_overrides \\ %{}) do
    Renderer.format_snapshot_content(snapshot_data, tps, dashboard_context(context_overrides), @terminal_columns)
  end

  defp running_entry(overrides) do
    Map.merge(
      %{
        identifier: "MT-000",
        state: "running",
        session_id: "thread-1234567890",
        agent_pid: "4242",
        agent_total_tokens: 0,
        runtime_seconds: 0,
        turn_count: 1,
        last_agent_event: :notification,
        last_agent_message: turn_started_message()
      },
      overrides
    )
  end

  defp retry_entry(overrides) do
    Map.merge(
      %{
        issue_id: "issue-1",
        identifier: "MT-000",
        attempt: 1,
        due_in_ms: 1_000,
        error: "retry scheduled"
      },
      overrides
    )
  end

  defp turn_started_message do
    %{
      event: :session_started,
      message: %{"session_id" => "459972f6-4eea-4448-9ebf-b0864a01940a"}
    }
  end

  defp turn_completed_message(_status) do
    %{
      event: :turn_completed,
      message: %{
        "type" => "result",
        "subtype" => "success",
        "is_error" => false,
        "usage" => %{"input_tokens" => 18, "output_tokens" => 4},
        "total_cost_usd" => 0.0125
      }
    }
  end

  defp exec_command_message(command) do
    %{
      event: :notification,
      message: %{
        "type" => "assistant",
        "message" => %{
          "content" => [%{"type" => "text", "text" => command}]
        }
      }
    }
  end

  defp agent_message_delta(delta) do
    %{
      event: :notification,
      message: %{
        "type" => "assistant",
        "message" => %{
          "content" => [%{"type" => "text", "text" => delta}]
        }
      }
    }
  end

  defp token_usage_message(input_tokens, output_tokens, _total_tokens) do
    %{
      event: :notification,
      message: %{
        "type" => "assistant",
        "message" => %{
          "content" => [%{"type" => "text", "text" => "processing..."}],
          "usage" => %{
            "input_tokens" => input_tokens,
            "output_tokens" => output_tokens
          }
        }
      }
    }
  end
end
