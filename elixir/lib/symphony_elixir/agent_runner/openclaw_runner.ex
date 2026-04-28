defmodule SymphonyElixir.AgentRunner.OpenClawRunner do
  @moduledoc """
  AgentRunner implementation for OpenClaw using the ACP protocol over stdio.

  Wraps the OpenClaw session and emits typed events for the orchestrator:
  - `turn_start` / `turn_end` for each OpenClaw turn
  - `tool_call` / `tool_result` for each tool invocation
  - `error` for failures
  - `stall` when the agent blocks on input or approval

  Token usage is accumulated across all turns and surfaced in the final `:done` event.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.AgentRunner.Behavior

  @behaviour Behavior

  @default_max_turns 10
  @default_stall_timeout_ms 120_000
  @default_turn_timeout_ms 3_600_000
  @default_read_timeout_ms 5_000
  @port_line_bytes 1_048_576
  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3

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
    max_turns = Map.get(config, :max_turns, @default_max_turns)
    stall_timeout_ms = Map.get(config, :stall_timeout_ms, @default_stall_timeout_ms)
    issue = Map.get(config, :issue, %{id: "runner", identifier: "runner", title: "OpenClaw Runner"})
    openclaw_config = Map.get(config, :openclaw_config, %{})

    state = %{
      workspace_path: workspace_path,
      prompt: prompt,
      issue: issue,
      config: config,
      openclaw_config: openclaw_config,
      max_turns: max_turns,
      stall_timeout_ms: stall_timeout_ms,
      event_queue: [],
      token_counts: %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
      turns_completed: 0,
      status: :initializing,
      port: nil,
      thread_id: nil,
      session_metadata: %{}
    }

    {:ok, state, {:continue, :check_binary}}
  end

  @impl true
  def handle_continue(:check_binary, state) do
    case find_openclaw_binary() do
      {:ok, binary_path} ->
        Logger.info("OpenClaw binary found at: #{binary_path}")
        {:noreply, %{state | openclaw_binary: binary_path}, {:continue, :start_session}}

      {:error, :not_found} ->
        emit_event(state, :error, %{
          phase: :binary_check,
          reason: :openclaw_not_found,
          message: "OpenClaw binary 'openclaw' not found. Is it installed and in PATH?"
        })

        {:stop, {:binary_not_found, "openclaw not found"}, state}
    end
  end

  @impl true
  def handle_continue(:start_session, state) do
    case start_openclaw_session(state) do
      {:ok, new_state} ->
        {:noreply, new_state}

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
  def handle_info({:openclaw_message, message}, state) do
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
    {:stop, {:port_exit, status}, state}
  end

  defp find_openclaw_binary do
    case System.find_executable("openclaw") do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  defp start_openclaw_session(state) do
    openclaw_cfg = state.openclaw_config
    command = Map.get(openclaw_cfg, :command, "openclaw --acp --stdio")

    port =
      Port.open(
        {:spawn_executable, String.to_charlist("/bin/bash")},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [~c"-lc", String.to_charlist(command)],
          cd: String.to_charlist(state.workspace_path),
          line: @port_line_bytes
        ]
      )

    on_message = fn msg -> send(self(), {:openclaw_message, msg}) end

    case initialize_openclaw(port, on_message) do
      :ok ->
        case start_thread(port, on_message, openclaw_cfg, state.workspace_path) do
          {:ok, thread_id} ->
            emit_event(state, :turn_start, %{turn_number: 1, session_id: thread_id})

            new_state = %{
              state
              | port: port,
                thread_id: thread_id,
                status: :running,
                session_metadata: %{openclaw_pid: port_pid(port)}
            }

            {:ok, run_turn(new_state, 1)}

          {:error, reason} ->
            Port.close(port)
            {:error, reason}
        end

      {:error, reason} ->
        Port.close(port)
        {:error, reason}
    end
  end

  defp port_pid(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} -> to_string(os_pid)
      _ -> nil
    end
  end

  defp initialize_openclaw(port, on_message) do
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

    case await_response(port, @initialize_id, 5000) do
      {:ok, _} ->
        send_message(port, %{"method" => "initialized", "params" => %{}})
        :ok

      {:error, reason} ->
        Logger.error("OpenClaw initialize failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp start_thread(port, on_message, openclaw_cfg, workspace_path) do
    approval_policy = Map.get(openclaw_cfg, :approval_policy, "never")
    thread_sandbox = Map.get(openclaw_cfg, :thread_sandbox, "workspace-write")

    payload = %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" => %{
        "approvalPolicy" => approval_policy,
        "sandbox" => thread_sandbox,
        "cwd" => workspace_path
      }
    }

    send_message(port, payload)

    case await_response(port, @thread_start_id, 10000) do
      {:ok, %{"thread" => thread_payload}} ->
        case thread_payload do
          %{"id" => thread_id} -> {:ok, thread_id}
          _ -> {:error, {:invalid_thread_payload, thread_payload}}
        end

      other ->
        other
    end
  end

  defp run_turn(state, turn_number) when turn_number <= state.max_turns do
    port = state.port
    on_message = fn msg -> send(self(), {:openclaw_message, msg}) end

    stall_timer = Process.send_after(self(), {:stall_check, turn_number}, state.stall_timeout_ms)

    case start_turn(port, state.thread_id, state.prompt, state.issue, state.openclaw_config, on_message) do
      {:ok, turn_id} ->
        session_id = "#{state.thread_id}-#{turn_id}"

        case await_turn_completion(port, on_message) do
          {:ok, _result} ->
            cancel_timer(stall_timer)

            new_state = %{state | turns_completed: turn_number}

            emit_event(new_state, :turn_end, %{
              turn_number: turn_number,
              session_id: session_id
            })

            if turn_number < state.max_turns do
              continuation_prompt = build_continuation_prompt(turn_number, state.max_turns)

              emit_event(new_state, :turn_start, %{
                turn_number: turn_number + 1,
                session_id: session_id
              })

              run_turn(%{new_state | prompt: continuation_prompt}, turn_number + 1)
            else
              emit_done(new_state)
              stop_port(port)
              %{new_state | status: :done}
            end

          {:error, reason} ->
            cancel_timer(stall_timer)
            emit_event(state, :error, %{turn_number: turn_number, reason: reason})
            stop_port(port)
            %{state | status: {:error, reason}}
        end

      {:error, reason} ->
        cancel_timer(stall_timer)
        emit_event(state, :error, %{turn_number: turn_number, reason: reason})
        stop_port(port)
        %{state | status: {:error, reason}}
    end
  end

  defp run_turn(state, turn_number) when turn_number > state.max_turns do
    emit_done(state)
    stop_port(state.port)
    %{state | status: :done}
  end

  defp start_turn(port, thread_id, prompt, issue, _openclaw_config, on_message) do
    payload = %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" => %{
        "threadId" => thread_id,
        "input" => [
          %{
            "type" => "text",
            "text" => prompt
          }
        ],
        "cwd" => "/tmp",
        "title" => "#{issue.identifier}: #{issue.title}"
      }
    }

    send_message(port, payload)

    case await_response(port, @turn_start_id, 30000) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end

  defp await_turn_completion(port, on_message) do
    receive_loop(port, on_message, @default_turn_timeout_ms, "")
  end

  defp receive_loop(port, on_message, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_incoming(port, on_message, complete_line, timeout_ms, "")

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(
          port,
          on_message,
          timeout_ms,
          pending_line <> to_string(chunk)
        )

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_incoming(port, on_message, data, timeout_ms, pending_line) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, %{"method" => "turn/completed"} = payload} ->
        emit_turn_event(on_message, :turn_completed, payload, payload_string)
        {:ok, :turn_completed}

      {:ok, %{"method" => "turn/failed", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_failed,
          payload,
          payload_string
        )

        {:error, {:turn_failed, Map.get(payload, "params")}}

      {:ok, %{"method" => "turn/cancelled", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_cancelled,
          payload,
          payload_string
        )

        {:error, {:turn_cancelled, Map.get(payload, "params")}}

      {:ok, %{"method" => method} = payload} when is_binary(method) ->
        handle_turn_method(port, on_message, payload, payload_string, timeout_ms)

      {:ok, payload} ->
        emit_message(
          on_message,
          :other_message,
          %{
            payload: payload,
            raw: payload_string
          }
        )

        receive_loop(port, on_message, timeout_ms, "")

      {:error, _reason} ->
        Logger.debug("OpenClaw non-JSON output: #{String.slice(payload_string, 0, 200)}")
        receive_loop(port, on_message, timeout_ms, "")
    end
  end

  defp handle_turn_method(port, on_message, payload, payload_string, timeout_ms) do
    method = Map.get(payload, "method")

    case method do
      "item/tool/call" ->
        handle_tool_call(port, on_message, payload, payload_string)
        receive_loop(port, on_message, timeout_ms, "")

      "item/commandExecution/requestApproval" ->
        handle_approval_request(port, on_message, payload, payload_string, "acceptForSession")
        receive_loop(port, on_message, timeout_ms, "")

      "execCommandApproval" ->
        handle_approval_request(port, on_message, payload, payload_string, "approved_for_session")
        receive_loop(port, on_message, timeout_ms, "")

      "applyPatchApproval" ->
        handle_approval_request(port, on_message, payload, payload_string, "approved_for_session")
        receive_loop(port, on_message, timeout_ms, "")

      "item/fileChange/requestApproval" ->
        handle_approval_request(port, on_message, payload, payload_string, "acceptForSession")
        receive_loop(port, on_message, timeout_ms, "")

      "item/tool/requestUserInput" ->
        handle_tool_input_request(port, on_message, payload, payload_string)
        receive_loop(port, on_message, timeout_ms, "")

      "turn/input_required" ->
        emit_message(on_message, :turn_input_required, %{payload: payload, raw: payload_string})
        {:error, {:turn_input_required, payload}}

      "turn/needs_input" ->
        emit_message(on_message, :stall, %{reason: :input_required, payload: payload})
        {:error, {:input_required, payload}}

      _ ->
        emit_message(on_message, :notification, %{
          payload: payload,
          raw: payload_string
        })

        Logger.debug("OpenClaw notification: #{inspect(method)}")
        receive_loop(port, on_message, timeout_ms, "")
    end
  end

  defp handle_tool_call(port, on_message, payload, payload_string) do
    params = Map.get(payload, "params", %{})
    tool_name = Map.get(params, "tool") || Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{})

    emit_message(on_message, :tool_call, %{
      tool_name: tool_name,
      arguments: arguments,
      payload: payload,
      raw: payload_string
    })
  end

  defp handle_approval_request(port, on_message, payload, payload_string, decision) do
    id = Map.get(payload, "id")

    send_message(port, %{"id" => id, "result" => %{"decision" => decision}})

    emit_message(on_message, :approval_auto_approved, %{
      payload: payload,
      raw: payload_string,
      decision: decision
    })
  end

  defp handle_tool_input_request(port, on_message, payload, payload_string) do
    id = Map.get(payload, "id")
    params = Map.get(payload, "params", %{})

    # Auto-answer with non-interactive response
    answers = %{}

    send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

    emit_message(on_message, :tool_input_auto_answered, %{
      payload: payload,
      raw: payload_string
    })
  end

  defp emit_turn_event(on_message, event, payload, payload_string) do
    emit_message(on_message, event, %{
      payload: payload,
      raw: payload_string
    })
  end

  defp drain_events(runner) do
    case GenServer.call(runner, :take_events, 100) do
      [] -> {:halt, :done}
      events -> {events, :acquire}
    end
  end

  defp process_message(%{event: :session_started} = msg, state) do
    emit_event(state, :session_started, Map.drop(msg, [:event, :timestamp]))
    state
  end

  defp process_message(%{event: :turn_completed} = msg, state) do
    emit_event(state, :turn_completed, Map.drop(msg, [:event, :timestamp]))
    state
  end

  defp process_message(%{event: :turn_failed} = msg, state) do
    emit_event(state, :turn_failed, Map.drop(msg, [:event, :timestamp]))
    state
  end

  defp process_message(%{event: :tool_call} = msg, state) do
    tool_name = Map.get(msg, :tool_name)
    arguments = Map.get(msg, :arguments, %{})

    emit_event(state, :tool_call, %{
      tool_name: tool_name,
      arguments: arguments
    })

    state
  end

  defp process_message(%{event: :tool_call_completed} = msg, state) do
    emit_event(state, :tool_call, %{
      tool_name: Map.get(msg, :tool_name),
      arguments: Map.get(msg, :arguments, %{})
    })

    state
  end

  defp process_message(%{event: :tool_call_failed} = msg, state) do
    emit_event(state, :tool_result, %{
      tool_name: Map.get(msg, :tool_name),
      success: false,
      output: inspect(msg)
    })

    state
  end

  defp process_message(%{event: :approval_required} = msg, state) do
    emit_event(state, :stall, %{
      reason: :approval_required,
      payload: Map.get(msg, :payload)
    })

    state
  end

  defp process_message(%{event: :turn_input_required} = msg, state) do
    emit_event(state, :stall, %{
      reason: :input_required,
      payload: Map.get(msg, :payload)
    })

    state
  end

  defp process_message(%{event: :approval_auto_approved} = msg, state) do
    emit_event(state, :approval_auto_approved, Map.drop(msg, [:event, :timestamp]))
    state
  end

  defp process_message(%{event: :turn_ended_with_error} = msg, state) do
    emit_event(state, :error, Map.drop(msg, [:event, :timestamp]))
    state
  end

  defp process_message(%{event: :startup_failed} = msg, state) do
    emit_event(state, :error, Map.drop(msg, [:event, :timestamp]))
    state
  end

  defp process_message(%{event: :notification} = msg, state) do
    Logger.debug("OpenClawRunner received notification: #{inspect(msg)}")
    state
  end

  defp process_message(%{event: :other_message} = msg, state) do
    Logger.debug("OpenClawRunner received other message: #{inspect(msg)}")
    state
  end

  defp process_message(msg, state) do
    Logger.debug("OpenClawRunner received unexpected message: #{inspect(msg)}")
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

  defp stop_port(nil), do: :ok

  defp stop_port(port) when is_port(port) do
    try do
      Port.close(port)
      :ok
    rescue
      _ -> :ok
    end
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    Process.cancel_timer(timer)
  rescue
    _ -> :ok
  end

  defp await_response(port, request_id, timeout_ms) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        handle_response(port, request_id, to_string(chunk), timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        await_response_cont(port, request_id, to_string(chunk), timeout_ms)

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp await_response_cont(port, request_id, pending, timeout_ms) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        handle_response(port, request_id, pending <> to_string(chunk), timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        await_response_cont(port, request_id, pending <> to_string(chunk), timeout_ms)

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, data, timeout_ms) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{} = other} ->
        Logger.debug("Ignoring message while waiting for response: #{inspect(other)}")
        await_response(port, request_id, timeout_ms)

      {:error, _} ->
        Logger.debug("OpenClaw non-JSON response: #{String.slice(payload, 0, 200)}")
        await_response(port, request_id, timeout_ms)
    end
  end

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  defp build_continuation_prompt(turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous OpenClaw turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp emit_message(on_message, event, details) when is_function(on_message, 1) do
    message = details |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  @spec format_token_report(Behavior.token_counts()) :: String.t()
  def format_token_report(%{input_tokens: i, output_tokens: o, total_tokens: t}) do
    "tokens: #{t} total (#{i} in / #{o} out)"
  end
end
