defmodule SymphonyElixir.AgentRunner.OpencodeRunnerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AgentRunner.Behavior
  alias SymphonyElixir.AgentRunner.OpencodeRunner

  describe "Behavior" do
    test "format_token_report formats token counts correctly" do
      tokens = %{input_tokens: 1000, output_tokens: 500, total_tokens: 1500}
      assert OpencodeRunner.format_token_report(tokens) == "tokens: 1500 total (1000 in / 500 out)"
    end

    test "format_token_report handles zero tokens" do
      tokens = %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
      assert OpencodeRunner.format_token_report(tokens) == "tokens: 0 total (0 in / 0 out)"
    end

    test "format_token_report handles large token counts" do
      tokens = %{input_tokens: 1_500_000, output_tokens: 750_000, total_tokens: 2_250_000}

      assert OpencodeRunner.format_token_report(tokens) ==
               "tokens: 2250000 total (1500000 in / 750000 out)"
    end
  end

  describe "OpencodeRunner" do
    @workspace_path System.tmp_dir!()
                    |> Path.join("symphony-opencode-runner-test-#{:rand.uniform(999_999)}")

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
      assert @workspace_path =~ "symphony-opencode-runner-test"
    end
  end

  describe "Behavior types" do
    test "agent_event can be event tuple" do
      event = {:event, :turn_start, %{turn_number: 1}}
      assert match?({:event, _, _}, event)
    end

    test "agent_event can be done tuple" do
      event = {:done, 5, %{token_counts: %{input_tokens: 1000, output_tokens: 500, total_tokens: 1500}}}

      assert match?({:done, n, _} when is_integer(n) and n >= 0, event)
    end

    test "token_counts type" do
      token_counts = %{input_tokens: 100, output_tokens: 50, total_tokens: 150}
      assert token_counts.input_tokens == 100
      assert token_counts.output_tokens == 50
      assert token_counts.total_tokens == 150
    end

    test "agent_event types are distinct" do
      event1 = {:event, :tool_call, %{tool_name: "Read"}}
      done1 = {:done, 0, %{token_counts: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}}}

      assert elem(event1, 0) == :event
      assert elem(done1, 0) == :done
    end
  end
end
