defmodule SymphonyElixir.ControlLinearBridgeTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Control.LinearBridge

  test "follows comment pages and normalizes final page command" do
    fun = fn _query, vars ->
      if vars[:after] == nil do
        {:ok, %{"data" => %{"issue" => %{"id" => "i-1", "comments" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => true, "endCursor" => "c-1"}}}}}}
      else
        {:ok,
         %{
           "data" => %{
             "issue" => %{
               "id" => "i-1",
               "comments" => %{
                 "nodes" => [%{"id" => "c-2", "body" => "/symphony resume", "createdAt" => "now", "user" => %{"id" => "u-1"}, "issue" => %{"id" => "i-1"}}],
                 "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
               }
             }
           }
         }}
      end
    end

    assert {:ok, [%{id: "c-2", issue_id: "i-1"}]} = LinearBridge.fetch_comments("i-1", fun)
  end

  test "refuses a repeated pagination cursor" do
    fun = fn _query, _vars -> {:ok, %{"data" => %{"issue" => %{"id" => "i-1", "comments" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => true, "endCursor" => "same"}}}}}} end
    assert {:error, :nonprogressing_cursor} = LinearBridge.fetch_comments("i-1", fun)
  end

  test "rejects transport and malformed pagination responses" do
    assert {:error, :timeout} = LinearBridge.fetch_comments("i-1", fn _query, _vars -> {:error, :timeout} end)

    malformed = fn _query, _vars -> {:ok, %{"data" => %{"issue" => %{"id" => "other", "comments" => %{}}}}} end
    assert {:error, :invalid_linear_payload} = LinearBridge.fetch_comments("i-1", malformed)

    wrong_page = fn _query, _vars ->
      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "id" => "i-1",
             "comments" => %{"nodes" => %{}, "pageInfo" => %{"hasNextPage" => false}}
           }
         }
       }}
    end

    assert {:error, :invalid_linear_payload} = LinearBridge.fetch_comments("i-1", wrong_page)
  end

  test "rejects a missing or unchanged next cursor" do
    missing = fn _query, _vars ->
      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "id" => "i-1",
             "comments" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => true, "endCursor" => nil}}
           }
         }
       }}
    end

    assert {:error, :nonprogressing_cursor} = LinearBridge.fetch_comments("i-1", missing)
  end

  test "accepts only authorized pause and resume commands" do
    comment = %{id: "c-1", issue_id: "i-1", user_id: "actor", body: "  /symphony pause now"}
    assert {:ok, :pause} = LinearBridge.command(comment, ["actor"], "controller")
    assert {:ok, :resume} = LinearBridge.command(%{comment | body: "/symphony resume"}, ["actor"], "controller")
    assert :ignore = LinearBridge.command(comment, ["actor"], "actor")
    assert :ignore = LinearBridge.command(comment, ["other"], "controller")
    assert :ignore = LinearBridge.command(%{comment | body: "/symphony status"}, ["actor"], "controller")
    assert :ignore = LinearBridge.command(:invalid, [], "controller")
  end

  test "projects a stable create and update comment" do
    snapshot = %{stage: :running, summary: "ok", thread_id: "t-1", model: "gpt-5.6-luna"}

    create = fn query, variables ->
      assert query =~ "commentCreate"
      assert variables.input.issueId == "i-1"
      {:ok, %{"data" => %{"commentCreate" => %{"comment" => %{"id" => "created"}, "userError" => []}}}}
    end

    assert {:ok, %{id: id, body: body}} = LinearBridge.project("i-1", snapshot, create)
    assert is_binary(id)
    assert body =~ "stage=:running"

    update = fn query, variables ->
      assert query =~ "commentUpdate"
      assert variables.id == "existing"
      {:ok, %{"data" => %{"commentUpdate" => %{"comment" => %{"id" => "existing"}, "userError" => nil}}}}
    end

    assert {:ok, %{id: "existing"}} = LinearBridge.project("i-1", Map.put(snapshot, :comment_id, "existing"), update)
  end

  test "reports projection errors without claiming success" do
    snapshot = %{stage: :ready}

    user_error = fn _query, _variables ->
      {:ok, %{"data" => %{"commentCreate" => %{"userError" => [%{"message" => "denied"}]}}}}
    end

    assert {:error, {:projection_pending, :user_error, id}} = LinearBridge.project("i-1", snapshot, user_error)
    assert is_binary(id)

    assert {:error, {:projection_pending, :offline, ^id}} =
             LinearBridge.project("i-1", snapshot, fn _query, _variables -> {:error, :offline} end)
  end
end
