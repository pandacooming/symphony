defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with the configured agent runner.

  Dispatches to the appropriate runner (CodexRunner, ClaudeCodeRunner, OpencodeRunner,
  OpenclawRunner, or HermesRunner) based on the agent.kind setting from WORKFLOW.md.
  """

  require Logger

  alias SymphonyElixir.AgentRunner.{
    CodexRunner,
    ClaudeCodeRunner,
    OpencodeRunner,
    OpenclawRunner,
    HermesRunner
  }

  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Workspace}

  @type worker_host :: String.t() | nil

  # Runner module mapping from agent_kind() atoms
  @runner_for_kind %{
    codex: CodexRunner,
    claude_code: ClaudeCodeRunner,
    opencode: OpencodeRunner,
    openclaw: OpenclawRunner,
    hermes: HermesRunner
  }

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_with_runner(issue, workspace, recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Dispatches to the correct runner based on agent.kind
  defp run_with_runner(issue, workspace, recipient, opts, worker_host) do
    runner_module = runner_for_agent_kind()
    config = build_runner_config(issue, workspace, opts, worker_host)
    prompt = PromptBuilder.build_prompt(issue, opts)

    run_with_selected_runner(runner_module, workspace, prompt, config, issue, recipient)
  end

  defp run_with_selected_runner(runner_module, workspace, prompt, config, issue, recipient) do
    case runner_module.start_link(workspace, prompt, config) do
      {:ok, runner_pid} ->
        # Monitor the runner for exit events
        ref = Process.monitor(runner_pid)

        # Stream events back to recipient if provided
        stream_events_to_recipient(runner_pid, recipient, issue)

        # Wait for runner to complete
        receive do
          {:DOWN, ^ref, :process, ^runner_pid, reason} ->
            case reason do
              :normal ->
                :ok
              _ ->
                {:error, {:runner_exited, reason}}
            end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stream_events_to_recipient(runner_pid, recipient, issue) when is_pid(recipient) do
    spawn(fn ->
      runner_module = runner_for_agent_kind()

      Enum.each(runner_module.stream_events(runner_pid), fn
        {:event, event_type, data} ->
          send(recipient, {:runner_event, issue.id, event_type, data})

        {:done, turn_count, stats} ->
          send(recipient, {:runner_done, issue.id, turn_count, stats})
      end)
    end)
  end

  defp stream_events_to_recipient(_runner_pid, _recipient, _issue), do: :ok

  defp runner_for_agent_kind do
    kind = Config.agent_kind()
    Map.get(@runner_for_kind, kind) || raise "No runner for agent kind: #{inspect(kind)}"
  end

  defp build_runner_config(issue, workspace, opts, worker_host) do
    %{
      issue: issue,
      workspace_path: workspace,
      worker_host: worker_host,
      max_turns: Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns),
      stall_timeout_ms: Keyword.get(opts, :stall_timeout_ms, Config.settings!().agent.stall_timeout_ms)
    }
  end

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
