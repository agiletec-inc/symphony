defmodule SymphonyElixir.LinearAgentSessionAcceptanceTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias SymphonyElixir.Control

  @endpoint SymphonyElixirWeb.Endpoint
  @secret "native-test-secret"
  @session_id "11111111-1111-4111-8111-111111111111"
  @issue_id "22222222-2222-4222-8222-222222222222"

  setup do
    root = Path.join(System.tmp_dir!(), "native-gate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    control =
      start_supervised!({Control, name: nil, enabled: true, state_root: Path.join(root, "state"), workspace_root: Path.join(root, "workspaces")})

    owner = self()
    previous = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    endpoint_config =
      previous
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.put(:linear_agent_session_control,
        enabled: true,
        webhook_secret: @secret,
        organization_id: "org-1",
        application_user_id: "app-user-1",
        oauth_client_id: "oauth-client-1",
        project_id: "project-1",
        control_server: control,
        interrupt: fn issue ->
          send(owner, {:interrupt, issue})
          :ok
        end,
        graphql_client: fn query, variables, _opts ->
          send(owner, {:graphql_called, query, variables})

          cond do
            String.contains?(query, "agentActivityCreate") ->
              send(owner, {:ack_disk_snapshot, File.read(Path.join([root, "state", "records.term"]))})
              input = variables[:input] || variables["input"]
              id = input[:id] || input["id"]

              {:ok,
               %{
                 "data" => %{
                   "agentActivityCreate" => %{
                     "success" => true,
                     "agentActivity" => %{"id" => id, "agentSession" => %{"id" => @session_id}}
                   }
                 }
               }}

            String.contains?(query, "activities") ->
              {:ok,
               %{
                 "data" => %{
                   "agentSession" => %{
                     "id" => @session_id,
                     "activities" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}
                   }
                 }
               }}

            true ->
              {:ok,
               %{
                 "data" => %{
                   "agentSession" => %{
                     "id" => @session_id,
                     "appUser" => %{"id" => "app-user-1"},
                     "issue" => %{"id" => @issue_id, "project" => %{"id" => "project-1"}}
                   }
                 }
               }}
          end
        end
      )

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({@endpoint, []})

    on_exit(fn -> Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, previous) end)
    on_exit(fn -> File.rm_rf!(root) end)
    %{control: control, root: root}
  end

  @tag :terminal_binding
  test "a signed second session cannot replace the existing issue binding", %{control: control} do
    assert post_signed(Jason.encode!(created_event())).status == 200
    endpoint = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint)
    native = Keyword.fetch!(endpoint, :linear_agent_session_control)
    original = Keyword.fetch!(native, :graphql_client)

    graphql = fn query, variables, opts ->
      if String.contains?(query, "SymphonyNativeScope") do
        {:ok,
         %{
           "data" => %{
             "agentSession" => %{
               "id" => variables.id,
               "appUser" => %{"id" => "app-user-1"},
               "issue" => %{"id" => @issue_id, "project" => %{"id" => "project-1"}}
             }
           }
         }}
      else
        original.(query, variables, opts)
      end
    end

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      Keyword.put(endpoint, :linear_agent_session_control, Keyword.put(native, :graphql_client, graphql))
    )

    replacement = put_in(created_event(), ["agentSession", "id"], "33333333-3333-4333-8333-333333333333")

    assert post_signed(Jason.encode!(replacement), [{"linear-delivery", "44444444-4444-4444-8444-444444444444"}]).status ==
             409

    assert %{native_session_id: @session_id} = Control.snapshot(control, @issue_id)
  end

  test "disabled native ingress is a 404 and has no control side effect" do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint)

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      Keyword.put(endpoint_config, :linear_agent_session_control, enabled: false)
    )

    body = Jason.encode!(created_event())
    response = post_signed(body)

    assert response.status == 404
    refute_received {:linear_agent_session, _}
  end

  test "accepted created event persists ready state and emits one deterministic thought", %{control: control} do
    body = Jason.encode!(created_event())
    response = post_signed(body)

    assert response.status == 200
    assert %{native_session_id: @session_id, prompt_context: "inspect issue"} = Control.snapshot(control, @issue_id)
    variables = receive_activity_variables()
    input = variables[:input] || variables["input"]
    content = input[:content] || input["content"]
    assert (content[:type] || content["type"]) == "thought"
    assert (content[:body] || content["body"]) == "依頼を受け付けました。実行を準備しています。"
    id = input[:id] || input["id"]
    assert id =~ ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    assert (input[:agentSessionId] || input["agentSessionId"]) == @session_id
    assert_receive {:ack_disk_snapshot, {:ok, durable}}
    assert %{native_activity_id: ^id, projection_pending: true} = :erlang.binary_to_term(durable, [:safe])[@issue_id]
    await_projection(control, @issue_id)
    assert %{projection_pending: false} = Control.snapshot(control, @issue_id)
  end

  test "same delivery with changed raw body is refused without a second dispatch" do
    first = Jason.encode!(created_event())
    assert post_signed(first).status == 200

    changed = Jason.encode!(created_event("changed prompt"))
    assert post_signed(changed).status in 400..499
    refute_received {:linear_agent_session, %{action: :created, prompt_context: "changed prompt"}}
  end

  test "a replayed valid payload with a new delivery id is acknowledged once", %{control: control} do
    body = Jason.encode!(created_event())
    assert post_signed(body).status == 200
    assert post_signed(body, [{"linear-delivery", "44444444-4444-4444-8444-444444444444"}]).status == 200

    assert %{native_session_id: @session_id} = Control.snapshot(control, @issue_id)
  end

  test "stale signed body timestamp and malformed delivery are refused before GraphQL" do
    stale =
      created_event() |> Map.put("webhookTimestamp", System.system_time(:millisecond) - 120_000) |> Jason.encode!()

    assert post_signed(stale).status == 400

    body = Jason.encode!(created_event())
    assert post_signed(body, [{"linear-delivery", "not-a-uuid"}]).status == 400
    refute_received {:graphql_called, _}
  end

  test "prompted activity queues its body once to the stored session thread", %{control: control} do
    assert post_signed(Jason.encode!(created_event())).status == 200
    :ok = Control.publish(control, @issue_id, {:waiting_user, %{thread_id: "saved-thread"}})
    body = Jason.encode!(prompted_event("activity-1", "continue"))
    assert post_signed(body, [{"linear-delivery", "66666666-6666-4666-8666-666666666666"}]).status == 200
    assert post_signed(body, [{"linear-delivery", "55555555-5555-4555-8555-555555555555"}]).status == 200

    assert %{thread_id: "saved-thread", prompts: [%{id: "activity-1", body: "continue"}]} =
             Control.snapshot(control, @issue_id)
  end

  test "stop signal interrupts a known session through the orchestrator seam", %{control: control} do
    assert post_signed(Jason.encode!(created_event())).status == 200
    :ok = Control.publish(control, @issue_id, {:running, %{thread_id: "saved-thread"}})
    body = prompted_event("activity-stop", "stop") |> put_in(["agentActivity", "signal"], "stop") |> Jason.encode!()
    assert post_signed(body, [{"linear-delivery", "77777777-7777-4777-8777-777777777777"}]).status == 200
    assert_receive {:interrupt, @issue_id}
    assert %{paused: true, thread_id: "saved-thread"} = Control.snapshot(control, @issue_id)
    refute Control.dispatchable?(control, @issue_id)
  end

  test "wrong organization, app user, oauth client, project, and HMAC are refused" do
    for {field, value} <- [
          {"organizationId", "other-org"},
          {"appUserId", "other-app-user"},
          {"oauthClientId", "other-oauth-client"},
          {"projectId", "other-project"}
        ] do
      event =
        case field do
          "projectId" -> put_in(created_event(), ["agentSession", "issue", field], value)
          _ -> Map.put(created_event(), field, value)
        end

      assert post_signed(Jason.encode!(event)).status == 403
    end

    body = Jason.encode!(created_event())
    assert post_signed(body, [{"linear-signature", String.duplicate("0", 64)}]).status == 401
    refute_received {:linear_session_prompt, _}
    refute_received {:linear_session_stop, _}
  end

  test "delivery collisions remain rejected after the Control owner restarts", %{root: root} do
    original = Jason.encode!(created_event())
    assert post_signed(original).status == 200
    :ok = stop_supervised(Control)

    replacement =
      start_supervised!({Control, name: nil, enabled: true, state_root: Path.join(root, "state"), workspace_root: Path.join(root, "workspaces")})

    endpoint = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint)
    native = Keyword.fetch!(endpoint, :linear_agent_session_control) |> Keyword.put(:control_server, replacement)

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      Keyword.put(endpoint, :linear_agent_session_control, native)
    )

    assert post_signed(original).status == 200
    assert post_signed(Jason.encode!(created_event("different work"))).status == 409
    assert %{prompt_context: "inspect issue"} = Control.snapshot(replacement, @issue_id)
  end

  test "an unknown session prompt cannot become new work", %{control: control} do
    assert post_signed(Jason.encode!(prompted_event("unknown-activity", "continue"))).status in [403, 404, 409]
    refute Map.has_key?(Control.snapshot(control, @issue_id), :native_session_id)
  end

  test "authoritative Linear project mismatch cannot bind a session", %{control: control} do
    endpoint = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint)
    native = Keyword.fetch!(endpoint, :linear_agent_session_control)
    owner = self()

    graphql = fn query, _variables, _opts ->
      send(owner, {:authority_query, query})

      {:ok,
       %{
         "data" => %{
           "agentSession" => %{
             "id" => @session_id,
             "appUser" => %{"id" => "app-user-1"},
             "issue" => %{"id" => @issue_id, "project" => %{"id" => "different-project"}}
           }
         }
       }}
    end

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      Keyword.put(endpoint, :linear_agent_session_control, Keyword.put(native, :graphql_client, graphql))
    )

    assert post_signed(Jason.encode!(created_event())).status == 403
    assert_receive {:authority_query, query}
    assert String.contains?(query, "agentSession(id:")
    refute Map.has_key?(Control.snapshot(control, @issue_id), :native_session_id)
    refute_receive {:authority_query, _}
  end

  test "signed malformed JSON shapes return 400 without provider access" do
    for event <- [
          [],
          nil,
          %{},
          Map.put(created_event(), "agentSession", []),
          put_in(created_event(), ["agentSession", "issue"], "invalid")
        ] do
      assert post_signed(Jason.encode!(event)).status == 400
    end

    refute_receive {:graphql_called, _, _}
  end

  test "raw body reader preserves split bytes and bounds native payload storage" do
    reader = SymphonyElixirWeb.Plugs.LinearAgentSessionRawBody
    conn = Plug.Test.conn(:post, "/api/v1/linear/agent-sessions", "abcdefgh")
    assert {:more, "abc", conn} = reader.read_body(conn, length: 3)
    assert {:more, "def", conn} = reader.read_body(conn, length: 3)
    assert {:ok, "gh", conn} = reader.read_body(conn, length: 3)
    assert conn.private.linear_raw_body == "abcdefgh"
    oversized = Plug.Test.conn(:post, "/api/v1/linear/agent-sessions", String.duplicate("x", 1_048_577))
    assert {:error, :too_large} = reader.read_body(oversized, length: 1_048_577)
  end

  defp await_projection(control, issue, attempts \\ 40)
  defp await_projection(control, issue, 0), do: assert(Control.snapshot(control, issue)[:projection_pending] == false)

  defp await_projection(control, issue, attempts) do
    if Control.snapshot(control, issue)[:projection_pending] == false do
      :ok
    else
      Process.sleep(25)
      await_projection(control, issue, attempts - 1)
    end
  end

  defp receive_activity_variables do
    receive do
      {:graphql_called, query, variables} ->
        if String.contains?(query, "agentActivityCreate"), do: variables, else: receive_activity_variables()
    after
      1_000 -> flunk("no initial Linear activity was published")
    end
  end

  defp created_event(prompt_context \\ "inspect issue") do
    %{
      "type" => "AgentSessionEvent",
      "action" => "created",
      "webhookTimestamp" => System.system_time(:millisecond),
      "organizationId" => "org-1",
      "appUserId" => "app-user-1",
      "oauthClientId" => "oauth-client-1",
      "promptContext" => prompt_context,
      "agentSession" => %{
        "id" => @session_id,
        "issue" => %{"id" => @issue_id, "projectId" => "project-1"}
      }
    }
  end

  defp prompted_event(activity_id, body) do
    %{
      "type" => "AgentSessionEvent",
      "action" => "prompted",
      "webhookTimestamp" => System.system_time(:millisecond),
      "organizationId" => "org-1",
      "appUserId" => "app-user-1",
      "oauthClientId" => "oauth-client-1",
      "agentSession" => %{"id" => @session_id, "issue" => %{"id" => @issue_id, "projectId" => "project-1"}},
      "agentActivity" => %{"id" => activity_id, "content" => %{"type" => "prompt", "body" => body}}
    }
  end

  defp post_signed(body, extra_headers \\ []) do
    signature = :crypto.mac(:hmac, :sha256, @secret, body) |> Base.encode16(case: :lower)

    default_headers =
      [
        {"content-type", "application/json"},
        {"linear-delivery", "33333333-3333-4333-8333-333333333333"},
        {"linear-signature", signature},
        {"linear-timestamp", Integer.to_string(System.system_time(:millisecond))}
      ]
      |> Map.new()
      |> Map.merge(Map.new(extra_headers))

    delivery = Enum.find_value(default_headers, fn {key, value} -> if key == "linear-delivery", do: value end)

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("linear-delivery", delivery)
    |> put_req_header(
      "linear-signature",
      Enum.find_value(default_headers, signature, fn {key, value} -> if key == "linear-signature", do: value end)
    )
    |> post("/api/v1/linear/agent-sessions", body)
  end
end
