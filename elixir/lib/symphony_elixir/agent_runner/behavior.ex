defmodule SymphonyElixir.AgentRunner.Behavior do
  @moduledoc """
  Behaviour for running agent coding sessions with event streaming and token tracking.

  Implement this behaviour to integrate any agent (Codex, Claude Code, etc.)
  with the Symphony orchestration layer. Each runner:
  - Starts a GenServer-managed session in a workspace
  - Streams events (turn_start, turn_end, tool_call, tool_result, error, stall)
  - Tracks token usage
  - Provides a clean stop API
  """

  @type agent_event :: {:event, atom(), map()} | {:done, non_neg_integer(), map()}
  @type token_counts :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer()
        }
  @type runner_config :: map()

  @doc """
  Start a new agent runner GenServer linked to the current process.

  - `workspace_path` - absolute path to the per-issue workspace
  - `prompt` - the initial prompt to send to the agent
  - `config` - runner-specific configuration (agent kind, max_turns, etc.)

  Returns `{:ok, pid}` on success or `{:error, reason}`.
  """
  @callback start_link(
              workspace_path :: String.t(),
              prompt :: String.t(),
              config :: runner_config()
            ) ::
              GenServer.on_start()

  @doc """
  Stop a running agent runner gracefully.
  Waits for any in-flight turns to complete before cleanup.
  """
  @callback stop(runner :: pid()) :: :ok

  @doc """
  Stream events from the runner as an Enumerable.

  Each event is either:
  - `{:event, event_type :: atom(), event_data :: map()}` for in-progress events
  - `{:done, turn_count :: non_neg_integer(), final_stats :: map()}` when complete

  Event types include: `turn_start`, `turn_end`, `tool_call`, `tool_result`, `error`, `stall`
  """
  @callback stream_events(runner :: pid()) :: Enumerable.t()

  @doc """
  Return the current accumulated token counts for this runner session.
  """
  @callback token_counts(runner :: pid()) :: token_counts()

  @doc """
  Return the workspace path for this runner session.
  """
  @callback workspace_path(runner :: pid()) :: String.t()

  @doc """
  Macro to inject common helper functions into implementing modules.
  """
  defmacro __using__(_opts) do
    quote do
      @doc """
      Format a token report string from token counts map.
      """
      @spec format_token_report(AgentRunner.Behavior.token_counts()) :: String.t()
      def format_token_report(%{input_tokens: i, output_tokens: o, total_tokens: t}) do
        "tokens: #{t} total (#{i} in / #{o} out)"
      end

      defoverridable format_token_report: 1
    end
  end
end
