defmodule SymphonyElixir.LinearAgentSessionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.AgentSession

  @secret "test-secret"
  @config %{
    webhook_secret: @secret,
    organization_id: "org-1",
    application_user_id: "app-1",
    oauth_client_id: "oauth-1",
    project_id: "project-1"
  }

  test "returns scope unavailable when the authority query raises" do
    assert {:error, :scope_unavailable} =
             AgentSession.authorize(%{"agentSession" => %{"id" => "session", "issueId" => "issue"}}, @config, fn _, _, _ -> raise "offline" end)
  end

  test "rejects GraphQL errors and malformed authority responses" do
    event = %{"agentSession" => %{"id" => "session", "issueId" => "issue"}}
    graphql_error = fn _, _, _ -> {:ok, %{"data" => %{"agentSession" => authority_session()}, "errors" => [%{}]}} end
    assert {:error, :scope_unavailable} = AgentSession.authorize(event, @config, graphql_error)
    assert {:error, :scope_unavailable} = AgentSession.authorize(event, @config, fn _, _, _ -> {:ok, %{}} end)

    mismatch = put_in(authority_session(), ["issue", "project", "id"], "other-project")

    assert {:error, :out_of_scope} =
             AgentSession.authorize(event, @config, fn _, _, _ ->
               {:ok, %{"data" => %{"agentSession" => mismatch}}}
             end)

    incomplete = Map.delete(authority_session(), "issue")

    assert {:error, :out_of_scope} =
             AgentSession.authorize(event, @config, fn _, _, _ ->
               {:ok, %{"data" => %{"agentSession" => incomplete}}}
             end)
  end

  test "rejects malformed delivery, signature, issue consistency, and prompt activity" do
    created = base_event()
    raw = Jason.encode!(created)
    invalid_delivery = Map.delete(signed_headers(created, raw), "linear-delivery")

    assert {:error, :invalid_delivery} = AgentSession.verify(raw, invalid_delivery, @config)
    assert {:error, :invalid_signature} = AgentSession.verify(raw, %{"linear-delivery" => valid_delivery()}, @config)

    inconsistent = put_in(created, ["agentSession", "issue", "id"], "different-issue")
    assert {:error, :invalid_event} = verify_signed(inconsistent, @config)

    prompted = prompted_event() |> put_in(["agentActivity", "content", "body"], nil)
    assert {:error, :invalid_event} = verify_signed(prompted, @config)
  end

  test "accepts a signed event and preserves its delivery id" do
    assert {:ok, %{"_delivery" => delivery}} = verify_signed(base_event(), @config)
    assert delivery == valid_delivery()
  end

  test "rejects stale and malformed webhook timestamps" do
    stale = Map.put(base_event(), "webhookTimestamp", System.system_time(:millisecond) - 120_001)
    malformed = Map.put(base_event(), "webhookTimestamp", "now")

    assert {:error, :stale_timestamp} = verify_signed(stale, @config)
    assert {:error, :invalid_timestamp} = verify_signed(malformed, @config)
  end

  test "uses the nested issue id when issueId is absent" do
    event = put_in(base_event(), ["agentSession", "issueId"], nil)
    assert AgentSession.issue_id(event) == "issue"
  end

  defp verify_signed(event, config) do
    raw = Jason.encode!(event)
    AgentSession.verify(raw, signed_headers(event, raw), config)
  end

  defp signed_headers(_event, raw) do
    signature = if is_binary(raw), do: :crypto.mac(:hmac, :sha256, @secret, raw) |> Base.encode16(case: :lower), else: String.duplicate("0", 64)
    %{"linear-signature" => signature, "linear-delivery" => valid_delivery()}
  end

  defp valid_delivery, do: "11111111-1111-4111-8111-111111111111"

  defp base_event do
    %{
      "type" => "AgentSessionEvent",
      "action" => "created",
      "organizationId" => "org-1",
      "appUserId" => "app-1",
      "oauthClientId" => "oauth-1",
      "webhookTimestamp" => System.system_time(:millisecond),
      "agentSession" => %{"id" => "session", "issueId" => "issue", "issue" => %{"id" => "issue", "projectId" => "project-1"}}
    }
  end

  defp prompted_event do
    base_event()
    |> Map.put("action", "prompted")
    |> Map.put("agentActivity", %{"id" => "activity", "content" => %{"type" => "prompt", "body" => "continue"}})
  end

  defp authority_session do
    %{"id" => "session", "appUser" => %{"id" => "app-1"}, "issue" => %{"id" => "issue", "project" => %{"id" => "project-1"}}}
  end
end
