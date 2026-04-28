defmodule SymphonyElixir.Agent.CLIAdapter do
  @moduledoc """
  Adapter for CLI-based coding agents using the Agent Coding Protocol (ACP).

  Supports:
  - Claude Code (claude-code): Anthropic's CLI agent
  - OpenCode (opencode): Aliyun Bailian CLI agent
  - OpenClaw (openclaw): OpenClaw CLI agent
  - Hermes Agent (hermes): Hermes CLI agent

  These agents all communicate via --acp --stdio mode, accepting JSON-RPC 2.0
  messages over stdio with the same message shape as Codex app-server.
  """
  @behaviour SymphonyElixir.Agent.Protocol

  require Logger

  alias SymphonyElixir.Linear.Issue

  # ACP JSON-RPC message IDs
  @initialize_id 1
  @session_start_id 2
  @turn_start_id 3
  @port_line_bytes 1_048_576

  @type session :: %{
          port: port(),
          metadata: map(),
          kind: String.t(),
          session_id: String.t() | nil,
          workspace: Path.t(),
          worker_host: String.t() | nil
        }

  # ============================================================
  # Callbacks
  # ============================================================

  @impl true
  def kind, do: kind_from_config()

  @impl true
  def description do
    case kind() do
      "claude-code" -> "Claude Code (Anthropic)"
      "opencode" -> "OpenCode (Aliyun Bailian)"
      "openclaw" -> "OpenClaw"
      "hermes" -> "Hermes Agent"
      other -> "Agent: #{other}"
    end
  end

  @impl true
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    expanded_workspace = Path.expand(workspace)

    config = config_for_kind()

    cmd = build_command(config, expanded_workspace)

    port =
      if is_nil(worker_host) do
        Port.open(
          {:spawn_executable, to_charlist(System.find_executable!("bash"))},
          [:binary, :exit_status, :stderr_to_stdout, args: [~c"-lc", cmd], cd: to_charlist(expanded_workspace), line: @port_line_bytes]
        )
      else
        # SSH-based remote launch (placeholder for remote support)
        raise "Remote worker support for #{kind()} not yet implemented"
      end

    session = %{
      port: port,
      metadata: %{},
      kind: kind(),
      session_id: nil,
      workspace: expanded_workspace,
      worker_host: worker_host
    }

    # Initialize the ACP session
    case initialize_session(port) do
      :ok ->
        {:ok, session}

      {:error, reason} ->
        Port.close(port)
        {:error, reason}
    end
  end

  @impl true
  def run_turn(session, prompt, %Issue{} = issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    turn_timeout = turn_timeout_ms()

    with {:ok, session_id} <- start_turn(session, prompt, issue) do
      session_with_id = %{session | session_id: session_id}
      await_turn_completion(session_with_id, on_message, turn_timeout)
    end
  end

  @impl true
  def stop_session(%{port: port}) do
    Port.close(port)
    :ok
  end

  # ============================================================
  # ACP Session Lifecycle
  # ============================================================

  defp initialize_session(port) do
    payload = %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{
          "experimentalApi" => true
        },
        "clientInfo" => %{
          "name" => "symphony-orchestrator",
          "title" => "Symphony Orchestrator",
          "version" => "0.1.0"
        }
      }
    }

    send_message(port, payload)

    case await_response(port, @initialize_id, 30_000) do
      {:ok, _} ->
        # Send initialized notification
        send_message(port, %{"method" => "initialized", "params" => %{}})
        :ok

      error ->
        error
    end
  end

  defp start_turn(%{port: port, session_id: nil} = session, prompt, issue) do
    thread_id = thread_id_for_session(session)

    # Start a new thread for this turn
    start_thread_payload = %{
      "method" => "thread/start",
      "id" => @session_start_id,
      "params" => %{
        "cwd" => session.workspace,
        "dynamicTools" => []
      }
    }

    send_message(port, start_thread_payload)

    case await_response(port, @session_start_id, 30_000) do
      {:ok, %{"thread" => %{"id" => thread_id}}} ->
        session_id = "#{thread_id}-1"

        # Now start the turn
        turn_payload = %{
          "method" => "turn/start",
          "id" => @turn_start_id,
          "params" => %{
            "threadId" => thread_id,
            "input" => [%{"type" => "text", "text" => prompt}],
            "cwd" => session.workspace,
            "title" => "#{issue.identifier}: #{issue.title}"
          }
        }

        send_message(port, turn_payload)

        case await_response(port, @turn_start_id, 30_000) do
          {:ok, %{"turn" => %{"id" => turn_id}}} ->
            {:ok, "#{thread_id}-#{turn_id}"}

          error ->
            error
        end
    end
  end

  defp start_turn(%{port: port, session_id: session_id} = session, prompt, issue) do
    # Resume existing session - continue the thread
    [thread_id, _turn_num] = String.split(session_id, "-")

    continuation_payload = %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" => %{
        "threadId" => thread_id,
        "input" => [%{"type" => "text", "text" => prompt}],
        "cwd" => session.workspace,
        "title" => "#{issue.identifier}: #{issue.title} (continuation)"
      }
    }

    send_message(port, continuation_payload)

    case await_response(port, @turn_start_id, 30_000) do
      {:ok, %{"turn" => %{"id" => turn_id}}} ->
        {:ok, "#{thread_id}-#{turn_id}"}

      error ->
        error
    end
  end

  defp await_turn_completion(session, on_message, timeout_ms) do
    receive_loop(session, on_message, timeout_ms, "")
  end

  defp receive_loop(%{port: port} = session, on_message, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_incoming(session, on_message, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(session, on_message, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_incoming(session, on_message, data, timeout_ms) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, %{"method" => "turn/completed"}} ->
        emit_message(on_message, :turn_completed, %{}, %{})
        {:ok, %{result: :completed, session_id: session.session_id}}

      {:ok, %{"method" => "turn/failed", "params" => params}} ->
        emit_message(on_message, :turn_failed, params, %{})
        {:error, {:turn_failed, params}}

      {:ok, %{"method" => "turn/cancelled", "params" => params}} ->
        emit_message(on_message, :turn_cancelled, params, %{})
        {:error, {:turn_cancelled, params}}

      {:ok, payload} ->
        emit_message(on_message, :other_message, payload, %{raw: payload_string})
        receive_loop(session, on_message, timeout_ms, "")

      {:error, _} ->
        # Non-JSON line (tool output, etc.) - pass through
        emit_message(on_message, :raw_output, %{raw: payload_string}, %{})
        receive_loop(session, on_message, timeout_ms, "")
    end
  rescue
    e ->
      {:error, {:parse_error, Exception.message(e)}}
  end

  # ============================================================
  # Message Helpers
  # ============================================================

  defp send_message(port, payload) do
    json = Jason.encode!(payload)
    Port.command(port, [json, "\n"])
  end

  defp await_response(port, id, timeout_ms) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        case Jason.decode(to_string(chunk)) do
          {:ok, %{"id" => ^id} = response} -> {:ok, response}
          {:ok, _other} -> await_response(port, id, timeout_ms)
          {:error, _} -> await_response(port, id, timeout_ms)
        end

      {^port, {:data, {:noeol, chunk}}} ->
        await_response(port, id, timeout_ms)
    after
      timeout_ms -> {:error, :timeout}
    end
  end

  defp emit_message(on_message, type, data, metadata) do
    try do
      on_message.(%{type: type, data: data, metadata: metadata})
    rescue
      _ -> :ok
    end
  end

  # ============================================================
  # Config Helpers
  # ============================================================

  defp kind_from_config do
    Config.settings!().agent.kind
  end

  defp config_for_kind do
    settings = Config.settings!()
    settings.agent
  end

  defp turn_timeout_ms do
    settings = Config.settings!()
    settings.agent.turn_timeout_ms || 3_600_000
  end

  defp build_command(config, workspace) do
    kind = config.kind || "codex"
    model = config.model
    provider = config.provider

    case kind do
      "claude-code" ->
        base = "claude --acp --stdio"
        args = acp_args(provider, model, config)
        "#{base} #{args}"

      "opencode" ->
        base = "opencode --acp --stdio"
        args = acp_args(provider, model, config)
        "#{base} #{args}"

      "openclaw" ->
        base = "openclaw --acp --stdio"
        args = acp_args(provider, model, config)
        "#{base} #{args}"

      "hermes" ->
        base = "hermes chat --acp --stdio"
        args = hermes_acp_args(provider, model, config)
        "#{base} #{args}"

      _ ->
        config.command || "codex app-server"
    end
  end

  defp acp_args(nil, nil, _config), do: ""
  defp acp_args(provider, nil, _config), do: "--provider #{provider}"
  defp acp_args(nil, model, _config), do: "--model #{model}"
  defp acp_args(provider, model, _config), do: "--provider #{provider} --model #{model}"

  defp hermes_acp_args(nil, nil, config) do
    # Default: use current hermes config
    ""
  end

  defp hermes_acp_args(provider, model, _config) do
    args = []
    args = if provider, do: ["--provider #{provider}" | args], else: args
    args = if model, do: ["--model #{model}" | args], else: args
    Enum.join(args, " ")
  end

  defp thread_id_for_session(%{session_id: nil}) do
    "symphony-#{:rand.uniform(999_999)}"
  end

  defp thread_id_for_session(%{session_id: session_id}) do
    case String.split(session_id, "-") do
      [thread_id, _] -> thread_id
      _ -> session_id
    end
  end

  defp default_on_message(_msg), do: :ok
end
