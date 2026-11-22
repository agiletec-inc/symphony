defmodule SymphonyElixir.NativeResumeTest do
  use SymphonyElixir.TestSupport, async: false

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Control
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Workflow

  test "a prompted follow-up makes a waiting native session ready and is claimed once" do
    root = Path.join(System.tmp_dir!(), "native-resume-#{System.unique_integer([:positive])}")
    server = Module.concat(__MODULE__, Server)

    {:ok, pid} =
      Control.start_link(
        name: server,
        enabled: true,
        state_root: Path.join(root, "state"),
        workspace_root: Path.join(root, "workspace")
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf(root)
    end)

    event = %{"action" => "created", "agentSession" => %{"id" => "session-1", "issue" => %{"id" => "issue-1"}}}

    graphql = fn query, variables, _opts ->
      if String.contains?(query, "agentActivityCreate") do
        id = get_in(variables, [:input, :id])

        {:ok,
         %{
           "data" => %{
             "agentActivityCreate" => %{
               "success" => true,
               "agentActivity" => %{"id" => id, "agentSession" => %{"id" => "session-1"}}
             }
           }
         }}
      else
        {:ok, %{"data" => %{"agentSession" => %{"id" => "session-1", "activities" => %{"nodes" => []}}}}}
      end
    end

    assert :ok =
             Control.accept_native(server, Map.put(event, "_delivery", "delivery-1"), "hash-1", graphql_client: graphql)

    assert :ok =
             Control.publish(
               server,
               "issue-1",
               {:waiting_user, %{thread_id: "thread-1", workspace: Path.join(root, "workspace")}}
             )

    prompted = %{
      "action" => "prompted",
      "agentSession" => %{"id" => "session-1", "issue" => %{"id" => "issue-1"}},
      "agentActivity" => %{"id" => "activity-1", "content" => %{"body" => "continue"}}
    }

    assert :ok = Control.accept_native(server, Map.put(prompted, "_delivery", "delivery-2"), "hash-2")
    await_projection(server, "issue-1")
    assert Control.dispatchable?(server, "issue-1")
    assert {:ok, "continue"} = Control.take_native_prompt(server, "issue-1")
    assert :empty = Control.take_native_prompt(server, "issue-1")

    assert %{thread_id: "thread-1", prompts: [%{id: "activity-1", body: "continue"}], state: :ready} =
             Control.snapshot(server, "issue-1")
  end

  test "AgentRunner resumes the saved Luna thread with one claimed native prompt" do
    root = Path.join(System.tmp_dir!(), "native-wire-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "WIRE-1")
    trace = Path.join(root, "requests.jsonl")
    fake = Path.join(root, "fake-codex")
    File.mkdir_p!(workspace)

    File.write!(fake, """
    #!/bin/sh
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> "#{trace}"
      case "$line" in
        *initialize*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *model/list*) printf '%s\\n' '{"id":4,"result":{"data":[{"id":"gpt-5.6-luna"}]}}' ;;
        *thread/resume*) printf '%s\\n' '{"id":2,"result":{"model":"gpt-5.6-luna","thread":{"id":"saved-thread"}}}' ;;
        *turn/start*) printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-1"}}}'; printf '%s\\n' '{"method":"item/completed","params":{"threadId":"saved-thread","turnId":"turn-1","item":{"type":"agentMessage","phase":"final_answer","text":"{\\"outcome\\":\\"waiting_user\\",\\"summary\\":\\"Awaiting input\\"}"}}}'; printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"saved-thread","turn":{"id":"turn-1","status":"completed","items":[]}}}' ;;
      esac
    done
    """)

    File.chmod!(fake, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{fake} app-server"
    )

    server = Module.concat(__MODULE__, WireServer)

    {:ok, pid} =
      Control.start_link(
        name: server,
        enabled: true,
        state_root: Path.join(root, "state"),
        workspace_root: workspace_root
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf(root)
    end)

    issue = %Issue{
      id: "wire-issue",
      identifier: "WIRE-1",
      title: "resume",
      state: "In Progress",
      url: "https://example.org/WIRE-1"
    }

    created = %{
      "action" => "created",
      "agentSession" => %{"id" => "session-wire", "issue" => %{"id" => issue.id}},
      "promptContext" => "initial"
    }

    assert :ok = Control.accept_native(server, Map.put(created, "_delivery", "wire-created"), "wire-created-hash")
    assert {:ok, "initial"} = Control.take_native_prompt(server, issue.id)
    assert :ok = Control.acknowledge_native_prompt(server, issue.id)
    :ok = Control.publish(server, issue.id, {:waiting_user, %{thread_id: "saved-thread", workspace: workspace}})

    prompted = %{
      "action" => "prompted",
      "agentSession" => %{"id" => "session-wire", "issue" => %{"id" => issue.id}},
      "agentActivity" => %{"id" => "wire-prompt", "content" => %{"body" => "continue"}}
    }

    assert :ok = Control.accept_native(server, Map.put(prompted, "_delivery", "wire-prompted"), "wire-prompted-hash")

    assert :ok =
             AgentRunner.run(issue, nil,
               max_turns: 1,
               control_server: server,
               issue_state_fetcher: fn ["wire-issue"] -> {:ok, [issue]} end
             )

    content = File.read!(trace)
    assert content =~ ~s("method":"thread/resume")
    refute content =~ ~s("method":"thread/start")
    assert content =~ ~s("threadId":"saved-thread")
    assert content =~ "continue"
    assert content =~ ~s("model":"gpt-5.6-luna")
    assert %{state: :waiting_user, model: "gpt-5.6-luna"} = Control.snapshot(server, issue.id)
    assert :empty = Control.take_native_prompt(server, issue.id)

    assert_raise RuntimeError, ~r/native_input_unavailable/, fn ->
      AgentRunner.run(issue, nil,
        max_turns: 1,
        control_server: server,
        issue_state_fetcher: fn ["wire-issue"] -> {:ok, [issue]} end
      )
    end

    assert Enum.count(String.split(File.read!(trace), "\n"), &String.contains?(&1, "turn/start")) == 1
  end

  defp await_projection(server, issue, attempts \\ 50)
  defp await_projection(server, issue, 0), do: assert(Control.snapshot(server, issue)[:projection_pending] == false)

  defp await_projection(server, issue, attempts) do
    if Control.snapshot(server, issue)[:projection_pending] == false do
      :ok
    else
      Process.sleep(10)
      await_projection(server, issue, attempts - 1)
    end
  end
end
