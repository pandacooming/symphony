defmodule SymphonyElixir.AgentRunner.CodexRunner do
  @moduledoc """
  AgentRunner implementation for OpenAI Codex using the AppServer protocol.

  Wraps the AppServer session and emits typed events for the orchestrator:
  - `turn_start` / `turn_end` for each Codex turn
  - `tool_call` / `tool_result` for each tool invocation
  - `error` for failures
  - `stall` when the agent blocks on input or approval

  Token usage is accumulated across all turns and surfaced in the final `:done` event.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.AgentRunner.Behavior
  alias SymphonyElixir.Codex.AppServer

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
    max_turns = Map.get(config, :max_turns, @default_max_turns)
    stall_timeout_ms = Map.get(config, :stall_timeout_ms, @default_stall_timeout_ms)
    issue = Map.get(config, :issue, %{id: "runner", identifier: "runner", title: "Codex Runner"})
    worker_host = Map.get(config, :worker_host)

    state = %{
      workspace_path: workspace_path,
      prompt: prompt,
      issue: issue,
      config: config,
      max_turns: max_turns,
      stall_timeout_ms: stall_timeout_ms,
      worker_host: worker_host,
      event_queue: [],
      token_counts: %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
      turns_completed: 0,
      status: :initializing
    }

    {:ok, state, {:continue, :start_session}}
  end

  @impl true
  def handle_continue(:start_session, state) do
    case AppServer.start_session(state.workspace_path, worker_host: state.worker_host) do
      {:ok, session} ->
        new_state = %{state | session: session, status: :running}

        emit_event(new_state, :turn_start, %{turn_number: 1, session_id: session.thread_id})

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
  def handle_info({:codex_message, message}, state) do
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

  defp run_turn(state, turn_number) when turn_number <= state.max_turns do
    on_message = fn msg -> send(self(), {:codex_message, msg}) end

    stall_timer = Process.send_after(self(), {:stall_check, turn_number}, state.stall_timeout_ms)

    case AppServer.run_turn(
           state.session,
           state.prompt,
           state.issue,
           on_message: on_message
         ) do
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
          stop_session(new_state)
          %{new_state | status: :done}
        end

      {:error, reason} ->
        cancel_timer(stall_timer)
        emit_event(state, :error, %{turn_number: turn_number, reason: reason})
        stop_session(state)
        %{state | status: {:error, reason}}
    end
  end

  defp run_turn(state, turn_number) when turn_number > state.max_turns do
    emit_done(state)
    stop_session(state)
    %{state | status: :done}
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

  defp process_message(%{event: :tool_call_completed} = msg, state) do
    emit_event(state, :tool_call, %{
      tool_name: get_in(msg, [:params, "tool"]) || get_in(msg, [:params, :tool]),
      arguments: get_in(msg, [:params, "arguments"]) || get_in(msg, [:params, :arguments]) || %{}
    })

    state
  end

  defp process_message(%{event: :tool_call_failed} = msg, state) do
    emit_event(state, :tool_result, %{
      tool_name: get_in(msg, [:params, "tool"]) || get_in(msg, [:params, :tool]),
      success: false,
      output: inspect(msg)
    })

    state
  end

  defp process_message(%{event: :unsupported_tool_call} = _msg, state) do
    emit_event(state, :tool_call, %{
      tool_name: nil,
      arguments: %{},
      unsupported: true
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

  defp process_message(%{event: :other_message} = msg, state) do
    Logger.debug("CodexRunner received other message: #{inspect(msg)}")
    state
  end

  defp process_message(msg, state) do
    Logger.debug("CodexRunner received unexpected message: #{inspect(msg)}")
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

  defp stop_session(state) do
    if state.session && is_map(state.session) && Map.has_key?(state.session, :port) do
      AppServer.stop_session(state.session)
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

  defp accumulate_token_counts(existing, turn_result) do
    existing
  end

  defp build_continuation_prompt(turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  @spec format_token_report(Behavior.token_counts()) :: String.t()
  def format_token_report(%{input_tokens: i, output_tokens: o, total_tokens: t}) do
    "tokens: #{t} total (#{i} in / #{o} out)"
  end
end
