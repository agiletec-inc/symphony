defmodule SymphonyElixir.NativeTransportTimeoutTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Linear.Client

  test "native scope HTTP waits are bounded without transport retries" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])
    {:ok, {_ip, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    owner = self()

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        send(owner, :scope_connected)

        receive do
          :finish -> :gen_tcp.close(socket)
        after
          2_000 -> :gen_tcp.close(socket)
        end
      end)

    started = System.monotonic_time(:millisecond)

    result =
      Client.graphql("query ScopeTimeout { viewer { id } }", %{},
        tracker_settings: %{api_key: "test-only-key", endpoint: "http://127.0.0.1:#{port}"},
        request_timeout_ms: 100
      )

    assert {:error, _} = result
    assert System.monotonic_time(:millisecond) - started < 1_500
    assert_received :scope_connected
    send(task.pid, :finish)
    Task.await(task, 1_000)
  end
end
