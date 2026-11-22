defmodule SymphonyElixir.TerminalHandoffTest do
  use SymphonyElixir.TestSupport, async: false

  alias SymphonyElixir.{Control, TerminalHandoff}

  defmodule FakeAppServer do
    def read_thread(_cwd, thread, _opts) do
      send(Process.get(:handoff_test_pid), {:read, thread})
      {:ok, %{"thread" => %{"id" => thread, "cwd" => Process.get(:handoff_source)}}}
    end

    def fork_thread(cwd, source, destination, _opts) do
      send(Process.get(:handoff_test_pid), {:fork, source, cwd, destination})
      {:ok, %{"thread" => %{"id" => "thread-new"}}}
    end
  end

  test "imports clean HEAD, forks once, and wires the durable Control record" do
    root = Path.join(System.tmp_dir!(), "handoff-#{System.unique_integer([:positive])}")
    source = Path.join(root, "source")
    workspace_root = Path.join(root, "workspaces")
    state_root = Path.join(root, "state")
    File.mkdir_p!(source)
    git(source, ["init", "-b", "main"])
    git(source, ["config", "user.email", "test@example.com"])
    git(source, ["config", "user.name", "Test User"])
    File.write!(Path.join(source, "README.md"), "clean\n")
    git(source, ["add", "."])
    git(source, ["commit", "-m", "initial"])
    {head, 0} = git(source, ["rev-parse", "HEAD"])
    summary = Path.join(root, "summary.txt")
    File.write!(summary, "continue selected thread\n")
    File.mkdir_p!(workspace_root)
    File.mkdir_p!(state_root)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    name = Module.concat(__MODULE__, :Control)
    {:ok, pid} = Control.start_link(name: name, enabled: true, state_root: state_root, workspace_root: workspace_root)
    Process.put(:handoff_test_pid, self())
    Process.put(:handoff_source, source)

    request = %{source_workspace: source, issue_id: "ISSUE-1", thread_id: "thread-old", summary_file: summary}
    opts = [control_server: name, state_root: state_root, app_server_module: FakeAppServer]
    assert {:ok, record} = TerminalHandoff.import(request, opts)
    assert record["sourceHead"] == String.trim(head)
    destination = Path.join(workspace_root, "ISSUE-1")
    assert {dest_head, 0} = git(destination, ["rev-parse", "HEAD"])
    assert String.trim(dest_head) == String.trim(head)
    assert File.read!(Path.join(source, "README.md")) == "clean\n"
    assert_receive {:read, "thread-old"}
    assert_receive {:fork, "thread-old", ^destination, ^destination}
    assert %{handoff: true, thread_id: "thread-new", workspace: ^destination} = Control.snapshot(name, "ISSUE-1")
    assert {:ok, _same} = TerminalHandoff.import(request, opts)
    refute_receive {:fork, _, _, _}
    GenServer.stop(pid)
    File.rm_rf(root)
  end

  test "imports dirty source without changing the source" do
    root = Path.join(System.tmp_dir!(), "handoff-dirty-#{System.unique_integer([:positive])}")
    source = Path.join(root, "source")
    workspace_root = Path.join(root, "workspaces")
    File.mkdir_p!(source)
    git(source, ["init"])
    git(source, ["config", "user.email", "test@example.com"])
    git(source, ["config", "user.name", "Test User"])
    File.write!(Path.join(source, "tracked"), "one\n")
    git(source, ["add", "."])
    git(source, ["commit", "-m", "initial"])
    File.write!(Path.join(source, "tracked"), "changed\n")
    File.write!(Path.join(source, "untracked"), "keep\n")
    summary = Path.join(root, "summary.txt")
    File.write!(summary, "summary\n")
    Process.put(:handoff_test_pid, self())
    Process.put(:handoff_source, source)
    File.mkdir_p!(workspace_root)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok, record} =
             TerminalHandoff.import(%{source_workspace: source, issue_id: "ISSUE-2", thread_id: "thread-old", summary_file: summary},
               app_server_module: FakeAppServer,
               state_root: Path.join(root, "state")
             )

    assert record["issue"] == "ISSUE-2"
    assert File.read!(Path.join(workspace_root, "ISSUE-2/tracked")) == "changed\n"
    assert File.read!(Path.join(workspace_root, "ISSUE-2/untracked")) == "keep\n"
    assert File.read!(Path.join(source, "tracked")) == "changed\n"
    assert File.read!(Path.join(source, "untracked")) == "keep\n"
    assert_receive {:fork, "thread-old", _, _}
    File.rm_rf(root)
  end

  defp git(cwd, args), do: System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true)
end
