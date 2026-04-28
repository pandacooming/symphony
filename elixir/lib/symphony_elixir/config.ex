defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  # Agent kind atoms (used in public API)
  @type agent_kind :: :codex | :claude_code | :opencode | :openclaw | :hermes

  # Valid agent kind strings (used in config)
  @agent_kind_strings ["codex", "claude-code", "opencode", "openclaw", "hermes"]

  # Agent kind string to atom mapping
  @kind_string_to_atom %{
    "codex" => :codex,
    "claude-code" => :claude_code,
    "opencode" => :opencode,
    "openclaw" => :openclaw,
    "hermes" => :hermes
  }

  # Default commands for each agent kind
  @default_commands %{
    :codex => "codex app-server",
    :claude_code => "claude --acp --stdio",
    :opencode => "opencode --acp --stdio",
    :openclaw => "openclaw --acp --stdio",
    :hermes => "hermes chat --acp --stdio"
  }

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec agent_kind() :: agent_kind()
  def agent_kind do
    settings = settings!()
    kind_str = settings.agent.kind || "codex"

    case Map.get(@kind_string_to_atom, kind_str) do
      nil ->
        raise ArgumentError,
          message: "Unknown agent kind: #{inspect(kind_str)}. Valid kinds are: #{Enum.join(@agent_kind_strings, ", ")}"

      atom ->
        atom
    end
  end

  @spec agent_kind_string() :: String.t()
  def agent_kind_string do
    settings = settings!()
    settings.agent.kind || "codex"
  end

  @spec claude_code_config() :: %{
          command: String.t(),
          model: String.t() | nil,
          provider: String.t() | nil,
          api_key: String.t() | nil,
          endpoint: String.t() | nil,
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_timeout_ms: pos_integer(),
          read_timeout_ms: pos_integer(),
          stall_timeout_ms: non_neg_integer()
        }
  def claude_code_config do
    settings = settings!()
    agent = settings.agent

    %{
      command: agent.command || Map.get(@default_commands, :claude_code),
      model: agent.model,
      provider: agent.provider,
      api_key: nil,
      endpoint: nil,
      approval_policy: agent.approval_policy,
      thread_sandbox: agent.thread_sandbox || "workspace-write",
      turn_timeout_ms: agent.turn_timeout_ms || 3_600_000,
      read_timeout_ms: agent.read_timeout_ms || 5_000,
      stall_timeout_ms: agent.stall_timeout_ms || 300_000
    }
  end

  @spec opencode_config() :: %{
          command: String.t(),
          model: String.t() | nil,
          provider: String.t() | nil,
          api_key: String.t() | nil,
          endpoint: String.t() | nil,
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_timeout_ms: pos_integer(),
          read_timeout_ms: pos_integer(),
          stall_timeout_ms: non_neg_integer()
        }
  def opencode_config do
    settings = settings!()
    agent = settings.agent

    %{
      command: agent.command || Map.get(@default_commands, :opencode),
      model: agent.model,
      provider: agent.provider,
      api_key: nil,
      endpoint: nil,
      approval_policy: agent.approval_policy,
      thread_sandbox: agent.thread_sandbox || "workspace-write",
      turn_timeout_ms: agent.turn_timeout_ms || 3_600_000,
      read_timeout_ms: agent.read_timeout_ms || 5_000,
      stall_timeout_ms: agent.stall_timeout_ms || 300_000
    }
  end

  @spec openclaw_config() :: %{
          command: String.t(),
          model: String.t() | nil,
          provider: String.t() | nil,
          api_key: String.t() | nil,
          endpoint: String.t() | nil,
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_timeout_ms: pos_integer(),
          read_timeout_ms: pos_integer(),
          stall_timeout_ms: non_neg_integer()
        }
  def openclaw_config do
    settings = settings!()
    agent = settings.agent

    %{
      command: agent.command || Map.get(@default_commands, :openclaw),
      model: agent.model,
      provider: agent.provider,
      api_key: nil,
      endpoint: nil,
      approval_policy: agent.approval_policy,
      thread_sandbox: agent.thread_sandbox || "workspace-write",
      turn_timeout_ms: agent.turn_timeout_ms || 3_600_000,
      read_timeout_ms: agent.read_timeout_ms || 5_000,
      stall_timeout_ms: agent.stall_timeout_ms || 300_000
    }
  end

  @spec hermes_config() :: %{
          command: String.t(),
          model: String.t() | nil,
          provider: String.t() | nil,
          api_key: String.t() | nil,
          endpoint: String.t() | nil,
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_timeout_ms: pos_integer(),
          read_timeout_ms: pos_integer(),
          stall_timeout_ms: non_neg_integer()
        }
  def hermes_config do
    settings = settings!()
    agent = settings.agent

    %{
      command: agent.command || Map.get(@default_commands, :hermes),
      model: agent.model,
      provider: agent.provider,
      api_key: nil,
      endpoint: nil,
      approval_policy: agent.approval_policy,
      thread_sandbox: agent.thread_sandbox || "workspace-write",
      turn_timeout_ms: agent.turn_timeout_ms || 3_600_000,
      read_timeout_ms: agent.read_timeout_ms || 5_000,
      stall_timeout_ms: agent.stall_timeout_ms || 300_000
    }
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: settings.codex.thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  defp validate_semantics(settings) do
    cond do
      is_nil(settings.tracker.kind) ->
        {:error, :missing_tracker_kind}

      settings.tracker.kind not in ["linear", "memory"] ->
        {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.api_key) ->
        {:error, :missing_linear_api_token}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        :ok
    end
  end

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
