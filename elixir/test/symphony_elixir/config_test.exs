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

    test "load with only tracker + workspace (no agent.kind) → defaults to codex" do
      # Legacy format: no agent section at all, no codex section
      # Agent kind should default to :codex
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: nil,
        codex_command: nil
      )

      assert Config.agent_kind() == :codex
    end

    test "load with codex.command set but no agent.kind → works as before" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: nil,
        codex_command: "codex app-server",
        codex_thread_sandbox: "workspace-write"
      )

      assert Config.agent_kind() == :codex
      assert Config.agent_kind_string() == "codex"
    end

    test "load with agent.kind: codex and codex.* config → works" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "codex",
        codex_command: "codex app-server",
        codex_thread_sandbox: "workspace-write",
        codex_turn_timeout_ms: 3_600_000
      )

      assert Config.agent_kind() == :codex
    end

    test "load with agent.kind: opencode and codex.* config present → opencode used, codex.* ignored" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "opencode",
        codex_command: "codex app-server",
        codex_thread_sandbox: "workspace-write",
        agent_command: "opencode --acp --stdio"
      )

      # agent_kind should be opencode, NOT codex
      assert Config.agent_kind() == :opencode
      assert Config.agent_kind_string() == "opencode"

      # opencode_config should use its own command, NOT the codex command
      opencode_cfg = Config.opencode_config()
      assert opencode_cfg.command == "opencode --acp --stdio"
    end

    test "agent.kind: codex with existing codex.* config → codex config used" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "codex",
        codex_command: "codex app-server",
        codex_approval_policy: %{"reject" => %{"sandbox_approval" => true}}
      )

      assert Config.agent_kind() == :codex
    end

    test "agent.kind is NOT codex → codex.* keys silently ignored" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "claude-code",
        codex_command: "this-should-be-ignored",
        codex_thread_sandbox: "this-should-be-ignored",
        agent_command: "claude --acp --stdio"
      )

      # agent_kind should be claude_code, NOT codex
      assert Config.agent_kind() == :claude_code

      # claude_code_config should use its own command, NOT the codex command
      claude_cfg = Config.claude_code_config()
      assert claude_cfg.command == "claude --acp --stdio"
    end
  end
end
