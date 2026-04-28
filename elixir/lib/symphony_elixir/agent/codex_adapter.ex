defmodule SymphonyElixir.Agent.CodexAdapter do
  @moduledoc """
  Adapter for OpenAI Codex (app-server mode).

  Codex communicates over JSON-RPC 2.0 via stdio using the app-server protocol.
  This adapter wraps the existing AppServer module.
  """
  @behaviour SymphonyElixir.Agent.Protocol

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Linear.Issue}

  @impl true
  def kind, do: "codex"

  @impl true
  def description, do: "OpenAI Codex (app-server mode)"

  @impl true
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    AppServer.start_session(workspace, worker_host: worker_host)
  end

  @impl true
  def run_turn(session, prompt, %Issue{} = issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    AppServer.run_turn(session, prompt, issue, on_message: on_message)
  end

  @impl true
  def stop_session(session) do
    AppServer.stop_session(session)
  end

  defp default_on_message(_msg), do: :ok
end
