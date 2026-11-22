defmodule SymphonyElixir.TerminalSnapshotAcceptanceTest do
  use SymphonyElixir.TestSupport, async: false
  alias SymphonyElixir.TerminalHandoff

  defmodule FakeAppServer do
    def read_thread(_cwd, _id, _opts), do: {:ok, %{"thread" => %{"cwd" => Process.get(:snapshot_source)}}}

    def fork_thread(cwd, _source, _destination, _opts) do
      send(Process.get(:snapshot_owner), {:snapshot_fork, cwd})
      {:ok, %{"thread" => %{"id" => "snapshot-fork"}}}
    end
  end

  test "dirty handoff preserves staged and working bytes without changing the source index" do
    root = Path.join(System.tmp_dir!(), "snapshot-gate-#{System.unique_integer([:positive])}")
    source = Path.join(root, "source")
    workspaces = Path.join(root, "workspaces")
    File.mkdir_p!(source)
    on_exit(fn -> File.rm_rf!(root) end)
    git!(source, ["init", "-b", "main"])
    git!(source, ["config", "user.name", "Snapshot Test"])
    git!(source, ["config", "user.email", "snapshot@example.invalid"])
    File.write!(Path.join(source, "tracked.txt"), "base\n")
    File.write!(Path.join(source, "binary.dat"), <<0, 1, 2>>)
    File.write!(Path.join(source, ".gitignore"), ".env\n")
    git!(source, ["add", "."])
    git!(source, ["commit", "-m", "base"])
    head = git!(source, ["rev-parse", "HEAD"])
    File.write!(Path.join(source, "tracked.txt"), "staged\n")
    File.write!(Path.join(source, "binary.dat"), <<0, 3, 4>>)
    git!(source, ["add", "tracked.txt", "binary.dat"])
    File.write!(Path.join(source, "tracked.txt"), "working\n")
    File.write!(Path.join(source, "binary.dat"), <<0, 5, 6>>)
    File.write!(Path.join(source, "new file.txt"), "untracked\n")
    File.write!(Path.join(source, "new executable.sh"), "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join(source, "new executable.sh"), 0o755)
    File.write!(Path.join(source, ".env"), "TEST_ONLY_IGNORED_VALUE=keep-local\n")
    index_before = File.read!(Path.join(source, ".git/index"))
    summary = Path.join(root, "summary.txt")
    File.write!(summary, "continue selected dirty work")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspaces)
    Process.put(:snapshot_source, source)
    Process.put(:snapshot_owner, self())
    request = %{source_workspace: source, issue_id: "SNAP-1", thread_id: "source-thread", summary_file: summary}
    options = [state_root: Path.join(root, "state"), app_server_module: FakeAppServer]

    assert {:ok, fingerprint} = TerminalHandoff.fingerprint(request, options)
    request = Map.put(request, :expected_fingerprint, fingerprint)
    File.write!(summary, "changed after selection")
    assert {:error, :selected_snapshot_changed} = TerminalHandoff.import(request, options)
    refute_receive {:snapshot_fork, _}
    File.write!(summary, "continue selected dirty work")
    File.write!(Path.join(source, "tracked.txt"), "changed while queued")
    assert {:error, :selected_snapshot_changed} = TerminalHandoff.import(request, options)
    refute_receive {:snapshot_fork, _}
    File.write!(Path.join(source, "tracked.txt"), "working\n")
    assert {:ok, record} = TerminalHandoff.import(request, options)
    destination = record["workspace"]
    assert_receive {:snapshot_fork, ^destination}
    assert File.read!(Path.join(source, ".git/index")) == index_before
    assert git!(source, ["rev-parse", "HEAD"]) == head
    assert File.read!(Path.join(source, "tracked.txt")) == "working\n"
    assert File.read!(Path.join(source, ".env")) == "TEST_ONLY_IGNORED_VALUE=keep-local\n"
    assert File.read!(Path.join(destination, "tracked.txt")) == "working\n"
    assert git!(destination, ["show", ":tracked.txt"]) == "staged\n"
    assert File.read!(Path.join(destination, "binary.dat")) == <<0, 5, 6>>
    assert git!(destination, ["show", ":binary.dat"]) == <<0, 3, 4>>
    assert File.read!(Path.join(destination, "new file.txt")) == "untracked\n"
    refute File.exists?(Path.join(destination, ".env"))
    assert Bitwise.band(File.stat!(Path.join(destination, "new executable.sh")).mode, 0o777) == 0o755
    assert {:ok, ^record} = TerminalHandoff.import(request, options)
    refute_receive {:snapshot_fork, _}
    File.chmod!(Path.join(source, "new executable.sh"), 0o644)
    assert {:error, _} = TerminalHandoff.import(request, options)
    File.chmod!(Path.join(source, "new executable.sh"), 0o755)
    File.write!(Path.join(source, "tracked.txt"), "changed after import\n")
    assert {:error, _} = TerminalHandoff.import(request, options)
    refute_receive {:snapshot_fork, _}
  end

  defmodule AmbiguousAppServer do
    def read_thread(_cwd, _id, _opts), do: {:ok, %{"thread" => %{"cwd" => Process.get(:snapshot_source)}}}

    def fork_thread(_cwd, _source, _destination, _opts) do
      send(Process.get(:snapshot_owner), :ambiguous_fork_attempt)
      {:error, :simulated_fork_timeout}
    end
  end

  test "an ambiguous fork cannot be repeated by retrying the import" do
    root = Path.join(System.tmp_dir!(), "snapshot-ambiguous-#{System.unique_integer([:positive])}")
    source = Path.join(root, "source")
    File.mkdir_p!(source)
    on_exit(fn -> File.rm_rf!(root) end)
    git!(source, ["init", "-b", "main"])
    git!(source, ["config", "user.name", "Snapshot Test"])
    git!(source, ["config", "user.email", "snapshot@example.invalid"])
    File.write!(Path.join(source, "tracked.txt"), "base
")
    git!(source, ["add", "."])
    git!(source, ["commit", "-m", "base"])
    summary = Path.join(root, "summary.txt")
    File.write!(summary, "continue selected work")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.join(root, "workspaces"))
    Process.put(:snapshot_source, source)
    Process.put(:snapshot_owner, self())
    request = %{source_workspace: source, issue_id: "SNAP-2", thread_id: "source-thread", summary_file: summary}
    options = [state_root: Path.join(root, "state"), app_server_module: AmbiguousAppServer]
    assert {:error, _} = TerminalHandoff.import(request, options)
    assert_receive :ambiguous_fork_attempt
    assert {:error, _} = TerminalHandoff.import(request, options)
    refute_receive :ambiguous_fork_attempt
    assert File.read!(Path.join(source, "tracked.txt")) == "base
"
  end

  defmodule MovingHeadAppServer do
    def read_thread(_cwd, _id, _opts) do
      source = Process.get(:snapshot_source)
      {_, 0} = System.cmd("git", ["-C", source, "commit", "--allow-empty", "-m", "concurrent head change"], stderr_to_stdout: true)
      {:ok, %{"thread" => %{"cwd" => source}}}
    end

    def fork_thread(_, _, _, _) do
      send(Process.get(:snapshot_owner), :unexpected_racing_fork)
      {:ok, %{"thread" => %{"id" => "should-not-fork"}}}
    end
  end

  test "even a concurrent HEAD change with identical file bytes prevents the fork" do
    root = Path.join(System.tmp_dir!(), "snapshot-head-#{System.unique_integer([:positive])}")
    source = Path.join(root, "source")
    File.mkdir_p!(source)
    on_exit(fn -> File.rm_rf!(root) end)
    git!(source, ["init", "-b", "main"])
    git!(source, ["config", "user.name", "Snapshot Test"])
    git!(source, ["config", "user.email", "snapshot@example.invalid"])
    git!(source, ["commit", "--allow-empty", "-m", "base"])
    summary = Path.join(root, "summary.txt")
    File.write!(summary, "selected work")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.join(root, "workspaces"))
    Process.put(:snapshot_source, source)
    Process.put(:snapshot_owner, self())
    request = %{source_workspace: source, issue_id: "SNAP-HEAD", thread_id: "source-thread", summary_file: summary}
    assert {:error, _} = TerminalHandoff.import(request, state_root: Path.join(root, "state"), app_server_module: MovingHeadAppServer)
    refute_receive :unexpected_racing_fork
  end

  defp git!(cwd, args) do
    {output, status} = System.cmd("git", ["-C", cwd | args], env: [{"GIT_OPTIONAL_LOCKS", "0"}], stderr_to_stdout: true)
    assert status == 0
    output
  end
end
