defmodule SymphonyElixir.AgentRunner.OpencodeRunner do
  @moduledoc """
  AgentRunner implementation for Aliyun Bailian OpenCode using the ACP protocol.

  Wraps the OpenCode session and emits typed events for the orchestrator:
  - `turn_start` / `turn_end` for each OpenCode turn
  - `tool_call` / `tool_result` for each tool invocation
  - `error` for failures
  - `stall` when the agent blocks on input or approval

  Token usage is accumulated across all turns and surfaced in the final `:done` event.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.AgentRunner.Behavior
  alias SymphonyElixir.Config

  @behaviour Behavior

  @default_max_turns 10
  @default_stall_timeout_ms 120_000

  @impl Behavior
  def start_link(workspace_path, prompt, config) do
    GenServer.start_link(__MODULE__, {workspace_path, prompt, config})
  end

  @impl Behavior
  def stop(runner) do
    GenServer.stop(runner, :normal, 30_000)
  end

  @impl Behavior
  def stream_events(runner) do
    Stream.resource(
      fn -> :acquire end,
      fn
        :acquire -> drain_events(runner)
        :done -> {:halt, :done}
      end,
      fn _ -> :ok end
    )
  end

  @impl Behavior
  def token_counts(runner) do
    GenServer.call(runner, :token_counts)
  end

  @impl Behavior
  def workspace_path(runner) do
    GenServer.call(runner, :workspace_path)
  end

  @impl true
  def init({workspace_path, prompt, config}) do
    opencode_cfg = Config.opencode_config()

    max_turns = Map.get(config, :max_turns, @default_max_turns)
    stall_timeout_ms = Map.get(config, :stall_timeout_ms, @default_stall_timeout_ms)
    issue = Map.get(config, :issue, %{id: "runner", identifier: "runner", title: "OpenCode Runner"})

    state = %{
      workspace_path: workspace_path,
      prompt: prompt,
      issue: issue,
      config: config,
      opencode_config: opencode_cfg,
      max_turns: max_turns,
      stall_timeout_ms: stall_timeout_ms,
      event_queue: [],
      token_counts: %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
      turns_completed: 0,
      status: :initializing,
      port: nil,
      session_id: nil
    }

    {:ok, state, {:continue, :start_session}}
  end

  @impl true
  def handle_continue(:start_session, state) do
    case start_opencode_session(state) do
      {:ok, port, session_id} ->
        new_state = %{state | port: port, session_id: session_id, status: :running}

        emit_event(new_state, :turn_start, %{turn_number: 1, session_id: session_id})

        {:noreply, run_turn(new_state, 1)}

      {:error, reason} ->
        emit_event(state, :error, %{phase: :session_start, reason: reason})
        {:stop, {:session_start_failed, reason}, state}
    end
  end

  @impl true
  def handle_call(:token_counts, _from, state) do
    {:reply, state.token_counts, state}
  end

  @impl true
  def handle_call(:workspace_path, _from, state) do
    {:reply, state.workspace_path, state}
  end

  @impl true
  def handle_call(:take_events, _from, state) do
    events = Enum.reverse(state.event_queue)
    {:reply, events, %{state | event_queue: []}}
  end

  @impl true
  def handle_info({:opencode_message, message}, state) do
    new_state = process_message(message, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(
        {:stall_check, turn_number},
        %{turns_completed: turn_number, status: :running} = state
      ) do
    emit_event(state, :stall, %{turn_number: turn_number, reason: :turn_timeout})
    {:noreply, state}
  end

  @impl true
  def handle_info({:stall_check, _turn_number}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    emit_event(state, :error, %{phase: :process_exit, reason: {:exit_status, status}})
    {:stop, {:process_exited, status}, state}
  end

  defp start_opencode_session(state) do
    workspace = state.workspace_path
    opencode_cfg = state.opencode_config

    # Build environment with API key if provided
    env = build_opencode_env(opencode_cfg)

    # Build command arguments
    cmd_args = build_opencode_args(opencode_cfg)

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(System.find_executable("bash"))},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [~c"-lc", "cd #{shell_escape(workspace)} && exec #{shell_escape(cmd_args)}"],
          env: env,
          cd: String.to_charlist(workspace),
          line: 1_048_576
        ]
      )

    # Wait for session initialization
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode(to_string(line)) do
          {:ok, %{"method" => "session/started", "params" => params}} ->
            session_id = params["sessionId"] || "opencode-#{:rand.uniform(999_999)}"
            # Send initialized acknowledgment
            send_message(port, %{"method" => "initialized", "params" => %{}})
            {:ok, port, session_id}

          {:ok, payload} ->
            # Check for other session started formats
            session_id = extract_session_id(payload) || "opencode-#{:rand.uniform(999_999)}"
            {:ok, port, session_id}

          {:error, _} ->
            # Non-JSON response might mean ready to proceed
            {:ok, port, "opencode-#{:rand.uniform(999_999)}"}
        end

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      30_000 ->
        Port.close(port)
        {:error, :session_start_timeout}
    end
  end

  defp build_opencode_env(opencode_cfg) do
    env_list = [
      {"OPENCODE_API_KEY", to_charlist(opencode_cfg.api_key || "")},
      {"OPENCODE_MODEL", to_charlist(opencode_cfg.model || "")},
      {"OPENCODE_ENDPOINT", to_charlist(opencode_cfg.endpoint || "")}
    ]

    # Filter out empty values and convert to charlist pairs
    env_list
    |> Enum.filter(fn {_, v} -> v != [] and v != '' end)
    |> Enum.map(fn {k, v} -> {String.to_charlist(k), v} end)
  end

  defp build_opencode_args(opencode_cfg) do
    opencode_cfg.command
  end

  defp run_turn(state, turn_number) when turn_number <= state.max_turns do
    stall_timer = Process.send_after(self(), {:stall_check, turn_number}, state.stall_timeout_ms)

    case execute_turn(state, turn_number) do
      {:ok, turn_result} ->
        cancel_timer(stall_timer)

        new_token_counts = accumulate_token_counts(state.token_counts, turn_result)
        new_state = %{state | token_counts: new_token_counts, turns_completed: turn_number}

        emit_event(new_state, :turn_end, %{
          turn_number: turn_number,
          session_id: turn_result.session_id
        })

        if turn_number < state.max_turns do
          continuation_prompt = build_continuation_prompt(turn_number, state.max_turns)

          emit_event(new_state, :turn_start, %{
            turn_number: turn_number + 1,
            session_id: turn_result.session_id
          })

          run_turn(%{new_state | prompt: continuation_prompt}, turn_number + 1)
        else
          emit_done(new_state)
          stop_opencode_session(new_state)
          %{new_state | status: :done}
        end

      {:error, reason} ->
        cancel_timer(stall_timer)
        emit_event(state, :error, %{turn_number: turn_number, reason: reason})
        stop_opencode_session(state)
        %{state | status: {:error, reason}}
    end
  end

  defp run_turn(state, turn_number) when turn_number > state.max_turns do
    emit_done(state)
    stop_opencode_session(state)
    %{state | status: :done}
  end

  defp execute_turn(state, turn_number) do
    port = state.port

    # Send turn/start request
    turn_request = %{
      "method" => "turn/start",
      "id" => turn_number,
      "params" => %{
        "threadId" => state.session_id,
        "input" => [
          %{
            "type" => "text",
            "text" => state.prompt
          }
        ],
        "cwd" => state.workspace_path,
        "title" => "#{state.issue.identifier}: #{state.issue.title}"
      }
    }

    send_message(port, turn_request)

    # Await turn completion
    await_turn_completion(port, turn_number)
  end

  defp await_turn_completion(port, turn_id) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode(to_string(line)) do
          {:ok, %{"method" => "turn/completed", "params" => params}} ->
            {:ok,
             %{
               session_id: params["sessionId"] || "opencode",
               turn_id: turn_id,
               result: params
             }}

          {:ok, %{"method" => "turn/failed", "params" => params}} ->
            {:error, {:turn_failed, params}}

          {:ok, %{"method" => "tool/call", "params" => params}} = payload ->
            # Emit tool call event
            send(self(), {:opencode_message, payload})
            await_turn_completion(port, turn_id)

          {:ok, %{"method" => "tool/result", "params" => params}} = payload ->
            send(self(), {:opencode_message, payload})
            await_turn_completion(port, turn_id)

          {:ok, %{"method" => "approval_required", "params" => _} = payload} ->
            send(self(), {:opencode_message, payload})
            {:error, {:approval_required, payload}}

          {:ok, %{"method" => "input_required", "params" => _} = payload} ->
            send(self(), {:opencode_message, payload})
            {:error, {:input_required, payload}}

          {:ok, payload} ->
            send(self(), {:opencode_message, %{payload: payload}})
            await_turn_completion(port, turn_id)

          {:error, _} ->
            await_turn_completion(port, turn_id)
        end

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      3_600_000 ->
        {:error, :turn_timeout}
    end
  end

  defp drain_events(runner) do
    case GenServer.call(runner, :take_events, 100) do
      [] -> {:halt, :done}
      events -> {events, :acquire}
    end
  end

  defp process_message(%{payload: payload} = msg, state) do
    method = payload["method"]

    case method do
      "tool/call" ->
        tool_name = get_in(payload, ["params", "tool"]) || get_in(payload, ["params", "name"])
        arguments = get_in(payload, ["params", "arguments"]) || %{}
        emit_event(state, :tool_call, %{tool_name: tool_name, arguments: arguments})
        state

      "tool/result" ->
        tool_name = get_in(payload, ["params", "tool"]) || get_in(payload, ["params", "name"])
        success = payload["params"]["success"] != false
        output = payload["params"]["output"] || inspect(payload)
        emit_event(state, :tool_result, %{tool_name: tool_name, success: success, output: output})
        state

      "approval_required" ->
        emit_event(state, :stall, %{
          reason: :approval_required,
          payload: payload["params"]
        })

        state

      "input_required" ->
        emit_event(state, :stall, %{
          reason: :input_required,
          payload: payload["params"]
        })

        state

      "session/started" ->
        emit_event(state, :session_started, payload["params"] || %{})
        state

      _ ->
        Logger.debug("OpencodeRunner received: #{inspect(method)}")
        state
    end
  end

  defp process_message(msg, state) do
    Logger.debug("OpencodeRunner received unexpected message: #{inspect(msg)}")
    state
  end

  defp emit_event(state, event_type, data) do
    event = {:event, event_type, Map.put(data, :timestamp, DateTime.utc_now())}
    put_event(state, event)
  end

  defp emit_done(state) do
    done_event = {:done, state.turns_completed, %{token_counts: state.token_counts}}
    put_event(state, done_event)
  end

  defp put_event(state, event) do
    %{state | event_queue: [event | state.event_queue]}
  end

  defp stop_opencode_session(state) do
    if state.port && is_port(state.port) do
      Port.close(state.port)
    end
  rescue
    _ -> :ok
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    Process.cancel_timer(timer)
  rescue
    _ -> :ok
  end

  defp accumulate_token_counts(existing, _turn_result) do
    # Token accumulation will be implemented when OpenCode returns usage data
    existing
  end

  defp build_continuation_prompt(turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous OpenCode turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp send_message(port, payload) do
    message = Jason.encode!(payload) <> "\n"
    Port.command(port, message)
  end

  defp shell_escape(s) do
    "'" <> String.replace(s, "'", "'\\''") <> "'"
  end

  defp extract_session_id(payload) do
    with %{"sessionId" => id} <- payload do
      id
    else
      _ ->
        with %{"params" => %{"sessionId" => id}} <- payload do
          id
        else
          _ -> nil
        end
    end
  end

  @spec format_token_report(Behavior.token_counts()) :: String.t()
  def format_token_report(%{input_tokens: i, output_tokens: o, total_tokens: t}) do
    "tokens: #{t} total (#{i} in / #{o} out)"
  end
end
