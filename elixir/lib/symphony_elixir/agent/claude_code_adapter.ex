defmodule SymphonyElixir.Agent.ClaudeCodeAdapter do
  @moduledoc """
  Adapter for Claude Code (Anthropic's CLI agent).

  Claude Code supports --acp --stdio mode for programmatic control.
  This adapter uses the ACP protocol over stdio.
  """
  @behaviour SymphonyElixir.Agent.Protocol

  # Delegates to CLIAdapter for the core ACP protocol implementation
  @delegate_to_cli_adapter true

  @impl true
  def kind, do: "claude-code"

  @impl true
  def description, do: "Claude Code (Anthropic)"

  @impl true
  def start_session(workspace, opts \\ []) do
    SymphonyElixir.Agent.CLIAdapter.start_session(workspace, opts)
  end

  @impl true
  def run_turn(session, prompt, issue, opts \\ []) do
    SymphonyElixir.Agent.CLIAdapter.run_turn(session, prompt, issue, opts)
  end

  @impl true
  def stop_session(session) do
    SymphonyElixir.Agent.CLIAdapter.stop_session(session)
  end
end
