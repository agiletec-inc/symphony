defmodule SymphonyElixir.NativePauseTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Control
  alias SymphonyElixir.Control.ActivityProjection

  defp start_control do
    root = Path.join("/private/tmp", "pause-#{System.unique_integer([:positive])}")
    {:ok, pid} = Control.start_link(name: nil, enabled: true, graphql_client: fn _, _, _ -> {:error, :offline} end, state_root: Path.join(root, "state"), workspace_root: Path.join(root, "workspaces"))

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf(root)
    end)

    {pid, root}
  end

  defp created(issue), do: %{"action" => "created", "_delivery" => "created", "agentSession" => %{"id" => "session", "issue" => %{"id" => issue}}}

  defp prompted(issue, id, body, signal \\ nil) do
    %{"action" => "prompted", "_delivery" => id, "agentSession" => %{"id" => "session", "issue" => %{"id" => issue}}, "agentActivity" => %{"id" => id, "content" => %{"body" => body}}}
    |> then(fn event -> if signal, do: put_in(event["agentActivity"]["signal"], signal), else: event end)
  end

  test "stop activity pauses and is never executable" do
    {control, _} = start_control()
    assert :ok = Control.accept_native(control, created("issue"), "created")
    assert :ok = Control.register_native_turn(control, "issue", self(), "thread-1", "turn-1")
    assert :ok = Control.accept_native(control, prompted("issue", "stop", "stop", "stop"), "stop")
    assert_receive {:native_interrupt, "thread-1", "turn-1"}
    assert %{paused: true, state: :waiting_user} = Control.snapshot(control, "issue")
    assert :empty = Control.take_native_prompt(control, "issue")
  end

  test "resume instruction clears pause while preserving queued input" do
    {control, _} = start_control()
    Control.accept_native(control, created("issue"), "created")
    assert :ok = Control.accept_native(control, prompted("issue", "stop", "Stop", "stop"), "stop")
    assert :ok = Control.accept_native(control, prompted("issue", "normal", "keep"), "normal")
    assert %{paused: true, state: :waiting_user} = Control.snapshot(control, "issue")
    Control.accept_native(control, prompted("issue", "resume", "/resume"), "resume")
    assert %{paused: false, state: :ready} = Control.snapshot(control, "issue")
    assert {:ok, "keep"} = Control.take_native_prompt(control, "issue")
    assert {:ok, "/resume"} = Control.take_native_prompt(control, "issue")
    assert :empty = Control.take_native_prompt(control, "issue")
  end

  test "duplicate delivery does not duplicate stop or prompt" do
    {control, _} = start_control()
    event = created("issue")
    Control.accept_native(control, event, "created")
    stop = prompted("issue", "stop", "stop", "stop")
    Control.accept_native(control, stop, "stop")
    Control.accept_native(control, stop, "stop")
    assert %{paused: true, prompts: [%{id: "stop"}]} = Control.snapshot(control, "issue")
  end

  test "an old resume delivery cannot undo a newer stop" do
    {control, _} = start_control()
    assert :ok = Control.accept_native(control, created("issue"), "created")
    assert :ok = Control.accept_native(control, prompted("issue", "stop-1", "Stop", "stop"), "stop-1")
    resume = prompted("issue", "resume-1", " RESUME ")
    assert :ok = Control.accept_native(control, resume, "resume-1")
    assert %{paused: false} = Control.snapshot(control, "issue")
    assert :ok = Control.accept_native(control, prompted("issue", "stop-2", "Stop", "stop"), "stop-2")
    assert :ok = Control.accept_native(control, resume, "resume-1")
    assert :ok = Control.accept_native(control, Map.put(resume, "_delivery", "redelivery"), "redelivery-hash")
    assert %{paused: true, state: :waiting_user, last_native_phase: :paused} = Control.snapshot(control, "issue")
    assert {:ok, %{type: "elicitation", body: body}} = ActivityProjection.content(:paused)
    assert body =~ "実行中の処理には停止を要求しました"
    assert body =~ "再開"
  end

  test "pause survives owner restart" do
    {control, root} = start_control()
    Control.accept_native(control, created("issue"), "created")
    Control.accept_native(control, prompted("issue", "stop", "stop", "stop"), "stop")
    GenServer.stop(control)

    {:ok, replacement} =
      Control.start_link(name: nil, enabled: true, graphql_client: fn _, _, _ -> {:error, :offline} end, state_root: Path.join(root, "state"), workspace_root: Path.join(root, "workspaces"))

    assert %{paused: true, state: :waiting_user} = Control.snapshot(replacement, "issue")
    on_exit(fn -> if Process.alive?(replacement), do: GenServer.stop(replacement) end)
    assert :ok = Control.accept_native(replacement, prompted("issue", "resume", " 再開 "), "resume")
    assert %{paused: false, state: :ready} = Control.snapshot(replacement, "issue")
    assert {:ok, " 再開 "} = Control.take_native_prompt(replacement, "issue")
  end
end
