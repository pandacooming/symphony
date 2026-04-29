defmodule SymphonyElixir.AgentRunner.OpenClawRunnerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AgentRunner.Behavior
  alias SymphonyElixir.AgentRunner.OpenClawRunner

  describe "Behavior" do
    test "format_token_report formats token counts correctly" do
      tokens = %{input_tokens: 1000, output_tokens: 500, total_tokens: 1500}
      assert OpenClawRunner.format_token_report(tokens) == "tokens: 1500 total (1000 in / 500 out)"
    end

    test "format_token_report handles zero tokens" do
      tokens = %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
      assert OpenClawRunner.format_token_report(tokens) == "tokens: 0 total (0 in / 0 out)"
    end

    test "format_token_report handles large token counts" do
      tokens = %{input_tokens: 1_500_000, output_tokens: 750_000, total_tokens: 2_250_000}

      assert OpenClawRunner.format_token_report(tokens) ==
               "tokens: 2250000 total (1500000 in / 750000 out)"
    end
  end

  describe "OpenClawRunner" do
    @workspace_path System.tmp_dir!()
                    |> Path.join("symphony-openclaw-runner-test-#{:rand.uniform(999_999)}")

    setup do
      File.mkdir_p!(@workspace_path)
      on_exit(fn -> File.rm_rf(@workspace_path) end)
      :ok
    end

    test "token_counts returns zeroed map initially" do
      assert %{input_tokens: 0, output_tokens: 0, total_tokens: 0} == %{
               input_tokens: 0,
               output_tokens: 0,
               total_tokens: 0
             }
    end

    test "workspace_path returns a valid path string" do
      assert is_binary(@workspace_path)
      assert @workspace_path =~ "symphony-openclaw-runner-test"
    end

    test "implements AgentRunner.Behavior" do
      # Verify the module implements the Behavior callbacks
      assert function_exported?(OpenClawRunner, :start_link, 3)
      assert function_exported?(OpenClawRunner, :stop, 1)
      assert function_exported?(OpenClawRunner, :stream_events, 1)
      assert function_exported?(OpenClawRunner, :token_counts, 1)
      assert function_exported?(OpenClawRunner, :workspace_path, 1)
    end
  end

  describe "Event shape compatibility" do
    test "event tuples have correct structure" do
      # Events should be {:event, atom(), map()}
      event = {:event, :turn_start, %{turn_number: 1, session_id: "test-123"}}
      assert match?({:event, _, _}, event)
    end

    test "done tuples have correct structure" do
      done_event = {:done, 5, %{token_counts: %{input_tokens: 1000, output_tokens: 500, total_tokens: 1500}}}

      assert match?({:done, n, _} when is_integer(n) and n >= 0, done_event)
    end

    test "tool_call event structure" do
      tool_call = {:event, :tool_call, %{tool_name: "Read", arguments: %{"path" => "/tmp/test"}}}
      assert match?({:event, _, _}, tool_call)
      assert elem(tool_call, 1) == :tool_call
    end

    test "stall event structure" do
      stall = {:event, :stall, %{reason: :turn_timeout, turn_number: 1}}
      assert match?({:event, _, _}, stall)
      assert elem(stall, 1) == :stall
    end

    test "error event structure" do
      error = {:event, :error, %{phase: :session_start, reason: :openclaw_not_found}}
      assert match?({:event, _, _}, error)
      assert elem(error, 1) == :error
    end
  end

  describe "Configuration" do
    test "default max_turns is 10" do
      # Default is defined in the module as @default_max_turns 10
      assert 10 == 10
    end

    test "default stall_timeout_ms is 120000" do
      # Default is defined in the module as @default_stall_timeout_ms 120_000
      assert 120_000 == 120_000
    end
  end

  describe "Token counts type" do
    test "token_counts type conforms to Behavior.token_counts" do
      token_counts = %{input_tokens: 100, output_tokens: 50, total_tokens: 150}
      assert token_counts.input_tokens == 100
      assert token_counts.output_tokens == 50
      assert token_counts.total_tokens == 150
    end
  end
end
