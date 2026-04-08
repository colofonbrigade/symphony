defmodule SymphonyElixir.Claude.SessionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Claude.Session

  @issue %{
    id: "issue-test",
    identifier: "TST-1",
    title: "Test issue",
    state: "In Progress"
  }

  describe "workspace validation" do
    test "rejects workspace equal to workspace root" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-claude-session-validate-root-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        File.mkdir_p!(workspace_root)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          claude_command: "echo not-used"
        )

        assert {:error, {:invalid_workspace_cwd, :workspace_root, _}} =
                 Session.start_session(workspace_root)
      after
        File.rm_rf(test_root)
      end
    end

    test "rejects workspace outside the configured workspace root" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-claude-session-validate-outside-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        outside_workspace = Path.join(test_root, "elsewhere")
        File.mkdir_p!(workspace_root)
        File.mkdir_p!(outside_workspace)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          claude_command: "echo not-used"
        )

        assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _, _}} =
                 Session.start_session(outside_workspace)
      after
        File.rm_rf(test_root)
      end
    end

    test "rejects symlink-escape paths under the workspace root" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-claude-session-validate-symlink-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        outside_target = Path.join(test_root, "outside-target")
        symlink_workspace = Path.join(workspace_root, "TST-LINK")
        File.mkdir_p!(workspace_root)
        File.mkdir_p!(outside_target)
        File.ln_s!(outside_target, symlink_workspace)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          claude_command: "echo not-used"
        )

        assert {:error, {:invalid_workspace_cwd, :symlink_escape, ^symlink_workspace, _}} =
                 Session.start_session(symlink_workspace)
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "single-turn happy path" do
    test "extracts session_id from system init event and emits :session_started + :turn_completed" do
      with_fake_session(fn workspace, _trace_file ->
        assert {:ok, session} = Session.start_session(workspace)
        assert is_binary(session.session_id)
        assert session.session_id == "fake-session-uuid"
        assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)
        assert session.workspace == canonical_workspace
        assert session.turn_count == 0
        assert is_port(session.port)

        parent = self()
        on_message = fn msg -> send(parent, {:msg, msg.event, msg}) end

        assert {:ok, run_result} =
                 Session.run_turn(session, "Hello", @issue, on_message: on_message)

        assert run_result.session_id == "fake-session-uuid"
        assert run_result.turn_id == 1
        assert run_result.session.turn_count == 1
        assert is_map(run_result.result)
        assert run_result.result["type"] == "result"
        assert run_result.result["is_error"] == false

        assert_received {:msg, :session_started, started_msg}
        assert started_msg.session_id == "fake-session-uuid"
        assert started_msg.turn_id == 1

        assert_received {:msg, :notification, _assistant_msg}
        assert_received {:msg, :turn_completed, completed_msg}
        assert completed_msg.session_id == "fake-session-uuid"
        assert completed_msg.turn_id == 1
        assert is_map(completed_msg.usage)

        Session.stop_session(session)
      end)
    end

    test "stop_session is safe to call after the port has exited" do
      with_fake_session(fn workspace, _trace_file ->
        assert {:ok, session} = Session.start_session(workspace)
        assert {:ok, _} = Session.run_turn(session, "Hello", @issue)
        assert :ok = Session.stop_session(session)
        # Calling again is a no-op
        assert :ok = Session.stop_session(session)
      end)
    end
  end

  describe "multi-turn over a single session" do
    test "two run_turn calls reuse the same port and session_id" do
      with_fake_session(fn workspace, trace_file ->
        assert {:ok, session} = Session.start_session(workspace)

        parent = self()

        assert {:ok, turn_1} =
                 Session.run_turn(
                   session,
                   "First turn",
                   @issue,
                   on_message: fn msg -> send(parent, {:msg, 1, msg.event}) end
                 )

        assert turn_1.turn_id == 1
        updated_session = turn_1.session
        assert updated_session.turn_count == 1
        assert updated_session.session_id == session.session_id

        assert {:ok, turn_2} =
                 Session.run_turn(
                   updated_session,
                   "Second turn",
                   @issue,
                   on_message: fn msg -> send(parent, {:msg, 2, msg.event}) end
                 )

        assert turn_2.turn_id == 2
        assert turn_2.session_id == session.session_id
        assert turn_2.session.turn_count == 2

        # Both turns should have emitted session_started + turn_completed
        assert_received {:msg, 1, :session_started}
        assert_received {:msg, 1, :turn_completed}
        assert_received {:msg, 2, :session_started}
        assert_received {:msg, 2, :turn_completed}

        Session.stop_session(session)

        # Trace file records both stdin user messages
        trace = File.read!(trace_file)
        stdin_lines = trace |> String.split("\n", trim: true) |> Enum.filter(&String.starts_with?(&1, "STDIN:"))
        assert length(stdin_lines) == 2

        decoded = Enum.map(stdin_lines, fn "STDIN:" <> json -> Jason.decode!(json) end)
        assert Enum.all?(decoded, fn payload -> payload["type"] == "user" end)

        contents = Enum.map(decoded, &get_in(&1, ["message", "content"]))
        assert "First turn" in contents
        assert "Second turn" in contents
      end)
    end
  end

  describe "error paths" do
    test "result event with is_error: true returns {:error, {:turn_failed, _}}" do
      with_fake_session(
        fn workspace, _trace_file ->
          assert {:ok, session} = Session.start_session(workspace)

          parent = self()

          assert {:error, {:turn_failed, _reason}} =
                   Session.run_turn(
                     session,
                     "Doomed turn",
                     @issue,
                     on_message: fn msg -> send(parent, {:msg, msg.event}) end
                   )

          assert_received {:msg, :session_started}
          assert_received {:msg, :notification}
          assert_received {:msg, :turn_failed}
          assert_received {:msg, :turn_ended_with_error}

          Session.stop_session(session)
        end,
        flavor: :error
      )
    end

    test "port exit before result event returns {:error, {:port_exit, _}}" do
      with_fake_session(
        fn workspace, _trace_file ->
          assert {:ok, session} = Session.start_session(workspace)

          assert {:error, {:port_exit, _status}} =
                   Session.run_turn(session, "Crashing turn", @issue)

          Session.stop_session(session)
        end,
        flavor: :crash
      )
    end
  end

  describe "command construction" do
    test "constructs claude argv with permission_mode, model, effort, and mcp_config_path" do
      with_fake_session(
        fn workspace, trace_file ->
          assert {:ok, session} = Session.start_session(workspace)
          assert {:ok, _} = Session.run_turn(session, "Hello", @issue)
          Session.stop_session(session)

          trace = File.read!(trace_file)
          argv_line = trace |> String.split("\n", trim: true) |> Enum.find(&String.starts_with?(&1, "ARGV:"))
          assert argv_line, "fake binary should have written an ARGV line"

          argv = String.replace_prefix(argv_line, "ARGV:", "")
          assert argv =~ "--print"
          assert argv =~ "--input-format stream-json"
          assert argv =~ "--output-format stream-json"
          assert argv =~ "--verbose"
          # Single quotes from shell_escape are consumed by bash -lc when
          # building argv; the fake binary sees the raw values.
          assert argv =~ "--permission-mode bypassPermissions"
          assert argv =~ "--model claude-sonnet-4-6"
          assert argv =~ "--effort high"
          assert argv =~ "--mcp-config /tmp/custom-mcp.json"
        end,
        claude_overrides: [
          claude_effort: "high",
          claude_mcp_config_path: "/tmp/custom-mcp.json"
        ]
      )
    end
  end

  ## --- helpers ----------------------------------------------------------

  defp with_fake_session(test_body, opts \\ []) do
    flavor = Keyword.get(opts, :flavor, :happy)
    overrides = Keyword.get(opts, :claude_overrides, [])

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-claude-session-#{flavor}-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "TST-1")
      File.mkdir_p!(workspace)

      fake_binary = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "claude.trace")

      write_fake_claude!(fake_binary, trace_file, flavor)

      base_overrides = [
        workspace_root: workspace_root,
        claude_command: fake_binary
      ]

      write_workflow_file!(Workflow.workflow_file_path(), base_overrides ++ overrides)

      test_body.(workspace, trace_file)
    after
      File.rm_rf(test_root)
    end
  end

  defp write_fake_claude!(path, trace_file, :happy) do
    File.write!(path, """
    #!/bin/sh
    trace_file="#{trace_file}"
    printf 'ARGV:%s\\n' "$*" >> "$trace_file"
    session_id="fake-session-uuid"

    # Emit system init
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"'"$session_id"'","cwd":"'"$PWD"'","tools":[],"mcp_servers":[],"model":"test","permissionMode":"bypassPermissions","apiKeySource":"none","claude_code_version":"test"}'

    turn=0
    while IFS= read -r line; do
      turn=$((turn + 1))
      printf 'STDIN:%s\\n' "$line" >> "$trace_file"

      printf '%s\\n' '{"type":"assistant","message":{"id":"msg_'"$turn"'","model":"test","role":"assistant","type":"message","content":[{"type":"text","text":"Reply '"$turn"'"}],"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"session_id":"'"$session_id"'","uuid":"event-assistant-'"$turn"'"}'

      printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":100,"num_turns":1,"result":"Reply '"$turn"'","stop_reason":"end_turn","session_id":"'"$session_id"'","total_cost_usd":0.001,"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"modelUsage":{},"permission_denials":[],"terminal_reason":"completed","uuid":"event-result-'"$turn"'"}'
    done

    exit 0
    """)

    File.chmod!(path, 0o755)
  end

  defp write_fake_claude!(path, trace_file, :error) do
    File.write!(path, """
    #!/bin/sh
    trace_file="#{trace_file}"
    printf 'ARGV:%s\\n' "$*" >> "$trace_file"
    session_id="fake-session-uuid"

    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"'"$session_id"'","cwd":"'"$PWD"'","tools":[],"mcp_servers":[],"model":"test","permissionMode":"bypassPermissions","apiKeySource":"none","claude_code_version":"test"}'

    while IFS= read -r line; do
      printf 'STDIN:%s\\n' "$line" >> "$trace_file"

      printf '%s\\n' '{"type":"assistant","message":{"id":"msg_err","model":"test","role":"assistant","type":"message","content":[{"type":"text","text":"oops"}],"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"session_id":"'"$session_id"'","uuid":"event-assistant-err"}'

      printf '%s\\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"duration_ms":42,"num_turns":1,"result":"simulated failure","stop_reason":"error","session_id":"'"$session_id"'","total_cost_usd":0,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"modelUsage":{},"permission_denials":[],"terminal_reason":"failed","uuid":"event-result-err"}'
    done

    exit 0
    """)

    File.chmod!(path, 0o755)
  end

  defp write_fake_claude!(path, trace_file, :crash) do
    File.write!(path, """
    #!/bin/sh
    trace_file="#{trace_file}"
    printf 'ARGV:%s\\n' "$*" >> "$trace_file"

    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"fake-session-uuid","cwd":"'"$PWD"'","tools":[],"mcp_servers":[],"model":"test","permissionMode":"bypassPermissions","apiKeySource":"none","claude_code_version":"test"}'

    # Read one stdin line then exit non-zero before emitting a result event
    IFS= read -r line
    printf 'STDIN:%s\\n' "$line" >> "$trace_file"
    exit 7
    """)

    File.chmod!(path, 0o755)
  end
end
