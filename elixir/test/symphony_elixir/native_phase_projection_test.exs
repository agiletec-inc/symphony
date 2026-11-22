defmodule SymphonyElixir.NativePhaseProjectionTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Control
  alias SymphonyElixir.Control.Outbox

  setup do
    root = Path.join("/private/tmp", "native-phase-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "actual state transitions emit fixed ordered activities and deduplicate repeats", ctx do
    transport = transport(self())
    control = start_control(ctx.root, transport)
    assert :ok = Control.accept_native(control, created(), "hash", graphql_client: transport)
    assert eventually(fn -> Control.snapshot(control, "issue")[:projection_pending] == false end)
    assert {:ok, "RAW_CONTEXT"} = Control.take_native_prompt(control, "issue")
    assert :ok = Control.acknowledge_native_prompt(control, "issue")
    assert :ok = Control.reserve_run(control, "issue")

    assert :ok =
             Control.publish(control, "issue", {:running, %{error: "PRIVATE_TEST_DETAIL", model: "PRIVATE_TEST_MODEL"}})

    assert :ok = Control.finish_run(control, "issue", :normal)
    assert :ok = Control.publish(control, "issue", {:waiting_user, %{}})
    assert eventually(fn -> Control.snapshot(control, "issue")[:native_pending_activities] == %{} end)
    activities = receive_activities(3)
    assert Enum.map(activities, & &1.content.type) == ["thought", "thought", "elicitation"]

    assert Enum.map(activities, & &1.content.body) == [
             "依頼を受け付けました。実行を準備しています。",
             "実行を開始しました。",
             "次の指示または判断を、このセッションに入力してください。"
           ]

    refute inspect(activities) =~ "PRIVATE_TEST"
    refute inspect(activities) =~ "RAW_CONTEXT"
    refute_receive {:activity, _}, 100
    assert :ok = Control.publish(control, "issue", {:failed, %{error: "PRIVATE_TEST_ERROR"}})
    assert_receive {:activity, %{content: %{type: "error", body: "実行に失敗しました。再開には原因の確認が必要です。"}}}, 2_000
  end

  test "primary state recovers initial and later phase activities before sender activation", ctx do
    transport = transport(self())

    outbox =
      start_supervised!({Outbox, name: nil, state_root: ctx.root, owner: self(), transport: transport, paused: true})

    control = start_control(ctx.root, transport, outbox_server: outbox)
    assert :ok = Control.accept_native(control, created(), "hash", graphql_client: transport)
    assert {:ok, "RAW_CONTEXT"} = Control.take_native_prompt(control, "issue")
    assert :ok = Control.acknowledge_native_prompt(control, "issue")
    assert :ok = Control.publish(control, "issue", {:running, %{}})
    assert :ok = Control.publish(control, "issue", {:waiting_user, %{}})
    record = Control.snapshot(control, "issue")

    ids = [
      record.native_activity_id
      | record.native_pending_activities |> Map.values() |> Enum.sort_by(& &1.order) |> Enum.map(& &1.id)
    ]

    refute_receive {:activity, _}, 50
    :ok = stop_supervised(Control)
    :ok = stop_supervised(Outbox)
    File.rm!(Path.join(ctx.root, "native-outbox.term"))
    disabled = start_control(ctx.root, transport, enabled: false)
    assert Control.snapshot(disabled, "issue")[:last_native_phase] == :waiting_user
    refute_receive {:activity, _}, 50
    :ok = stop_supervised(Control)
    restarted = start_control(ctx.root, transport)
    activities = receive_activities(3)
    assert Enum.map(activities, & &1.id) == ids
    assert Enum.map(activities, & &1.content.type) == ["thought", "thought", "elicitation"]
    assert eventually(fn -> Control.snapshot(restarted, "issue")[:native_pending_activities] == %{} end)
    assert :ok = Control.publish(restarted, "issue", {:waiting_user, %{}})
    refute_receive {:activity, _}, 100
  end

  test "unknown phase is refused instead of forwarding arbitrary content", ctx do
    transport = transport(self())
    outbox = start_supervised!({Outbox, name: nil, state_root: ctx.root, owner: self(), transport: transport})

    item = %{
      id: Ecto.UUID.generate(),
      activity_id: Ecto.UUID.generate(),
      session_id: "session",
      phase: :prompt,
      body: "PRIVATE_TEST_BODY",
      content: %{type: "prompt", body: "PRIVATE_TEST_BODY"}
    }

    assert {:error, _} = Outbox.enqueue(outbox, item, transport, self())
    refute_receive {:activity, _}, 100
    assert :ok = Outbox.enqueue(outbox, %{item | phase: :running}, transport, self())
    assert_receive {:activity, %{content: %{type: "thought", body: "実行を開始しました。"}}}, 1_000
  end

  test "repeated delivery failures retain a future retry and recover the same activity", ctx do
    id = Ecto.UUID.generate()
    entry = %{id: id, activity_id: id, session_id: "session", phase: :running, order: 1, attempts: 4, next_at: 0}
    file = Path.join(ctx.root, "native-outbox.term")
    File.write!(file, :erlang.term_to_binary(%{id => entry}))
    owner = self()

    failed = fn _query, variables, _opts ->
      send(owner, {:failed_read, variables.activityId})
      {:error, :unavailable}
    end

    outbox = start_supervised!({Outbox, name: nil, state_root: ctx.root, owner: self(), transport: failed})
    assert_receive {:failed_read, ^id}, 1_000
    assert_receive {:native_outbox_delayed, ^id}, 1_000
    saved = :sys.get_state(outbox).entries[id]
    assert saved.attempts == 5
    assert saved.next_at > System.system_time(:millisecond) + 58_000
    refute_receive {:failed_read, _}, 100
    :ok = stop_supervised(Outbox)
    # Model an elapsed durable deadline before restarting the sender.
    File.write!(file, :erlang.term_to_binary(%{id => %{saved | next_at: 0}}))

    recovered =
      start_supervised!({Outbox, name: nil, state_root: ctx.root, owner: self(), transport: transport(self())})

    assert_receive {:activity, %{id: ^id, content: %{type: "thought", body: "実行を開始しました。"}}}, 1_000
    assert_receive {:native_outbox_confirmed, ^id}, 1_000
    assert :sys.get_state(recovered).entries == %{}
  end

  test "an already queued instruction does not emit an unnecessary user judgment request", ctx do
    transport = transport(self())
    control = start_control(ctx.root, transport)
    assert :ok = Control.accept_native(control, created(), "hash", graphql_client: transport)
    assert eventually(fn -> Control.snapshot(control, "issue")[:projection_pending] == false end)
    assert {:ok, "RAW_CONTEXT"} = Control.take_native_prompt(control, "issue")
    assert :ok = Control.acknowledge_native_prompt(control, "issue")
    assert :ok = Control.reserve_run(control, "issue")

    followup = %{
      "action" => "prompted",
      "_delivery" => "followup",
      "agentSession" => %{"id" => "session", "issue" => %{"id" => "issue"}},
      "agentActivity" => %{"id" => "next-input", "content" => %{"body" => "continue"}}
    }

    assert :ok = Control.accept_native(control, followup, "followup-hash", graphql_client: transport)
    assert :ok = Control.publish(control, "issue", {:waiting_user, %{}})
    assert :ok = Control.finish_run(control, "issue", :normal)
    assert %{state: :ready} = Control.snapshot(control, "issue")
    assert :ok = Control.reserve_run(control, "issue")
    assert {:ok, "continue"} = Control.take_native_prompt(control, "issue")
    assert :ok = Control.acknowledge_native_prompt(control, "issue")
    assert :ok = Control.finish_run(control, "issue", :normal)
    assert eventually(fn -> Control.snapshot(control, "issue")[:native_pending_activities] == %{} end)

    assert Enum.map(receive_activities(5), & &1.content.type) == [
             "thought",
             "thought",
             "thought",
             "thought",
             "elicitation"
           ]
  end

  defp start_control(root, transport, extra \\ []) do
    start_supervised!(
      {Control,
       Keyword.merge(
         [
           name: nil,
           enabled: true,
           state_root: root,
           workspace_root: Path.join(root, "separate-workspaces"),
           native_session_config: %{enabled: false},
           graphql_client: transport
         ],
         extra
       )}
    )
  end

  defp created,
    do: %{
      "action" => "created",
      "_delivery" => "created",
      "agentSession" => %{"id" => "session", "issue" => %{"id" => "issue"}},
      "promptContext" => "RAW_CONTEXT"
    }

  defp transport(owner) do
    fn query, variables, _opts ->
      if String.contains?(query, "agentActivityCreate") do
        send(owner, {:activity, variables.input})

        {:ok,
         %{
           "data" => %{
             "agentActivityCreate" => %{
               "success" => true,
               "agentActivity" => %{
                 "id" => variables.input.id,
                 "agentSession" => %{"id" => variables.input.agentSessionId}
               }
             }
           }
         }}
      else
        {:ok, %{"data" => %{"agentSession" => %{"id" => variables.id, "activities" => %{"nodes" => []}}}}}
      end
    end
  end

  defp receive_activities(n),
    do:
      Enum.map(1..n, fn _ ->
        assert_receive {:activity, input}, 2_000
        input
      end)

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
