defmodule SymphonyElixir.NativePollingAcceptanceTest do
  use SymphonyElixir.TestSupport, async: false

  alias SymphonyElixir.{Control, Orchestrator, Workflow}
  alias SymphonyElixir.Tracker.Issue

  test "native waiting session resumes once on prompted input and stays quiet after completion" do
    root = Path.join("/private/tmp", "native-polling-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    state_root = Path.join(root, "state")
    workspace_root = Path.join(root, "workspaces")
    trace = Path.join(root, "trace.jsonl")
    fake = Path.join(root, "fake-codex")

    File.write!(fake, """
    #!/bin/sh
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> "#{trace}"
      case "$line" in
        *initialize*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *model/list*) printf '%s\\n' '{"id":4,"result":{"data":[{"id":"gpt-5.6-luna"}]}}' ;;
        *thread/resume*) printf '%s\\n' '{"id":2,"result":{"model":"gpt-5.6-luna","thread":{"id":"native-thread"}}}' ;;
        *turn/start*) printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-1"}}}'; printf '%s\\n' '{"method":"item/completed","params":{"threadId":"native-thread","turnId":"turn-1","item":{"type":"agentMessage","phase":"final_answer","text":"{\\"outcome\\":\\"waiting_user\\",\\"summary\\":\\"Awaiting input\\"}"}}}'; printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"native-thread","turn":{"id":"turn-1","status":"completed","items":[]}}}' ;;
      esac
    done
    """)

    File.chmod!(fake, 0o755)
    File.mkdir_p!(Path.join(workspace_root, "POLL-1"))

    issue = %Issue{
      dispatchable: true,
      id: "poll-issue",
      identifier: "POLL-1",
      title: "native polling",
      state: "In Progress",
      url: "https://example.invalid/POLL-1"
    }

    previous = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    workflow = Workflow.workflow_file_path()

    write_workflow_file!(workflow,
      tracker_kind: "memory",
      poll_interval_ms: 10,
      workspace_root: workspace_root,
      codex_command: "#{fake} app-server"
    )

    File.write!(
      workflow,
      String.replace(
        File.read!(workflow),
        "polling:",
        "control:\n  enabled: true\nlinear_agent_session:\n  enabled: true\npolling:"
      )
    )

    SymphonyElixir.WorkflowStore.force_reload()

    graphql = fn query, variables, _opts ->
      if String.contains?(query, "agentActivityCreate") do
        id = get_in(variables, [:input, :id])

        {:ok,
         %{
           "data" => %{
             "agentActivityCreate" => %{
               "success" => true,
               "agentActivity" => %{"id" => id, "agentSession" => %{"id" => "native-session"}}
             }
           }
         }}
      else
        {:ok, %{"data" => %{"agentSession" => %{"id" => "native-session", "activities" => %{"nodes" => []}}}}}
      end
    end

    control_opts =
      [name: nil, enabled: true] ++
        [state_root: state_root, workspace_root: workspace_root, graphql_client: graphql]

    control = start_supervised!({Control, control_opts})

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :memory_tracker_issues, previous)
      Workflow.set_workflow_file_path(workflow)
      File.rm_rf(root)
    end)

    assert is_pid(control)
    created = %{"action" => "created", "agentSession" => %{"id" => "native-session", "issue" => %{"id" => issue.id}}}

    assert :ok =
             Control.accept_native(control, Map.put(created, "_delivery", "poll-created"), "poll-created-hash", graphql_client: graphql)

    assert :ok =
             Control.publish(
               control,
               issue.id,
               {:waiting_user, %{thread_id: "native-thread", workspace: Path.join(workspace_root, "POLL-1")}}
             )

    assert eventually(fn -> Control.snapshot(control, issue.id)[:projection_pending] == false end)
    orchestrator = start_supervised!({Orchestrator, name: nil, control_server: control})
    poll(orchestrator)
    assert turn_count(trace) == 0

    prompted = %{
      "action" => "prompted",
      "agentSession" => %{"id" => "native-session", "issue" => %{"id" => issue.id}},
      "agentActivity" => %{"id" => "prompt-1", "content" => %{"body" => "continue"}}
    }

    assert :ok =
             Control.accept_native(control, Map.put(prompted, "_delivery", "poll-prompt"), "poll-prompt-hash", graphql_client: graphql)

    poll(orchestrator)

    assert eventually(fn -> settled?(control, orchestrator, issue.id) and turn_count(trace) == 1 end),
           inspect(
             {Control.snapshot(control, issue.id), read_trace(trace),
              Enum.map(:sys.get_state(orchestrator).running, fn {id, worker} ->
                {id, Process.info(worker.pid, [:current_stacktrace, :status, :message_queue_len])}
              end)}
           )

    poll(orchestrator)
    assert turn_count(trace) == 1

    assert :ok =
             Control.accept_native(control, Map.put(prompted, "_delivery", "poll-prompt"), "poll-prompt-hash", graphql_client: graphql)

    poll(orchestrator)
    assert turn_count(trace) == 1

    next =
      put_in(prompted, ["agentActivity", "id"], "prompt-2")
      |> put_in(["agentActivity", "content", "body"], "second instruction")

    assert :ok =
             Control.accept_native(control, Map.put(next, "_delivery", "poll-prompt-2"), "poll-prompt-hash-2", graphql_client: graphql)

    poll(orchestrator)
    assert eventually(fn -> settled?(control, orchestrator, issue.id) and turn_count(trace) == 2 end)
    poll(orchestrator)
    requests = read_trace(trace)
    assert turn_count(trace) == 2
    assert Enum.count(requests, &(&1["method"] == "thread/resume")) == 2
    refute Enum.any?(requests, &(&1["method"] == "thread/start"))
    turns = Enum.filter(requests, &(&1["method"] == "turn/start"))
    assert Enum.all?(turns, &(&1["params"]["threadId"] == "native-thread" and &1["params"]["model"] == "gpt-5.6-luna"))
    assert inspect(turns) =~ "second instruction"
  end

  defp poll(orchestrator) do
    for _ <- 1..3 do
      send(orchestrator, :run_poll_cycle)
      :sys.get_state(orchestrator)
    end
  end

  defp settled?(control, orchestrator, issue) do
    Control.snapshot(control, issue)[:state] == :waiting_user and :sys.get_state(orchestrator).running == %{}
  end

  defp turn_count(file), do: Enum.count(read_trace(file), &(&1["method"] == "turn/start"))

  defp read_trace(file) do
    case File.read(file) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&decode_trace_line/1)

      _ ->
        []
    end
  end

  defp decode_trace_line(line) do
    case Jason.decode(line) do
      {:ok, value} -> [value]
      _ -> []
    end
  end

  defp eventually(fun, attempts \\ 300)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end
end
