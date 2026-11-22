defmodule SymphonyElixir.HandoffDaemonAcceptanceTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Control
  alias SymphonyElixir.Control.HandoffInbox

  setup do
    root = Path.join(System.tmp_dir!(), "handoff-daemon-#{System.unique_integer([:positive])}")
    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(root)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, state_root: Path.join(root, "state"), workspace_root: Path.join(root, "workspaces")}
  end

  test "daemon consumes queued handoff outside mailbox and excludes issue execution", ctx do
    test_pid = self()
    source = Path.join(ctx.root, "source")
    summary = Path.join(ctx.root, "summary.md")
    File.mkdir_p!(source)
    File.write!(summary, "selected summary")

    {:ok, request_id} =
      HandoffInbox.submit(ctx.state_root, %{
        source_workspace: source,
        summary_file: summary,
        issue_id: "issue-1",
        thread_id: "terminal-thread"
      })

    importer = fn request, opts ->
      send(test_pid, {:importing, self(), request, opts})

      receive do
        :finish -> {:ok, %{thread: "forked"}}
      end
    end

    control_opts = [
      name: nil,
      enabled: true,
      native_session_config: %{enabled: false},
      state_root: ctx.state_root,
      workspace_root: ctx.workspace_root,
      handoff_importer: importer
    ]

    server = start_supervised!({Control, control_opts})

    assert_receive {:importing, task, %{issue_id: "issue-1"}, opts}, 2_000
    assert opts[:control_server] == server
    assert opts[:state_root] == elem(SymphonyElixir.PathSafety.canonicalize(ctx.state_root), 1)
    assert %{handoff_pending: true} = Control.snapshot(server, "issue-1")
    assert {:error, :not_dispatchable} = Control.reserve_run(server, "issue-1")
    assert {:error, :issue_busy} = Control.begin_handoff(server, "issue-1")
    assert :ok = Control.publish(server, "another-issue", {:ready, %{}})
    send(task, :finish)

    assert eventually(fn ->
             match?({:ok, %{"status" => "complete"}}, HandoffInbox.status(ctx.state_root, request_id))
           end)

    assert %{handoff_pending: false, handoff_status: :complete, state: :waiting_user} =
             Control.snapshot(server, "issue-1")

    refute_receive {:importing, _, _, _}, 100
  end

  test "atomic reservation admits one run despite concurrent state publication", ctx do
    control_opts = [
      name: nil,
      enabled: true,
      native_session_config: %{enabled: false},
      state_root: ctx.state_root,
      workspace_root: ctx.workspace_root
    ]

    server = start_supervised!({Control, control_opts})

    results =
      1..12
      |> Task.async_stream(fn _ -> Control.reserve_run(server, "issue-1") end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert :ok = Control.publish(server, "issue-1", {:ready, %{}})
    assert {:error, :issue_busy} = Control.begin_handoff(server, "issue-1")
    assert {:error, :not_dispatchable} = Control.reserve_run(server, "issue-1")
    assert :ok = Control.finish_run(server, "issue-1", :normal)
    assert :ok = Control.begin_handoff(server, "issue-1")
    assert {:error, :not_dispatchable} = Control.reserve_run(server, "issue-1")
  end

  test "corrupt durable control state refuses startup instead of forgetting reservations", ctx do
    File.mkdir_p!(ctx.state_root)
    file = Path.join(ctx.state_root, "records.term")
    File.write!(file, "truncated state")

    control_opts = [
      name: nil,
      enabled: true,
      native_session_config: %{enabled: false},
      state_root: ctx.state_root,
      workspace_root: ctx.workspace_root
    ]

    assert {:error, _} = start_supervised({Control, control_opts})

    assert File.read!(file) == "truncated state"
    refute File.exists?(Path.join(ctx.state_root, "handoff-inbox"))
  end

  test "control owner crash also terminates its in-flight importer", ctx do
    source = Path.join(ctx.root, "source")
    summary = Path.join(ctx.root, "summary.md")
    File.mkdir_p!(source)
    File.write!(summary, "selected summary")

    {:ok, _} =
      HandoffInbox.submit(ctx.state_root, %{
        source_workspace: source,
        summary_file: summary,
        issue_id: "issue-1",
        thread_id: "thread"
      })

    test_pid = self()

    importer = fn _request, _opts ->
      send(test_pid, {:active_importer, self()})

      receive do
        :finish -> :ok
      end
    end

    spawn(fn ->
      {:ok, server} =
        Control.start_link(
          name: nil,
          enabled: true,
          native_session_config: %{enabled: false},
          state_root: ctx.state_root,
          workspace_root: ctx.workspace_root,
          handoff_importer: importer
        )

      send(test_pid, {:control_owner, server})

      receive do
        :finish -> :ok
      end
    end)

    assert_receive {:control_owner, server}, 2_000
    assert_receive {:active_importer, importer_pid}, 2_000
    ref = Process.monitor(importer_pid)
    Process.exit(server, :kill)
    assert_receive {:DOWN, ^ref, :process, ^importer_pid, _reason}, 2_000
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(20)
          eventually(fun, attempts - 1)
        )
  end
end
