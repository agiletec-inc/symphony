defmodule SymphonyElixir.Control.ReviewerTest do
  use SymphonyElixir.TestSupport, async: false

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Control
  alias SymphonyElixir.Control.Outcome
  alias SymphonyElixir.Control.Reviewer
  alias SymphonyElixir.Tracker.Issue

  test "fresh Luna review applies and confirms read-only policy" do
    {workspace, trace, issue} = fixture(%{}, %{"outcome" => "approve", "summary" => "Inspected change"})

    assert {:ok, %{outcome: "approve", model: "gpt-5.6-luna", thread_id: "review-thread"}} =
             Reviewer.run(workspace, issue, "Implement the acceptance criteria", %{"outcome" => "needs_review", "summary" => "Implementation report"})

    requests = File.read!(trace) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.count(requests, &(&1["method"] == "thread/start")) == 1
    refute Enum.any?(requests, &(&1["method"] in ["thread/resume", "thread/fork"]))
    start = Enum.find(requests, &(&1["method"] == "thread/start"))["params"]
    turn = Enum.find(requests, &(&1["method"] == "turn/start"))["params"]
    assert start["model"] == "gpt-5.6-luna"
    assert start["sandbox"] == "read-only"
    assert start["approvalPolicy"] == "never"
    refute Map.has_key?(start, "dynamicTools")
    assert turn["sandboxPolicy"] == %{"type" => "readOnly", "networkAccess" => false}
    assert turn["model"] == "gpt-5.6-luna"
    assert turn["outputSchema"] == Outcome.schema(:review)
  end

  test "unsafe returned configuration refuses the session before a turn" do
    for override <- [
          %{"sandbox" => %{"type" => "workspaceWrite"}},
          %{"sandbox" => %{"type" => "readOnly", "networkAccess" => true}},
          %{"sandbox" => nil},
          %{"approvalPolicy" => "on-request"},
          %{"cwd" => "/"}
        ] do
      {workspace, trace, _issue} = fixture(override, %{})
      options = [model: "gpt-5.6-luna", read_only: true]
      assert {:error, :read_only_configuration_mismatch} = AppServer.start_session(workspace, options)
      refute File.read!(trace) =~ "turn/start"
    end
  end

  test "review output cannot use implementation outcomes" do
    {workspace, _trace, issue} = fixture(%{}, %{"outcome" => "needs_review", "summary" => "not a review verdict"})
    assert {:error, :invalid_outcome} = Reviewer.run(workspace, issue, "Task", %{"outcome" => "needs_review", "summary" => "Report"})
  end

  test "waiting outcomes and invalid requests do not start any model process" do
    {workspace, trace, issue} = fixture(%{}, %{})

    for outcome <- ["waiting_user", "waiting_ci"] do
      assert {:error, :review_not_ready} = Reviewer.run(workspace, issue, "Task", %{"outcome" => outcome, "summary" => "Waiting"})
    end

    for request <- ["", "   ", String.duplicate("x", 16_385), <<255>>] do
      assert {:error, :invalid_request} = Reviewer.run(workspace, issue, request, %{"outcome" => "needs_review", "summary" => "Ready"})
    end

    refute File.exists?(trace)
  end

  test "native implementation runs an independent review and preserves reviewed completion on worker exit" do
    {workspace, trace, issue} = fixture(%{}, %{"outcome" => "approve", "summary" => "Accepted requirements verified"})
    server = native_control(workspace, issue)
    assert :ok = AgentRunner.run(issue, nil, control_server: server, max_turns: 3)
    assert %{state: :completed, thread_id: "implementation-thread", result: %{review: %{thread_id: "review-thread", model: "gpt-5.6-luna"}}} = Control.snapshot(server, issue.id)
    assert :ok = Control.finish_run(server, issue.id, :normal)
    assert %{state: :completed} = Control.snapshot(server, issue.id)
    requests = File.read!(trace) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.count(requests, &(&1["method"] == "turn/start")) == 2
    assert Enum.count(requests, &(&1["method"] == "thread/resume")) == 1
    assert Enum.count(requests, &(&1["method"] == "thread/start")) == 1
  end

  test "review repair loop is bounded and returns to user judgment" do
    {workspace, trace, issue} = fixture(%{}, %{"outcome" => "changes_requested", "summary" => "Missing acceptance test"})
    server = native_control(workspace, issue)
    assert :ok = AgentRunner.run(issue, nil, control_server: server, max_turns: 20)
    assert %{state: :waiting_user, result: %{reason: :review_round_limit}} = Control.snapshot(server, issue.id)
    requests = File.read!(trace) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.count(requests, &(&1["method"] == "turn/start")) == 6
    assert Enum.count(requests, &(&1["method"] == "thread/start")) == 3
    assert :empty = Control.take_native_prompt(server, issue.id)
  end

  test "CI wait survives worker exit without running a reviewer" do
    {workspace, trace, issue} = fixture(%{}, %{}, "waiting_ci")
    server = native_control(workspace, issue)
    assert :ok = AgentRunner.run(issue, nil, control_server: server)
    assert :ok = Control.finish_run(server, issue.id, :normal)
    assert %{state: :waiting_ci} = Control.snapshot(server, issue.id)
    {:registered_name, name} = Process.info(server, :registered_name)
    GenServer.stop(server)

    {:ok, server} =
      Control.start_link(
        name: name,
        enabled: true,
        state_root: Path.join(Path.dirname(Path.dirname(workspace)), "state"),
        workspace_root: Path.dirname(workspace),
        graphql_client: fn _, _, _ -> {:error, :offline} end
      )

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    assert %{state: :waiting_ci} = Control.snapshot(server, issue.id)
    requests = File.read!(trace) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.count(requests, &(&1["method"] == "turn/start")) == 1
    refute Enum.any?(requests, &(&1["method"] == "thread/start"))

    prompted = %{
      "action" => "prompted",
      "_delivery" => "followup",
      "agentSession" => %{"id" => "native-review", "issue" => %{"id" => issue.id}},
      "agentActivity" => %{"id" => "next-input", "content" => %{"body" => "Change the request"}}
    }

    assert :ok = Control.accept_native(server, prompted, "followup-hash")
    assert :ok = Control.publish(server, issue.id, {:completed, %{}})
    assert :ok = Control.finish_run(server, issue.id, :normal)
    assert %{state: :ready} = Control.snapshot(server, issue.id)
    stop = Map.merge(prompted, %{"_delivery" => "stop", "agentActivity" => %{"id" => "stop-input", "signal" => "stop", "content" => %{"body" => "Stop"}}})
    assert :ok = Control.accept_native(server, stop, "stop-hash")
    assert :ok = Control.publish(server, issue.id, {:completed, %{}})
    assert :ok = Control.finish_run(server, issue.id, :normal)
    assert %{state: :waiting_user, paused: true} = Control.snapshot(server, issue.id)
    trace_before = File.read!(trace)
    assert :ok = AgentRunner.run(issue, nil, control_server: server)
    assert File.read!(trace) == trace_before
  end

  defp native_control(workspace, issue) do
    name = Module.concat(__MODULE__, "Server#{System.unique_integer([:positive])}")

    {:ok, server} =
      Control.start_link(
        name: name,
        enabled: true,
        state_root: Path.join(Path.dirname(Path.dirname(workspace)), "state"),
        workspace_root: Path.dirname(workspace),
        graphql_client: fn _, _, _ -> {:error, :offline} end
      )

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    created = %{"action" => "created", "_delivery" => "created", "agentSession" => %{"id" => "native-review", "issue" => %{"id" => issue.id}}, "promptContext" => "Implement the acceptance criteria"}
    :ok = Control.accept_native(server, created, "created-hash")
    :ok = Control.publish(server, issue.id, {:ready, %{thread_id: "implementation-thread", workspace: workspace}})
    server
  end

  defp fixture(overrides, output, implementation_outcome \\ "needs_review") do
    root = Path.join("/private/tmp", "reviewer-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspaces/workspace")
    trace = Path.join(root, "trace")
    fake = Path.join(root, "fake")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    response = %{"model" => "gpt-5.6-luna", "cwd" => workspace, "approvalPolicy" => "never", "sandbox" => %{"type" => "readOnly", "networkAccess" => false}, "thread" => %{"id" => "review-thread"}}
    File.write!(Path.join(root, "start"), Jason.encode!(%{"id" => 2, "result" => Map.merge(response, overrides)}) <> "\n")

    events = [
      %{
        "method" => "item/completed",
        "params" => %{
          "threadId" => "review-thread",
          "turnId" => "review-turn",
          "completedAtMs" => 1,
          "item" => %{"type" => "agentMessage", "id" => "review-item", "phase" => "final_answer", "text" => Jason.encode!(output)}
        }
      },
      %{"method" => "turn/completed", "params" => %{"threadId" => "review-thread", "turn" => %{"id" => "review-turn", "status" => "completed", "items" => []}}}
    ]

    File.write!(Path.join(root, "events"), Enum.map_join(events, "\n", &Jason.encode!/1) <> "\n")

    implementation_events = [
      %{
        "method" => "item/completed",
        "params" => %{
          "threadId" => "implementation-thread",
          "turnId" => "implementation-turn",
          "completedAtMs" => 1,
          "item" => %{
            "type" => "agentMessage",
            "id" => "implementation-item",
            "phase" => "final_answer",
            "text" => Jason.encode!(%{"outcome" => implementation_outcome, "summary" => "Implementation ready"})
          }
        }
      },
      %{"method" => "turn/completed", "params" => %{"threadId" => "implementation-thread", "turn" => %{"id" => "implementation-turn", "status" => "completed", "items" => []}}}
    ]

    File.write!(Path.join(root, "implementation-events"), Enum.map_join(implementation_events, "\n", &Jason.encode!/1) <> "\n")

    File.write!(fake, """
    #!/bin/sh
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> "#{trace}"
      case "$line" in
        *initialize*) echo '{"id":1,"result":{}}' ;;
        *model/list*) echo '{"id":4,"result":{"data":[{"id":"gpt-5.6-luna"}]}}' ;;
        *thread/start*) cat "#{root}/start" ;;
        *thread/resume*) echo '{"id":2,"result":{"model":"gpt-5.6-luna","thread":{"id":"implementation-thread"}}}' ;;
        *implementation-thread*)
          echo '{"id":3,"result":{"turn":{"id":"implementation-turn"}}}'
          cat "#{root}/implementation-events"
          ;;
        *turn/start*)
          echo '{"id":3,"result":{"turn":{"id":"review-turn"}}}'
          cat "#{root}/events"
          ;;
      esac
    done
    """)

    File.chmod!(fake, 0o755)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.dirname(workspace), codex_command: "#{fake} app-server")
    {workspace, trace, %Issue{id: "review", identifier: "REVIEW-1", title: "Task", description: "Acceptance criteria", state: "In Progress"}}
  end
end
