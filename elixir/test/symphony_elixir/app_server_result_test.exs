defmodule SymphonyElixir.AppServerResultTest do
  use SymphonyElixir.TestSupport, async: false
  alias SymphonyElixir.Codex.AppServer

  test "only matching final output is decoded and schema is sent" do
    events = [
      item("{}", "other"),
      item("{}", "thread-result", "other"),
      completion("completed", "other"),
      completion("completed", "thread-result", "other"),
      item("{}", "thread-result", "turn-result", "commentary"),
      item(~s({"answer":42})),
      completion()
    ]

    {result, trace} = run_events(events)
    assert {:ok, %{output: %{"answer" => 42}}} = result
    assert trace =~ ~s("outputSchema":{"type":"object"})
  end

  test "missing and duplicate final messages are rejected" do
    assert {{:error, :missing_output}, _} = run_events([completion()])
    assert {{:error, :ambiguous_output}, _} = run_events([item("{}"), item("{}"), completion()])
  end

  test "non-object invalid and oversized output is rejected" do
    for text <- ["broken", "[]", "null", String.duplicate("x", 65_537)] do
      assert {{:error, :invalid_output}, _} = run_events([item(text), completion()])
    end
  end

  test "failed interrupted and missing completion status cannot approve a result" do
    for status <- ["failed", "interrupted", nil] do
      assert {{:error, :unsuccessful_turn}, _} = run_events([item("{}"), completion(status)])
    end

    assert {{:error, :invalid_turn_completion}, _} = run_events([item("{}"), %{"method" => "turn/completed"}])
  end

  test "reasoning and missing final phase do not supply a result" do
    reasoning = put_in(item("{}"), ["params", "item", "type"], "reasoning")
    assert {{:error, :missing_output}, _} = run_events([reasoning, item("{}", "thread-result", "turn-result", nil), completion()])
  end

  defp item(text, thread \\ "thread-result", turn \\ "turn-result", phase \\ "final_answer") do
    %{
      "method" => "item/completed",
      "params" => %{"completedAtMs" => 1, "threadId" => thread, "turnId" => turn, "item" => %{"id" => "item-result", "type" => "agentMessage", "phase" => phase, "text" => text}}
    }
  end

  defp completion(status \\ "completed", thread \\ "thread-result", turn \\ "turn-result") do
    %{"method" => "turn/completed", "params" => %{"threadId" => thread, "turn" => %{"id" => turn, "status" => status, "items" => []}}}
  end

  defp run_events(events) do
    root = Path.join(System.tmp_dir!(), "app-result-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    trace = Path.join(root, "trace")
    fake = Path.join(root, "fake")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    File.write!(Path.join(root, "events"), Enum.map_join(events, "\n", &Jason.encode!/1) <> "\n")

    File.write!(fake, """
    #!/bin/sh
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> "#{trace}"
      case "$line" in
        *initialize*) echo '{"id":1,"result":{}}' ;;
        *thread/start*) echo '{"id":2,"result":{"thread":{"id":"thread-result"}}}' ;;
        *turn/start*)
          echo '{"id":3,"result":{"turn":{"id":"turn-result"}}}'
          cat "#{root}/events"
          ;;
      esac
    done
    """)

    File.chmod!(fake, 0o755)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root, codex_command: "#{fake} app-server")
    issue = %SymphonyElixir.Tracker.Issue{id: "result", identifier: "RESULT-1", title: "result", state: "In Progress"}
    assert {:ok, session} = AppServer.start_session(workspace)

    result =
      try do
        AppServer.run_turn(session, "prompt", issue, output_schema: %{"type" => "object"})
      after
        AppServer.stop_session(session)
      end

    {result, File.read!(trace)}
  end
end
