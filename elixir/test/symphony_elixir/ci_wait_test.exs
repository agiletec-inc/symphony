defmodule SymphonyElixir.Control.CiWaitTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Control
  alias SymphonyElixir.Control.CiMonitor
  alias SymphonyElixir.Control.CiResult

  test "target and check classification reject stale or unknown evidence" do
    payload = payload()
    assert {:ok, target} = CiResult.target(payload)
    assert :completed = CiResult.classify(target, payload)
    assert {:error, :stale_ci_target} = CiResult.classify(target, Map.put(payload, "headRefOid", String.duplicate("b", 40)))
    assert {:error, :stale_ci_target} = CiResult.classify(target, Map.put(payload, "url", "https://github.com/owner/other/pull/1"))

    for checks <- [
          [],
          nil,
          [%{}],
          [%{"__typename" => "StatusContext", "state" => "PENDING"}],
          [%{"__typename" => "CheckRun", "status" => "IN_PROGRESS"}],
          [%{"__typename" => "CheckRun", "status" => "COMPLETED", "conclusion" => "FUTURE_STATE"}],
          List.duplicate(%{}, 1001)
        ] do
      assert :pending = CiResult.classify(target, Map.put(payload, "statusCheckRollup", checks))
    end

    for url <- [
          "https://github.com/owner/../pull/1",
          "https://github.com/../repo/pull/1",
          "https://evil.example/owner/repo/pull/1",
          "https://github.com/owner/repo/pull/1?token=x",
          "https://user@github.com/owner/repo/pull/1"
        ] do
      assert {:error, :invalid_ci_target} = CiResult.target(Map.put(payload, "url", url))
    end
  end

  test "completed failure wakes exactly once across controller restart" do
    opts = control_options()
    server = start_control(opts)
    prepare(server)
    assert {:ok, wait} = Control.arm_ci_wait(server, "issue", payload())
    assert {:ok, ^wait} = Control.arm_ci_wait(server, "issue", payload())
    GenServer.stop(server)
    server = start_control(opts)
    assert :woken = Control.apply_ci_result(server, "issue", wait.id, payload())
    assert %{state: :ready} = Control.snapshot(server, "issue")
    GenServer.stop(server)
    server = start_control(opts)
    assert :ignored = Control.apply_ci_result(server, "issue", wait.id, payload())
    assert {:ok, prompt} = Control.take_native_prompt(server, "issue")
    assert prompt =~ "does not imply success"
    assert :ok = Control.acknowledge_native_prompt(server, "issue")
    assert :empty = Control.take_native_prompt(server, "issue")
    assert :ok = Control.publish(server, "issue", {:waiting_ci, %{}})
    assert {:error, :ci_already_handled} = Control.arm_ci_wait(server, "issue", payload())
  end

  test "replaced wait and stale head cannot wake the current request" do
    server = start_control(control_options())
    prepare(server)
    assert {:ok, old} = Control.arm_ci_wait(server, "issue", payload())
    newer = Map.put(payload(), "headRefOid", String.duplicate("b", 40))
    assert {:ok, current} = Control.arm_ci_wait(server, "issue", newer)
    assert :ignored = Control.apply_ci_result(server, "issue", old.id, payload())
    assert {:error, :stale_ci_target} = Control.apply_ci_result(server, "issue", current.id, payload())
    assert %{state: :waiting_ci} = Control.snapshot(server, "issue")
    assert :woken = Control.apply_ci_result(server, "issue", current.id, newer)
  end

  test "paused or newer user input prevents CI from scheduling a turn" do
    for signal <- [nil, "stop"] do
      server = start_control(control_options())
      prepare(server)
      assert {:ok, wait} = Control.arm_ci_wait(server, "issue", payload())

      event = %{
        "action" => "prompted",
        "_delivery" => "next",
        "agentSession" => %{"id" => "session", "issue" => %{"id" => "issue"}},
        "agentActivity" => %{"id" => "next", "signal" => signal, "content" => %{"body" => "New decision"}}
      }

      assert :ok = Control.accept_native(server, event, "next-hash")
      before = Control.snapshot(server, "issue")
      assert :ignored = Control.apply_ci_result(server, "issue", wait.id, payload())
      assert Control.snapshot(server, "issue").prompts == before.prompts
    end
  end

  test "owned monitor discovers then polls the saved target without duplicate wake" do
    parent = self()

    provider = fn workspace, wait ->
      send(parent, {:ci_read, workspace, wait})
      if is_nil(wait), do: {:ok, Map.put(payload(), "statusCheckRollup", [])}, else: {:ok, payload()}
    end

    opts = Keyword.put(control_options(), :ci_provider, provider)
    server = start_control(opts)
    prepare(server)
    workspace = Path.join(opts[:workspace_root], "CI-1")
    File.mkdir_p!(workspace)
    :ok = Control.publish(server, "issue", {:waiting_ci, %{workspace: workspace}})
    monitor = :sys.get_state(server).ci_monitor
    assert :ok = CiMonitor.poll_now(monitor)
    assert_receive {:ci_read, ^workspace, nil}
    assert %{state: :waiting_ci, ci_wait: wait} = Control.snapshot(server, "issue")
    assert :ok = CiMonitor.poll_now(monitor)
    assert_receive {:ci_read, ^workspace, ^wait}
    assert %{state: :ready} = Control.snapshot(server, "issue")
    assert :ok = CiMonitor.poll_now(monitor)
    refute_receive {:ci_read, _, _}, 30
    assert {:ok, _} = Control.take_native_prompt(server, "issue")
    assert :ok = Control.acknowledge_native_prompt(server, "issue")
    assert :empty = Control.take_native_prompt(server, "issue")
    ref = Process.monitor(monitor)
    GenServer.stop(server)
    assert_receive {:DOWN, ^ref, :process, ^monitor, :shutdown}
  end

  test "owner stop terminates a monitor blocked in a provider read" do
    parent = self()

    provider = fn _, _ ->
      send(parent, :provider_entered)

      receive do
        :release -> {:error, :test_release}
      end
    end

    opts = Keyword.put(control_options(), :ci_provider, provider)
    server = start_control(opts)
    prepare(server)
    :ok = Control.publish(server, "issue", {:waiting_ci, %{workspace: opts[:workspace_root]}})
    monitor = :sys.get_state(server).ci_monitor
    reference = Process.monitor(monitor)

    caller =
      spawn(fn ->
        try do
          CiMonitor.poll_now(monitor)
        catch
          :exit, _ -> :ok
        end
      end)

    caller_reference = Process.monitor(caller)
    assert_receive :provider_entered
    GenServer.stop(server)
    assert_receive {:DOWN, ^reference, :process, ^monitor, :shutdown}
    assert_receive {:DOWN, ^caller_reference, :process, ^caller, _}
  end

  test "a provider exception does not starve other waiting issues" do
    counter = start_supervised!({Agent, fn -> 0 end})

    provider = fn _, _ ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 -> raise "provider unavailable"
        _ -> {:ok, payload()}
      end
    end

    opts = Keyword.put(control_options(), :ci_provider, provider)
    server = start_control(opts)

    for id <- ["issue-a", "issue-b"] do
      event = %{"action" => "created", "_delivery" => id, "agentSession" => %{"id" => id, "issue" => %{"id" => id}}, "promptContext" => "Task"}
      :ok = Control.accept_native(server, event, id)
      {:ok, _} = Control.take_native_prompt(server, id)
      :ok = Control.acknowledge_native_prompt(server, id)
      :ok = Control.publish(server, id, {:waiting_ci, %{workspace: opts[:workspace_root]}})
    end

    monitor = :sys.get_state(server).ci_monitor
    assert :ok = CiMonitor.poll_now(monitor)
    assert Agent.get(counter, & &1) == 2
    states = Enum.map(["issue-a", "issue-b"], &Control.snapshot(server, &1).state)
    assert Enum.sort(states) == [:ready, :waiting_ci]
  end

  test "stale timer messages cannot create parallel polling schedules" do
    opts = control_options()
    server = start_control(opts)
    monitor = :sys.get_state(server).ci_monitor
    assert :ok = CiMonitor.poll_now(monitor)
    old = :sys.get_state(monitor).timer_token
    assert :ok = CiMonitor.poll_now(monitor)
    current = :sys.get_state(monitor).timer_token
    send(monitor, {:poll, old})
    assert :sys.get_state(monitor).timer_token == current
  end

  defp payload do
    %{
      "url" => "https://github.com/owner/repo/pull/1",
      "headRefOid" => String.duplicate("a", 40),
      "statusCheckRollup" => [%{"__typename" => "CheckRun", "status" => "COMPLETED", "conclusion" => "FAILURE"}, %{"__typename" => "StatusContext", "state" => "SUCCESS"}]
    }
  end

  defp control_options do
    root = Path.join("/private/tmp", "ci-wait-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    [
      name: Module.concat(__MODULE__, "Server#{System.unique_integer([:positive])}"),
      enabled: true,
      state_root: Path.join(root, "state"),
      workspace_root: Path.join(root, "workspaces"),
      graphql_client: fn _, _, _ -> {:error, :offline} end
    ]
  end

  defp start_control(opts) do
    {:ok, server} = Control.start_link(opts)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    server
  end

  defp prepare(server) do
    event = %{"action" => "created", "_delivery" => "created", "agentSession" => %{"id" => "session", "issue" => %{"id" => "issue"}}, "promptContext" => "Task"}
    assert :ok = Control.accept_native(server, event, "created-hash")
    assert {:ok, "Task"} = Control.take_native_prompt(server, "issue")
    assert :ok = Control.acknowledge_native_prompt(server, "issue")
    assert :ok = Control.publish(server, "issue", {:waiting_ci, %{}})
  end
end
