defmodule SymphonyElixir.NativeInterruptionTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Control

  test "a callback registration failure stops the turn before completion" do
    port = synthetic_port()
    issue = %{identifier: "NATIVE-1", title: "interrupt", id: "issue"}

    session = %{
      port: port,
      metadata: %{},
      approval_policy: "never",
      auto_approve_requests: true,
      turn_sandbox_policy: %{},
      thread_id: "thread-1",
      model: nil,
      workspace: "/private/tmp",
      dynamic_tool_binding: %{tools: %{}}
    }

    try do
      assert {:error, :native_paused} =
               AppServer.run_turn(session, "stop", issue, on_turn_started: fn _turn -> {:error, :native_paused} end)
    after
      AppServer.stop_session(%{port: port})
    end
  end

  test "clearing a stale completion cannot remove a newer active turn" do
    root = Path.join(System.tmp_dir!(), "native-clear-#{System.unique_integer([:positive])}")

    {:ok, control} =
      Control.start_link(
        name: nil,
        enabled: true,
        state_root: Path.join(root, "state"),
        workspace_root: Path.join(root, "workspaces")
      )

    on_exit(fn ->
      if Process.alive?(control), do: GenServer.stop(control)
      File.rm_rf(root)
    end)

    assert :ok = Control.register_native_turn(control, "issue", self(), "thread-1", "turn-new")
    assert :ok = Control.clear_native_turn(control, "issue", "turn-old")
    assert :ok = Control.clear_native_turn(control, "issue", nil)
    assert %{owner: owner, thread_id: "thread-1", turn_id: "turn-new"} = :sys.get_state(control).runtime_owners["issue"]
    assert owner == self()
  end

  defp synthetic_port do
    script = ~S'''
    while IFS= read -r line; do
      case "$line" in
        *'"method":"turn/start"'*)
          printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-1"}}}'
          printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"completed"}}}'
          ;;
      esac
    done
    '''

    Port.open({:spawn_executable, ~c"/bin/sh"}, [:binary, :exit_status, line: 1_048_576, args: [~c"-c", script]])
  end
end
