defmodule SymphonyElixir.Agent.Protocol do
  @moduledoc """
  Defines the behaviour for Symphony agent adapters.

  Each adapter implements this behaviour to integrate a specific coding agent
  (Codex, Claude Code, OpenCode, OpenClaw, Hermes Agent) with the Symphony
  orchestration layer.

  The adapter is responsible for:
  - Starting a session in a given workspace
  - Running turns (prompt + issue context → agent response)
  - Streaming updates back to the orchestrator
  - Stopping the session cleanly
  """

  alias SymphonyElixir.Linear.Issue

  @type session :: map()
  @type turn_result :: {:ok, %{result: term(), session_id: String.t()}} | {:error, term()}
  @type message :: %{
          type: :session_started | :turn_completed | :turn_failed | :turn_cancelled | :other,
          data: map()
        }

  @doc """
  Start a new agent session in the given workspace.
  Returns {:ok, session} or {:error, reason}.
  """
  @callback start_session(workspace :: Path.t(), opts :: keyword()) ::
              {:ok, session()} | {:error, term()}

  @doc """
  Run a single turn with the agent.
  - session: the session from start_session
  - prompt: the full prompt string to send to the agent
  - issue: the current Issue struct
  Returns {:ok, turn_result} or {:error, reason}.
  """
  @callback run_turn(
              session :: session(),
              prompt :: String.t(),
              issue :: Issue.t(),
              opts :: keyword()
            ) :: turn_result()

  @doc """
  Stop an active session and clean up resources.
  """
  @callback stop_session(session :: session()) :: :ok

  @doc """
  Return the agent kind identifier (atom).
  Used for dispatch and logging.
  """
  @callback kind() :: String.t()

  @doc """
  Return a short one-line description of the agent for logs.
  """
  @callback description() :: String.t()
end
