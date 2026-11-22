defmodule SymphonyElixir.ControlLinearProjectionTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Control.LinearBridge

  test "creates stable structured projection without forbidden fields" do
    fun = fn q, vars ->
      send(self(), {q, vars})
      {:ok, %{"data" => %{"commentCreate" => %{"userError" => [], "comment" => %{"id" => "x"}}}}}
    end

    assert {:ok, %{id: id, body: body}} =
             LinearBridge.project(
               "issue-1",
               %{stage: "waiting_user", summary: "ok", thread_id: "t", auth: "secret", transcript: "raw"},
               fun
             )

    assert id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
    refute body =~ "secret"
    refute body =~ "raw"
  end

  test "updates existing projection and rejects user errors" do
    fun = fn q, _ ->
      send(self(), q)
      {:ok, %{"data" => %{"commentUpdate" => %{"userError" => ["denied"]}}}}
    end

    assert {:error, {:projection_pending, :user_error, "c-1"}} =
             LinearBridge.project("i", %{comment_id: "c-1", stage: "running"}, fun)

    assert_receive q
    assert q =~ "commentUpdate"
  end
end
