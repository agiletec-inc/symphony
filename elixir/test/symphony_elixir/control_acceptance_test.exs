defmodule SymphonyElixir.ControlAcceptanceTest do
  use SymphonyElixir.TestSupport, async: false

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Control
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Workflow

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-control-#{System.unique_integer([:positive])}")
    state_root = Path.join(root, "state")
    workspace_root = Path.join(root, "workspaces")
    File.mkdir_p!(state_root)
    File.mkdir_p!(workspace_root)
    name = Module.concat(__MODULE__, "Server#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Control.start_link(
        name: name,
        enabled: true,
        state_root: state_root,
        workspace_root: workspace_root,
        allowed_actor_ids: ["operator-1"],
        controller_actor_id: "controller"
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf(root)
    end)

    %{server: name, pid: pid, state_root: state_root, workspace_root: workspace_root}
  end

  test "allowlisted controller commands are idempotent by Linear comment id", %{server: server} do
    comment = %{id: "comment-1", issue_id: "issue-1", user_id: "operator-1", body: "/symphony resume"}
    assert {:ok, _} = Control.authorize_comment(server, "issue-1", comment)
    assert {:duplicate, _} = Control.authorize_comment(server, "issue-1", comment)

    assert {:error, :unauthorized_actor} =
             Control.authorize_comment(server, "issue-1", %{comment | id: "comment-2", user_id: "unknown"})
  end

  test "controller-authored comments cannot trigger control", %{server: server} do
    comment = %{id: "comment-controller", issue_id: "issue-1", user_id: "controller", body: "/symphony resume"}
    assert {:error, :controller_comment} = Control.authorize_comment(server, "issue-1", comment)
  end

  test "waiting state persists over restart and resumes once", %{server: server, pid: pid, state_root: state_root} do
    assert :ok = Control.publish(server, "issue-1", {:waiting_user, %{prompt_id: "p-1"}})
    assert %{state: :waiting_user} = Control.snapshot(server, "issue-1")
    GenServer.stop(pid)

    {:ok, restarted} =
      Control.start_link(
        name: server,
        enabled: true,
        state_root: state_root,
        allowed_actor_ids: ["operator-1"],
        controller_actor_id: "controller"
      )

    assert %{state: :waiting_user} = Control.snapshot(server, "issue-1")
    assert Control.dispatchable?(server, "issue-1") == false

    comment = %{id: "comment-3", issue_id: "issue-1", user_id: "operator-1", body: "/symphony resume"}
    assert {:ok, :resume} = Control.authorize_comment(server, "issue-1", comment)
    assert Control.dispatchable?(server, "issue-1") == true
    assert {:duplicate, _} = Control.authorize_comment(server, "issue-1", comment)
    GenServer.stop(restarted)
  end

  test "disabled control is inert", %{state_root: state_root, workspace_root: workspace_root} do
    name = Module.concat(__MODULE__, :Disabled)
    {:ok, pid} = Control.start_link(name: name, enabled: false, state_root: state_root, workspace_root: workspace_root)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert {:disabled, _} =
             Control.authorize_comment(name, "issue-disabled", %{
               id: "c",
               user_id: "operator-1",
               body: "/symphony resume"
             })

    assert Control.dispatchable?(name, "issue-disabled") == true
  end

  test "state projection contains summaries and IDs only", %{server: server} do
    assert :ok = Control.publish(server, "issue-1", {:completed, %{pr_id: "pr-1", result: "passed"}})
    snapshot = Control.snapshot(server, "issue-1")
    refute inspect(snapshot) =~ "raw transcript"
    refute inspect(snapshot) =~ "Authorization"
    assert snapshot.state == :completed
  end

  test "unsafe state and workspace paths fail closed", %{server: server, workspace_root: workspace_root} do
    Process.flag(:trap_exit, true)

    assert {:error, :state_root_inside_workspace} =
             Control.start_link(
               name: Module.concat(__MODULE__, :Unsafe),
               enabled: true,
               state_root: workspace_root,
               workspace_root: workspace_root,
               allowed_actor_ids: ["operator-1"]
             )

    assert {:error, _} = Control.claim(server, "issue-1", Path.join(workspace_root, "../outside"))
  end

  test "a second controller cannot claim an issue already held", %{server: server, workspace_root: workspace_root} do
    workspace = Path.join(workspace_root, "issue-1")
    File.mkdir_p!(workspace)
    assert :ok = Control.claim(server, "issue-1", workspace)
    assert {:error, :already_claimed} = Control.claim(server, "issue-1", workspace)
    assert :ok = Control.release(server, "issue-1")
  end

  test "kernel lock rejects a second controller and is released on owner crash", %{pid: pid, state_root: state_root} do
    Process.flag(:trap_exit, true)
    duplicate = Module.concat(__MODULE__, :DuplicateController)

    assert {:error, _reason} =
             Control.start_link(
               name: duplicate,
               enabled: true,
               state_root: state_root,
               allowed_actor_ids: ["operator-1"]
             )

    Process.exit(pid, :kill)
    refute Process.alive?(pid)
    replacement = Module.concat(__MODULE__, :ReplacementController)

    assert {:ok, restarted} =
             Control.start_link(
               name: replacement,
               enabled: true,
               state_root: state_root,
               allowed_actor_ids: ["operator-1"]
             )

    on_exit(fn -> if Process.alive?(restarted), do: GenServer.stop(restarted) end)
  end

  test "real AgentRunner turn completion enters durable wait and does not start another turn", %{server: server} do
    root = Path.join(System.tmp_dir!(), "symphony-control-runner-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    source = Path.join(root, "source")
    fake = Path.join(root, "fake-codex")
    File.mkdir_p!(workspace_root)
    File.mkdir_p!(source)
    File.write!(Path.join(source, "README.md"), "source")
    System.cmd("git", ["-C", source, "init", "-b", "main"])
    System.cmd("git", ["-C", source, "config", "user.email", "test@example.com"])
    System.cmd("git", ["-C", source, "config", "user.name", "Test"])
    System.cmd("git", ["-C", source, "add", "."])
    System.cmd("git", ["-C", source, "commit", "-m", "init"])

    File.write!(fake, """
    #!/bin/sh
    n=0
    while IFS= read -r line; do
      n=$((n + 1))
      if [ "$n" = 1 ]; then printf '%s\\n' '{"id":1,"result":{}}'; fi
      if [ "$n" = 2 ]; then printf '%s\\n' '{"id":4,"result":{"data":[{"id":"gpt-5.6-luna"}]}}'; fi
      if [ "$n" = 3 ]; then printf '%s\\n' '{"id":2,"result":{"model":"gpt-5.6-luna","thread":{"id":"thread-real"}}}'; fi
      if [ "$n" = 4 ]; then printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-real"}}}'; printf '%s\\n' '{"method":"turn/completed"}'; fi
    done
    """)

    File.chmod!(fake, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{fake} app-server",
      hook_after_create: "cp #{Path.join(source, "README.md")} README.md"
    )

    issue = %Issue{
      id: "control-run",
      identifier: "S-1",
      title: "wait",
      state: "In Progress",
      url: "https://example.org/S-1"
    }

    assert :ok =
             AgentRunner.run(issue, self(),
               max_turns: 3,
               control_server: server,
               issue_state_fetcher: fn ["control-run"] -> {:ok, [issue]} end
             )

    assert %{state: :waiting_user} = Control.snapshot(server, "control-run")
    assert Control.dispatchable?(server, "control-run") == false
    File.rm_rf(root)
  end

  test "Orchestrator normal worker down does not schedule continuation when Control is enabled", %{server: server} do
    path = Workflow.workflow_file_path()
    original = File.read!(path)

    File.write!(
      path,
      String.replace(
        original,
        "polling:\n",
        "control:\n  enabled: true\n  allowed_actor_ids: [\"operator-1\"]\npolling:\n"
      )
    )

    name = Module.concat(__MODULE__, :ControlOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: name, control_server: server)
    issue_id = "orchestrator-control-#{System.unique_integer([:positive])}"
    ref = make_ref()

    entry = %{
      pid: self(),
      ref: ref,
      identifier: "S-CTRL",
      issue: %Issue{id: issue_id, identifier: "S-CTRL", state: "In Progress", url: "https://example.org/S-CTRL"},
      started_at: DateTime.utc_now()
    }

    state = :sys.get_state(pid)

    :sys.replace_state(pid, fn _ ->
      %{state | running: %{issue_id => entry}, claimed: MapSet.put(state.claimed, issue_id)}
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(30)
    updated = :sys.get_state(pid)
    assert updated.retry_attempts == %{}
    assert %{state: :waiting_user} = Control.snapshot(server, issue_id)
    GenServer.stop(pid)
    File.write!(path, original)
  end
end
