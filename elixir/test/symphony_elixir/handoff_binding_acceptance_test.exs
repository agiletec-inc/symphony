defmodule SymphonyElixir.HandoffBindingAcceptanceTest do
  use SymphonyElixir.TestSupport, async: false
  alias SymphonyElixir.Control
  alias SymphonyElixir.Control.{HandoffBinding, HandoffInbox}

  @issue "11111111-1111-4111-8111-111111111111"
  @session "22222222-2222-4222-8222-222222222222"
  @config %{enabled: true, application_user_id: "app", organization_id: "org", project_id: "project"}

  setup do
    root = Path.join("/private/tmp", "binding-#{System.unique_integer([:positive])}")
    source = Path.join(root, "source")
    summary = Path.join(root, "summary.md")
    File.mkdir_p!(source)
    File.write!(summary, "selected terminal summary")
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      source: source,
      summary: summary,
      state_root: Path.join(root, "state"),
      workspaces: Path.join(root, "workspaces")
    }
  end

  test "queued Terminal handoff resolves canonical issue and binds a native session", ctx do
    owner = self()
    transport = transport(owner, :success)
    control = start_control(ctx, transport)
    {:ok, request_id} = submit(ctx)
    assert_receive {:imported_issue, @issue}, 2_000
    assert_receive {:create_session, %{input: %{issueId: @issue}}}, 2_000

    assert eventually(fn ->
             match?({:ok, %{"status" => "complete"}}, HandoffInbox.status(ctx.state_root, request_id))
           end)

    assert eventually(fn -> Control.snapshot(control, @issue)[:projection_pending] == false end)

    assert %{
             native_session_id: @session,
             thread_id: "forked-thread",
             handoff: true,
             state: :waiting_user,
             session_creation_pending: false
           } = Control.snapshot(control, @issue)

    refute Control.snapshot(control, "TEST-1")[:handoff]
    assert :empty = Control.take_native_prompt(control, @issue)
    assert_receive {:initial_activity, %{input: %{content: %{type: "thought", body: body}}}}, 2_000
    assert body == "依頼を受け付けました。実行を準備しています。"
    refute body =~ "selected terminal summary"
    refute_receive {:create_session, _}, 50

    late_created = %{
      "action" => "created",
      "_delivery" => "late-created",
      "promptContext" => "generic issue context",
      "agentSession" => %{"id" => @session, "issue" => %{"id" => @issue}}
    }

    assert :ok = Control.accept_native(control, late_created, "late-hash", graphql_client: transport)
    assert :empty = Control.take_native_prompt(control, @issue)
    replacement = put_in(late_created, ["agentSession", "id"], "other-session") |> Map.put("_delivery", "replacement")

    assert {:error, :native_session_conflict} =
             Control.accept_native(control, replacement, "replacement-hash", graphql_client: transport)

    assert %{thread_id: "forked-thread", native_session_id: @session} = Control.snapshot(control, @issue)
  end

  test "ambiguous session creation stays unresolved after restart without another mutation", ctx do
    transport = transport(self(), :ambiguous)
    control = start_control(ctx, transport)
    {:ok, request_id} = submit(ctx)
    assert_receive {:create_session, _}, 2_000
    assert eventually(fn -> match?({:ok, %{"status" => "failed"}}, HandoffInbox.status(ctx.state_root, request_id)) end)
    assert %{session_creation_pending: true} = Control.snapshot(control, @issue)
    opts = [config: @config, graphql: transport]
    assert {:error, :session_creation_unresolved} = HandoffBinding.connect(control, @issue, opts)
    :ok = stop_supervised(Control)
    restarted = start_control(ctx, transport)
    assert {:error, :session_creation_unresolved} = HandoffBinding.connect(restarted, @issue, opts)
    refute_receive {:create_session, _}, 100

    recovered_event = %{
      "action" => "created",
      "_delivery" => "recovered-created",
      "agentSession" => %{"id" => @session, "issue" => %{"id" => @issue}}
    }

    assert :ok = Control.accept_native(restarted, recovered_event, "recovered-hash", graphql_client: transport)
    assert :ok = HandoffBinding.connect(restarted, @issue, opts)
    assert %{session_creation_pending: false, native_session_id: @session} = Control.snapshot(restarted, @issue)
    refute_receive {:create_session, _}, 50
  end

  test "a foreign project is rejected before importing or creating a session", ctx do
    transport = transport(self(), :foreign)
    control = start_control(ctx, transport)
    {:ok, request_id} = submit(ctx)
    assert eventually(fn -> match?({:ok, %{"status" => "failed"}}, HandoffInbox.status(ctx.state_root, request_id)) end)
    refute_receive {:imported_issue, _}
    refute_receive {:create_session, _}
    assert Control.snapshot(control, @issue) == %{state: :ready}
  end

  defp start_control(ctx, transport) do
    test_pid = self()

    importer = fn request, opts ->
      send(test_pid, {:imported_issue, request.issue_id})
      workspace = Path.join(ctx.workspaces, request.issue_id)
      File.mkdir_p!(workspace)

      record = %{
        issue: request.issue_id,
        thread: "forked-thread",
        workspace: workspace,
        summary: "selected terminal summary"
      }

      :ok = Control.import_handoff(opts[:control_server], request.issue_id, record)
      {:ok, record}
    end

    control_opts = [
      name: nil,
      enabled: true,
      native_session_config: @config,
      state_root: ctx.state_root,
      workspace_root: ctx.workspaces,
      graphql_client: transport,
      handoff_importer: importer
    ]

    start_supervised!({Control, control_opts})
  end

  defp submit(ctx) do
    HandoffInbox.submit(ctx.state_root, %{
      source_workspace: ctx.source,
      summary_file: ctx.summary,
      issue_id: "TEST-1",
      thread_id: "selected-thread"
    })
  end

  defp transport(owner, mode) do
    fn query, variables, _opts ->
      cond do
        String.contains?(query, "TerminalSessionResolve") ->
          project = project_for(mode)

          {:ok,
           %{
             "data" => %{
               "viewer" => %{"id" => "app", "organization" => %{"id" => "org"}},
               "issue" => %{"id" => @issue, "identifier" => "TEST-1", "project" => %{"id" => project}}
             }
           }}

        String.contains?(query, "agentSessionCreateOnIssue") ->
          send(owner, {:create_session, variables})
          session_create_response(mode)

        String.contains?(query, "agentActivityCreate") ->
          send(owner, {:initial_activity, variables})

          {:ok,
           %{
             "data" => %{
               "agentActivityCreate" => %{
                 "success" => true,
                 "agentActivity" => %{"id" => variables.input.id, "agentSession" => %{"id" => @session}}
               }
             }
           }}

        String.contains?(query, "activities(") ->
          {:ok, %{"data" => %{"agentSession" => %{"id" => @session, "activities" => %{"nodes" => []}}}}}

        true ->
          {:ok, %{"data" => %{"agentSession" => session()}}}
      end
    end
  end

  defp session,
    do: %{
      "id" => @session,
      "appUser" => %{"id" => "app"},
      "issue" => %{"id" => @issue, "project" => %{"id" => "project"}}
    }

  defp project_for(:foreign), do: "foreign"

  defp project_for(_mode), do: "project"

  defp session_create_response(:ambiguous), do: {:error, :timeout}

  defp session_create_response(_mode),
    do: {:ok, %{"data" => %{"agentSessionCreateOnIssue" => %{"success" => true, "agentSession" => session()}}}}

  defp eventually(fun, attempts \\ 150)
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
