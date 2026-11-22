defmodule SymphonyElixir.Linear.TerminalSessionTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Linear.TerminalSession
  @config %{enabled: true, application_user_id: "app", organization_id: "org", project_id: "proj"}
  defp resolve_response do
    %{
      "data" => %{
        "viewer" => %{"id" => "app", "organization" => %{"id" => "org"}},
        "issue" => %{"id" => "issue-uuid", "identifier" => "ENG-1", "project" => %{"id" => "proj"}}
      }
    }
  end

  test "resolves canonical issue" do
    assert {:ok, %{issue_id: "issue-uuid", identifier: "ENG-1"}} =
             TerminalSession.resolve_issue("ENG-1", @config, fn _, _, _ -> {:ok, resolve_response()} end)
  end

  for {name, key} <- [organization: :organization_id, project: :project_id, app: :application_user_id] do
    test "rejects wrong #{name} scope" do
      config = Map.put(@config, unquote(key), "wrong")

      assert {:error, :out_of_scope} =
               TerminalSession.resolve_issue("ENG-1", config, fn _, _, _ -> {:ok, resolve_response()} end)
    end
  end

  test "rejects GraphQL errors alongside data" do
    assert {:error, :scope_unavailable} =
             TerminalSession.resolve_issue("ENG-1", @config, fn _, _, _ ->
               {:ok, Map.put(resolve_response(), "errors", [%{"message" => "bad"}])}
             end)
  end

  test "creates scoped session with only issueId" do
    graphql = fn _, %{input: input}, opts ->
      send(self(), {:input, input})
      send(self(), {:opts, opts})

      {:ok,
       %{
         "data" => %{
           "agentSessionCreateOnIssue" => %{
             "success" => true,
             "agentSession" => %{
               "id" => "session",
               "appUser" => %{"id" => "app"},
               "issue" => %{"id" => "issue-uuid", "project" => %{"id" => "proj"}}
             }
           }
         }
       }}
    end

    assert {:ok, "session"} = TerminalSession.create_session("issue-uuid", @config, graphql)
    assert_received {:input, %{issueId: "issue-uuid"}}
    assert_received {:opts, [request_timeout_ms: 1_000, retry: false]}
  end

  test "ambiguous create response is unresolved and does not retry" do
    counter = :counters.new(1, [])

    graphql = fn _, _, _ ->
      :counters.add(counter, 1, 1)

      {:ok, %{"data" => %{"agentSessionCreateOnIssue" => %{"success" => true, "agentSession" => %{}}}, "errors" => [%{}]}}
    end

    assert {:error, :session_creation_unresolved} = TerminalSession.create_session("issue-uuid", @config, graphql)
    assert :counters.get(counter, 1) == 1
  end

  test "disabled or incomplete config performs no GraphQL call" do
    assert {:error, :disabled} =
             TerminalSession.resolve_issue("ENG-1", %{enabled: false}, fn _, _, _ -> raise "called" end)

    assert {:error, :disabled} =
             TerminalSession.create_session("issue-uuid", %{enabled: true}, fn _, _, _ -> raise "called" end)
  end

  test "rejects a successful response with an empty session id" do
    response = %{
      "data" => %{
        "agentSessionCreateOnIssue" => %{
          "success" => true,
          "agentSession" => %{
            "id" => "",
            "appUser" => %{"id" => "app"},
            "issue" => %{"id" => "issue-uuid", "project" => %{"id" => "proj"}}
          }
        }
      }
    }

    assert {:error, :session_creation_unresolved} =
             TerminalSession.create_session("issue-uuid", @config, fn _, _, _ -> {:ok, response} end)
  end

  test "rejects a created session outside the configured scope" do
    response =
      put_in(resolve_response(), ["data", "agentSessionCreateOnIssue"], %{
        "success" => true,
        "agentSession" => %{
          "id" => "session",
          "appUser" => %{"id" => "other-app"},
          "issue" => %{"id" => "issue-uuid", "project" => %{"id" => "proj"}}
        }
      })

    assert {:error, :session_creation_unresolved} =
             TerminalSession.create_session("issue-uuid", @config, fn _, _, _ -> {:ok, response} end)
  end

  test "maps create callback failures to an unresolved session" do
    assert {:error, :session_creation_unresolved} =
             TerminalSession.create_session("issue-uuid", @config, fn _, _, _ -> raise "offline" end)
  end
end
