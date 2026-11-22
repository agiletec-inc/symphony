defmodule SymphonyElixir.Control.Outcome do
  @moduledoc """
  Bounded local results for implementation and independent review turns.

  These are agent claims, not verified acceptance evidence. They are not sent to
  Linear by this module. An implementation cannot declare reviewed completion.
  """

  @implementation ["needs_review", "waiting_user", "waiting_ci"]
  @review ["approve", "changes_requested", "needs_judgment"]
  @max_summary 8_192

  @spec schema(:implementation | :review) :: map()
  def schema(role) when role in [:implementation, :review] do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["outcome", "summary"],
      "properties" => %{
        "outcome" => %{"type" => "string", "enum" => outcomes(role)},
        "summary" => %{"type" => "string", "minLength" => 1, "maxLength" => @max_summary}
      }
    }
  end

  @spec validate(:implementation | :review, term()) :: {:ok, map()} | {:error, :invalid_outcome}
  def validate(role, %{"outcome" => outcome, "summary" => summary} = value)
      when role in [:implementation, :review] and is_binary(summary) do
    if map_size(value) == 2 and outcome in outcomes(role) and
         byte_size(summary) <= @max_summary and String.valid?(summary) and String.trim(summary) != "" do
      {:ok, %{role: role, outcome: outcome, summary: summary}}
    else
      {:error, :invalid_outcome}
    end
  end

  def validate(_, _), do: {:error, :invalid_outcome}

  defp outcomes(:implementation), do: @implementation
  defp outcomes(:review), do: @review
end
