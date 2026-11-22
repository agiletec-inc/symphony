defmodule SymphonyElixir.NativeOutboxAcceptanceTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Control

  test "a blocked Linear publication cannot block durable control input or snapshots" do
    root = Path.join(System.tmp_dir!(), "outbox-independent-#{System.unique_integer([:positive])}")
    control = start_supervised!({Control, name: nil, enabled: true, state_root: Path.join(root, "state"), workspace_root: Path.join(root, "workspaces")})
    on_exit(fn -> File.rm_rf!(root) end)
    owner = self()
    issue = "issue-outbox"
    session = "session-outbox"

    graphql = fn query, variables, _opts ->
      if String.contains?(query, "agentActivityCreate") do
        id = variables.input.id
        send(owner, {:publication_waiting, self(), id})

        receive do
          :complete_publication ->
            {:ok, %{"data" => %{"agentActivityCreate" => %{"success" => true, "agentActivity" => %{"id" => id, "agentSession" => %{"id" => session}}}}}}
        after
          5_000 -> {:error, :test_timeout}
        end
      else
        {:ok, %{"data" => %{"agentSession" => %{"id" => session, "activities" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}}}}}
      end
    end

    event = %{"action" => "created", "_delivery" => "delivery-outbox", "agentSession" => %{"id" => session, "issue" => %{"id" => issue}}, "promptContext" => "work"}
    task = Task.async(fn -> Control.accept_native(control, event, "body-hash", graphql_client: graphql) end)
    assert Task.await(task, 1_000) == :ok
    assert_receive {:publication_waiting, sender, activity_id}, 1_000
    snapshot = GenServer.call(control, {:snapshot, issue}, 500)
    assert snapshot.projection_pending
    assert snapshot.native_activity_id == activity_id
    assert :ok = Control.accept_native(control, event, "body-hash", graphql_client: graphql)
    refute_receive {:publication_waiting, _, _}, 100
    refute Control.dispatchable?(control, issue)
    send(sender, :complete_publication)
    assert_eventually(fn -> Control.snapshot(control, issue)[:projection_pending] == false end)
    assert :ok = Control.accept_native(control, event, "body-hash", graphql_client: graphql)
    refute_receive {:publication_waiting, _, _}, 100
  end

  test "an unavailable reconciliation read never creates another activity" do
    root = Path.join(System.tmp_dir!(), "outbox-reconcile-#{System.unique_integer([:positive])}")
    control = start_supervised!({Control, name: nil, enabled: true, state_root: Path.join(root, "state"), workspace_root: Path.join(root, "workspaces")})
    on_exit(fn -> File.rm_rf!(root) end)
    owner = self()

    graphql = fn query, _variables, _opts ->
      if String.contains?(query, "agentActivityCreate"), do: send(owner, :unexpected_create), else: send(owner, :reconcile_read)
      {:error, :provider_unavailable}
    end

    event = %{"action" => "created", "_delivery" => "unavailable-delivery", "agentSession" => %{"id" => "unavailable-session", "issue" => %{"id" => "unavailable-issue"}}}
    assert :ok = Control.accept_native(control, event, "unavailable-hash", graphql_client: graphql)
    assert_receive :reconcile_read, 1_000
    refute_receive :unexpected_create, 300
    assert Control.snapshot(control, "unavailable-issue").projection_pending
    refute Control.dispatchable?(control, "unavailable-issue")
  end

  test "restart resumes saved pending activity without another webhook" do
    root = Path.join(System.tmp_dir!(), "outbox-restart-#{System.unique_integer([:positive])}")
    base = [name: nil, enabled: true, state_root: Path.join(root, "state"), workspace_root: Path.join(root, "workspaces")]
    owner = self()

    first = fn query, vars, _opts ->
      if String.contains?(query, "agentActivityCreate") do
        send(owner, {:first_activity, vars.input.id})
        {:ok, %{"data" => %{"agentActivityCreate" => %{"success" => false}}}}
      else
        {:ok, %{"data" => %{"agentSession" => %{"id" => "restart-session", "activities" => %{"nodes" => []}}}}}
      end
    end

    {:ok, control} = Control.start_link(base)
    on_exit(fn -> if Process.alive?(control), do: GenServer.stop(control) end)
    event = %{"action" => "created", "_delivery" => "restart-delivery", "agentSession" => %{"id" => "restart-session", "issue" => %{"id" => "restart-issue"}}}
    assert :ok = Control.accept_native(control, event, "restart-hash", graphql_client: first)
    assert_receive {:first_activity, activity_id}, 1_000
    assert Control.snapshot(control, "restart-issue").projection_pending
    GenServer.stop(control)
    # Simulate a crash after the canonical Control record was written but before enqueue persisted.
    File.rm!(Path.join([root, "state", "native-outbox.term"]))

    disabled_transport = fn _, _, _ ->
      send(owner, :disabled_io)
      {:error, :disabled}
    end

    {:ok, disabled} = Control.start_link(base |> Keyword.put(:enabled, false) |> Keyword.put(:graphql_client, disabled_transport))
    assert {:error, :control_disabled} = Control.accept_native(disabled, event, "restart-hash", graphql_client: disabled_transport)
    refute_receive :disabled_io, 100
    GenServer.stop(disabled)

    recovered = fn query, vars, _opts ->
      if String.contains?(query, "agentActivityCreate") do
        send(owner, {:recovered_activity, vars.input.id})
        {:ok, %{"data" => %{"agentActivityCreate" => %{"success" => true, "agentActivity" => %{"id" => vars.input.id, "agentSession" => %{"id" => "restart-session"}}}}}}
      else
        {:ok, %{"data" => %{"agentSession" => %{"id" => "restart-session", "activities" => %{"nodes" => []}}}}}
      end
    end

    {:ok, replacement} = Control.start_link(Keyword.put(base, :graphql_client, recovered))

    on_exit(fn ->
      if Process.alive?(replacement), do: GenServer.stop(replacement)
      File.rm_rf!(root)
    end)

    assert_receive {:recovered_activity, ^activity_id}, 1_500
    assert_eventually(fn -> Control.snapshot(replacement, "restart-issue")[:projection_pending] == false end)
  end

  defp assert_eventually(fun, attempts \\ 40)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(25)
          assert_eventually(fun, attempts - 1)
        )
  end
end
