defmodule SymphonyElixir.AppServerHandoffTest do
  use SymphonyElixir.TestSupport, async: false

  alias SymphonyElixir.Control
  alias SymphonyElixir.Control.HandoffInbox
  alias SymphonyElixir.TerminalHandoff

  setup do
    root = Path.join(System.tmp_dir!(), "handoff-rpc-#{System.unique_integer([:positive])}")
    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(root)
    workspaces = Path.join(root, "workspaces")
    destination = Path.join(workspaces, "issue")
    source = Path.join(root, "source")
    trace = Path.join(root, "trace.jsonl")
    fake = Path.join(root, "codex-fake")
    File.mkdir_p!(destination)
    File.mkdir_p!(source)
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(fake, """
    #!/usr/bin/env python3
    import json, os, sys
    for line in sys.stdin:
        request = json.loads(line)
        with open(#{inspect(trace)}, 'a') as output:
            output.write(json.dumps({'cwd': os.getcwd(), 'request': request}) + '\\n')
        method = request.get('method')
        if method == 'initialize':
            result = {}
        elif method == 'thread/read':
            result = {'thread': {'id': 'source-thread', 'cwd': #{inspect(source)}}}
        elif method == 'thread/fork':
            p = request['params']
            returned_model = p['model']
            result = {'thread': {'id': 'forked-thread'}, 'cwd': p['cwd'], 'model': returned_model, 'approvalPolicy': p['approvalPolicy'], 'sandbox': {'type': 'workspaceWrite'}}
        else:
            continue
        print(json.dumps({'id': request['id'], 'result': result}), flush=True)
    """)

    File.chmod!(fake, 0o755)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspaces, codex_command: "#{fake} app-server")
    %{root: root, destination: destination, source: source, trace: trace, fake: fake, workspaces: workspaces}
  end

  test "fork explicitly applies destination policy and verifies returned Luna metadata", context do
    assert {:ok, %{"thread" => %{"id" => "forked-thread"}}} =
             AppServer.fork_thread(context.destination, "source-thread", context.destination)

    trace = read_trace(context.trace)
    fork = Enum.find(trace, &(&1["request"]["method"] == "thread/fork"))
    params = fork["request"]["params"]
    assert params["model"] == "gpt-5.6-luna"
    assert params["cwd"] == context.destination
    assert params["sandbox"] == "workspace-write"
    assert Map.has_key?(params, "approvalPolicy")
    refute Enum.any?(trace, &(&1["request"]["method"] == "turn/start"))
  end

  test "fork refuses returned model drift", context do
    File.write!(
      context.fake,
      String.replace(File.read!(context.fake), "returned_model = p['model']", "returned_model = 'unexpected-model'")
    )

    assert {:error, :fork_configuration_mismatch} =
             AppServer.fork_thread(context.destination, "source-thread", context.destination)
  end

  test "source thread metadata is read from a separate validated directory", context do
    assert {:ok, %{"thread" => %{"cwd" => source}}} = AppServer.read_thread(context.source, "source-thread")
    assert source == context.source
    trace = read_trace(context.trace)
    assert Enum.all?(trace, &(&1["cwd"] == Path.join(context.workspaces, ".symphony-metadata")))
    refute Enum.any?(trace, &(&1["request"]["method"] == "turn/start"))
  end

  test "CLI queues a dirty Terminal handoff for the running daemon and actual fork RPC", context do
    for args <- [
          ["init", "-b", "main"],
          ["config", "user.name", "Handoff Test"],
          ["config", "user.email", "handoff@example.invalid"]
        ] do
      assert {_, 0} = System.cmd("git", ["-C", context.source | args], stderr_to_stdout: true)
    end

    tracked = Path.join(context.source, "work.txt")
    File.write!(tracked, "base
")
    assert {_, 0} = System.cmd("git", ["-C", context.source, "add", "."], stderr_to_stdout: true)
    assert {_, 0} = System.cmd("git", ["-C", context.source, "commit", "-m", "base"], stderr_to_stdout: true)
    File.write!(tracked, "unfinished work
")
    summary = Path.join(context.root, "summary.txt")
    File.write!(summary, "continue selected work")

    request = %{
      source_workspace: context.source,
      issue_id: "RPC-IMPORT",
      thread_id: "source-thread",
      summary_file: summary
    }

    options = [state_root: Path.join(context.root, "state")]

    control_opts = [name: nil, enabled: true, state_root: options[:state_root], workspace_root: context.workspaces]
    server = start_supervised!({Control, control_opts})

    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)

    Mix.Tasks.Symphony.TerminalHandoff.run([
      "--state-root",
      options[:state_root],
      "--source",
      context.source,
      "--issue",
      request.issue_id,
      "--thread",
      request.thread_id,
      "--summary",
      summary
    ])

    assert_receive {:mix_shell, :info, [response]}
    %{"request_id" => request_id, "status" => "queued"} = Jason.decode!(response)

    assert eventually(fn ->
             match?(
               {:ok, %{"status" => "complete"}},
               HandoffInbox.status(options[:state_root], request_id)
             )
           end),
           inspect({HandoffInbox.status(options[:state_root], request_id), Control.snapshot(server, request.issue_id), File.ls!(Path.join(options[:state_root], "handoff-inbox"))})

    assert %{thread_id: "forked-thread", handoff: true, handoff_status: :complete} =
             Control.snapshot(server, request.issue_id)

    assert {:ok, record} = TerminalHandoff.import(request, options)
    assert record["thread"] == "forked-thread"
    assert File.read!(Path.join(record["workspace"], "work.txt")) == "unfinished work
"
    assert File.read!(tracked) == "unfinished work
"
    trace = read_trace(context.trace)
    methods = Enum.map(trace, & &1["request"]["method"])
    assert "thread/read" in methods
    assert "thread/fork" in methods
    refute "turn/start" in methods
    refute Enum.any?(trace, &(&1["cwd"] == context.source))

    recovered =
      start_supervised!(
        Supervisor.child_spec(
          {SymphonyElixir.Control, name: nil, enabled: true, state_root: Path.join(context.root, "recovered-state"), workspace_root: context.workspaces},
          id: :recovered_control
        )
      )

    assert {:ok, ^record} =
             TerminalHandoff.import(request, Keyword.put(options, :control_server, recovered))

    assert %{thread_id: "forked-thread", handoff: true} = Control.snapshot(recovered, request.issue_id)
    assert read_trace(context.trace) == trace
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(25)
          eventually(fun, attempts - 1)
        )
  end

  defp read_trace(file), do: file |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
end
