defmodule SymphonyElixir.Control.OutcomeTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Control.Outcome

  test "implementation cannot assert independent review or completion" do
    for outcome <- ["approve", "completed", "changes_requested", "needs_judgment"] do
      assert {:error, :invalid_outcome} = Outcome.validate(:implementation, %{"outcome" => outcome, "summary" => "claim"})
    end

    assert {:ok, %{role: :implementation, outcome: "needs_review"}} =
             Outcome.validate(:implementation, %{"outcome" => "needs_review", "summary" => "Ready for independent inspection"})
  end

  test "role-specific schema and validation agree" do
    for role <- [:implementation, :review] do
      schema = Outcome.schema(role)
      assert schema["additionalProperties"] == false
      assert Enum.sort(schema["required"]) == ["outcome", "summary"]

      for outcome <- schema["properties"]["outcome"]["enum"] do
        assert {:ok, %{role: ^role, outcome: ^outcome}} = Outcome.validate(role, %{"outcome" => outcome, "summary" => "local report"})
      end
    end

    assert {:error, :invalid_outcome} = Outcome.validate(:review, %{"outcome" => "needs_review", "summary" => "claim"})
  end

  test "malformed and oversized results fail closed" do
    for value <- [
          nil,
          [],
          %{},
          %{"outcome" => "needs_review"},
          %{"outcome" => "needs_review", "summary" => "   "},
          %{"outcome" => "needs_review", "summary" => 1},
          %{"outcome" => "needs_review", "summary" => "report", "extra" => true},
          %{"outcome" => "needs_review", "summary" => String.duplicate("x", 8193)},
          %{"outcome" => "needs_review", "summary" => <<255>>}
        ] do
      assert {:error, :invalid_outcome} = Outcome.validate(:implementation, value)
    end
  end
end
