defmodule SymphonyElixir.ConfigTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Config

  describe "agent_kind/0" do
    test "returns :codex when kind is codex" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "codex")
      assert Config.agent_kind() == :codex
    end

    test "returns :claude_code when kind is claude-code" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "claude-code")
      assert Config.agent_kind() == :claude_code
    end

    test "returns :opencode when kind is opencode" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "opencode")
      assert Config.agent_kind() == :opencode
    end

    test "returns :openclaw when kind is openclaw" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "openclaw")
      assert Config.agent_kind() == :openclaw
    end

    test "returns :hermes when kind is hermes" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "hermes")
      assert Config.agent_kind() == :hermes
    end

    test "defaults to :codex when kind is not specified" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: nil)
      assert Config.agent_kind() == :codex
    end

    test "raises ArgumentError for unknown agent kind" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "unknown-agent")

      assert_raise ArgumentError,
                   ~s(Unknown agent kind: "unknown-agent". Valid kinds are: codex, claude-code, opencode, openclaw, hermes),
                   fn ->
                     Config.agent_kind()
                   end
    end
  end

  describe "agent_kind_string/0" do
    test "returns the raw kind string" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "claude-code")
      assert Config.agent_kind_string() == "claude-code"
    end

    test "defaults to codex when kind is not specified" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: nil)
      assert Config.agent_kind_string() == "codex"
    end
  end

  describe "claude_code_config/0" do
    test "returns default command for claude-code" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "claude-code")
      config = Config.claude_code_config()
      assert config.command == "claude --acp --stdio"
    end

    test "uses custom command when provided" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "claude-code",
        agent_command: "/usr/local/bin/claude --acp --stdio"
      )

      config = Config.claude_code_config()
      assert config.command == "/usr/local/bin/claude --acp --stdio"
    end

    test "returns model and provider when set" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "claude-code",
        agent_model: "claude-sonnet-4-20250514",
        agent_provider: "anthropic"
      )

      config = Config.claude_code_config()
      assert config.model == "claude-sonnet-4-20250514"
      assert config.provider == "anthropic"
    end

    test "returns default timeout values" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "claude-code")
      config = Config.claude_code_config()

      assert config.turn_timeout_ms == 3_600_000
      assert config.read_timeout_ms == 5_000
      assert config.stall_timeout_ms == 300_000
    end

    test "returns thread_sandbox setting" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "claude-code",
        codex_thread_sandbox: "workspace-write"
      )

      config = Config.claude_code_config()
      assert config.thread_sandbox == "workspace-write"
    end

    test "returns approval_policy setting" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "claude-code",
        codex_approval_policy: %{"reject" => %{"sandbox_approval" => true}}
      )

      config = Config.claude_code_config()
      assert config.approval_policy == %{"reject" => %{"sandbox_approval" => true}}
    end
  end

  describe "opencode_config/0" do
    test "returns default command for opencode" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "opencode")
      config = Config.opencode_config()
      assert config.command == "opencode --acp --stdio"
    end

    test "uses custom command when provided" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "opencode",
        agent_command: "/usr/local/bin/opencode --acp --stdio"
      )

      config = Config.opencode_config()
      assert config.command == "/usr/local/bin/opencode --acp --stdio"
    end

    test "returns model and provider when set" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "opencode",
        agent_model: "gpt-4o",
        agent_provider: "openai"
      )

      config = Config.opencode_config()
      assert config.model == "gpt-4o"
      assert config.provider == "openai"
    end
  end

  describe "openclaw_config/0" do
    test "returns default command for openclaw" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "openclaw")
      config = Config.openclaw_config()
      assert config.command == "openclaw --acp --stdio"
    end

    test "uses custom command when provided" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "openclaw",
        agent_command: "/usr/local/bin/openclaw --acp --stdio"
      )

      config = Config.openclaw_config()
      assert config.command == "/usr/local/bin/openclaw --acp --stdio"
    end
  end

  describe "hermes_config/0" do
    test "returns default command for hermes" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "hermes")
      config = Config.hermes_config()
      assert config.command == "hermes chat --acp --stdio"
    end

    test "uses custom command when provided" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "hermes",
        agent_command: "/usr/local/bin/hermes chat --acp --stdio"
      )

      config = Config.hermes_config()
      assert config.command == "/usr/local/bin/hermes chat --acp --stdio"
    end

    test "returns model and provider when set" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "hermes",
        agent_model: "hermes-3",
        agent_provider: "aliyun"
      )

      config = Config.hermes_config()
      assert config.model == "hermes-3"
      assert config.provider == "aliyun"
    end
  end

  describe "backward compatibility" do
    test "agent.kind defaults to codex for backward compatibility" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: nil)
      assert Config.agent_kind() == :codex
      assert Config.agent_kind_string() == "codex"
    end

    test "codex command works with default settings" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "codex",
        codex_command: "codex app-server"
      )

      # Codex config comes from codex section, not agent section
      # but the agent_kind should work
      assert Config.agent_kind() == :codex
    end
  end
end
