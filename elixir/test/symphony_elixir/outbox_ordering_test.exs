defmodule SymphonyElixir.Control.OutboxOrderingTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Control.Outbox

  defp transport(parent, failures \\ %{}) do
    fn query, variables, _opts ->
      if String.contains?(query, "agentActivityCreate") do
        id = get_in(variables, [:input, :id])
        send(parent, {:mutation, id, get_in(variables, [:input, :content])})

        mutation_response(failures, id, variables)
      else
        {:ok, %{"data" => %{"agentSession" => %{"id" => variables.id, "activities" => %{"nodes" => []}}}}}
      end
    end
  end

  defp mutation_response(failures, id, variables) do
    if Map.get(failures, id, 0) > 0 do
      {:error, :failed}
    else
      {:ok,
       %{
         "data" => %{
           "agentActivityCreate" => %{
             "success" => true,
             "agentActivity" => %{"id" => id, "agentSession" => %{"id" => variables.input.agentSessionId}}
           }
         }
       }}
    end
  end

  test "paused startup restores earlier order before later order" do
    root = Path.join(System.tmp_dir!(), "outbox-order-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, pid} = Outbox.start_link(state_root: root, paused: true)

    assert :ok =
             Outbox.enqueue(
               pid,
               %{id: "later", order: 1, session_id: "s", activity_id: "a1", body: "later"},
               transport(self()),
               self()
             )

    assert :ok =
             Outbox.enqueue(
               pid,
               %{id: "early", order: 0, session_id: "s", activity_id: "a0", body: "early"},
               transport(self()),
               self()
             )

    assert :ok = Outbox.activate(pid)
    assert_receive {:mutation, first_id, _}, 500
    assert first_id == "a0"
    assert_receive {:mutation, second_id, _}, 500
    assert second_id == "a1"
    GenServer.stop(pid)
  end

  test "same session remains behind failed head while another session proceeds" do
    root = Path.join(System.tmp_dir!(), "outbox-order-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    transport = transport(self(), %{"a0" => 1})
    {:ok, pid} = Outbox.start_link(state_root: root, transport: transport)
    Outbox.enqueue(pid, %{id: "head", order: 0, session_id: "s", activity_id: "a0", body: "head"}, transport, self())
    Outbox.enqueue(pid, %{id: "tail", order: 1, session_id: "s", activity_id: "a1", body: "tail"}, transport, self())

    Outbox.enqueue(
      pid,
      %{id: "other", order: 0, session_id: "other", activity_id: "b0", body: "other"},
      transport,
      self()
    )

    assert_receive {:mutation, "a0", _}, 500
    assert_receive {:mutation, "b0", _}, 500
    refute_receive {:mutation, "a1", _}, 50
    GenServer.stop(pid)
  end

  test "rejects negative order and preserves body-only thought content" do
    root = Path.join(System.tmp_dir!(), "outbox-order-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, pid} = Outbox.start_link(state_root: root, transport: transport(self()))
    assert {:error, :invalid_order} = Outbox.enqueue(pid, %{id: "bad", order: -1}, transport(self()), self())

    assert :ok =
             Outbox.enqueue(
               pid,
               %{id: "body", session_id: "s", activity_id: "body-a", body: "hello"},
               transport(self()),
               self()
             )

    assert_receive {:mutation, "body-a", %{type: "thought", body: "hello"}}, 500
    GenServer.stop(pid)
  end

  test "restart preserves explicit order" do
    root = Path.join(System.tmp_dir!(), "outbox-order-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, first} = Outbox.start_link(state_root: root, paused: true)

    assert :ok =
             Outbox.enqueue(
               first,
               %{id: "later", order: 1, session_id: "s", activity_id: "a1", body: "later"},
               transport(self()),
               self()
             )

    GenServer.stop(first)
    {:ok, second} = Outbox.start_link(state_root: root, paused: true)

    assert :ok =
             Outbox.enqueue(
               second,
               %{id: "early", order: 0, session_id: "s", activity_id: "a0", body: "early"},
               transport(self()),
               self()
             )

    assert :ok = Outbox.activate(second)
    assert_receive {:mutation, first_id, _}, 500
    assert first_id == "a0"
    assert_receive {:mutation, second_id, _}, 500
    assert second_id == "a1"
    GenServer.stop(second)
  end
end
