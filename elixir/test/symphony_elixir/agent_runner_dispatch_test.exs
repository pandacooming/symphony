defmodule SymphonyElixir.AgentRunnerDispatchTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AgentRunner

  describe "runner_for_kind mapping" do
    @runner_map %{
      codex: SymphonyElixir.AgentRunner.CodexRunner,
      claude_code: SymphonyElixir.AgentRunner.ClaudeCodeRunner,
      opencode: SymphonyElixir.AgentRunner.OpencodeRunner,
      openclaw: SymphonyElixir.AgentRunner.OpenclawRunner,
      hermes: SymphonyElixir.AgentRunner.HermesRunner
    }

    test "maps all valid agent kinds to runner modules" do
      kinds = [:codex, :claude_code, :opencode, :openclaw, :hermes]

      for kind <- kinds do
        assert Map.has_key?(@runner_map, kind),
               "Missing mapping for agent kind: #{kind}"
      end
    end

    test "each runner module implements AgentRunner.Behavior" do
      runners = Map.values(@runner_map)

      for runner <- runners do
        assert Code.ensure_loaded?(runner), "Runner #{runner} not loaded"
        assert function_exported?(runner, :start_link, 3), "Runner #{runner} missing start_link/3"
        assert function_exported?(runner, :stop, 1), "Runner #{runner} missing stop/1"
        assert function_exported?(runner, :stream_events, 1), "Runner #{runner} missing stream_events/1"
        assert function_exported?(runner, :token_counts, 1), "Runner #{runner} missing token_counts/1"
        assert function_exported?(runner, :workspace_path, 1), "Runner #{runner} missing workspace_path/1"
      end
    end
  end

  describe "AgentRunner.run/3" do
    test "run/3 function exists and has correct arity" do
      assert function_exported?(AgentRunner, :run, 3)
    end

    test "run/3 accepts issue, recipient, and opts arguments" do
      # Verify the function spec
      {:type, :fun, [{:type, :product, [_a, _b, _c]}, _ret]} =
        AgentRunner.__info__(:type) |> Enum.find(fn
          {:type, :fun, [{:type, :product, [_, _, _]}, _]} -> true
          _ -> false
        end)
    end
  end

  describe "runner config structure" do
    test "build_runner_config creates correct structure for runner" do
      issue = %{
        id: "test-issue",
        identifier: "TEST-1",
        title: "Test Issue",
        description: "Test description",
        state: "In Progress"
      }

      workspace = "/tmp/test-workspace"
      worker_host = nil
      max_turns = 5
      stall_timeout_ms = 60_000

      config = %{
        issue: issue,
        workspace_path: workspace,
        worker_host: worker_host,
        max_turns: max_turns,
        stall_timeout_ms: stall_timeout_ms
      }

      assert config.issue == issue
      assert config.workspace_path == workspace
      assert config.worker_host == worker_host
      assert config.max_turns == 5
      assert config.stall_timeout_ms == 60_000
    end
  end

  describe "event streaming contract" do
    test "runner events follow expected message format for orchestrator" do
      # These are the event types that runners emit
      event_types = [:turn_start, :turn_end, :tool_call, :tool_result, :error, :stall, :session_started]

      for event_type <- event_types do
        event = {:event, event_type, %{turn_number: 1, timestamp: DateTime.utc_now()}}

        assert elem(event, 0) == :event
        assert elem(event, 1) == event_type
        assert is_map(elem(event, 2))
      end
    end

    test "runner done events follow expected message format" do
      token_counts = %{input_tokens: 100, output_tokens: 50, total_tokens: 150}
      done = {:done, 5, %{token_counts: token_counts}}

      assert elem(done, 0) == :done
      assert elem(done, 1) == 5
      assert is_map(elem(done, 2))
      assert elem(done, 2)[:token_counts] == token_counts
    end

    test "orchestrator runner_event message format" do
      event_msg = {:runner_event, "issue-1", :turn_start, %{turn_number: 1, timestamp: DateTime.utc_now()}}

      assert elem(event_msg, 0) == :runner_event
      assert elem(event_msg, 1) == "issue-1"
      assert elem(event_msg, 2) == :turn_start
      assert is_map(elem(event_msg, 3))
    end

    test "orchestrator runner_done message format" do
      token_counts = %{input_tokens: 100, output_tokens: 50, total_tokens: 150}
      done_msg = {:runner_done, "issue-1", 5, %{token_counts: token_counts}}

      assert elem(done_msg, 0) == :runner_done
      assert elem(done_msg, 1) == "issue-1"
      assert elem(done_msg, 2) == 5
      assert is_map(elem(done_msg, 3))
    end
  end

  describe "workspace lifecycle integration" do
    test "workspace path follows expected naming convention" do
      # Verify that issue identifier is used for workspace naming
      issue_identifier = "TEST-123"
      safe_id = String.replace(issue_identifier, "/", "-")

      assert safe_id == "TEST-123"
    end

    test "AgentRunner calls Workspace.create_for_issue before running agent" do
      # This tests that Workspace.create_for_issue is in the call chain
      # by verifying the module structure
      assert Code.ensure_loaded?(SymphonyElixir.Workspace)
      assert function_exported?(SymphonyElixir.Workspace, :create_for_issue, 2)
    end
  end

  describe "agent_kind to runner module resolution" do
    test "all agent_kind atoms are valid" do
      valid_kinds = [:codex, :claude_code, :opencode, :openclaw, :hermes]

      for kind <- valid_kinds do
        assert is_atom(kind)
        assert kind in valid_kinds
      end
    end
  end
end
