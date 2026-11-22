defmodule SymphonyElixir.Control.CiResult do
  @moduledoc "Pure, target-bound classification of GitHub CI rollups."
  @conclusions ~w(SUCCESS FAILURE CANCELLED TIMED_OUT ACTION_REQUIRED STALE STARTUP_FAILURE NEUTRAL SKIPPED)
  @states ~w(SUCCESS FAILURE ERROR)

  @spec target(map()) :: {:ok, %{pr_url: String.t(), head_sha: String.t()}} | {:error, :invalid_ci_target}
  def target(%{"url" => url, "headRefOid" => sha}) when is_binary(url) and is_binary(sha) do
    if valid_url?(url) and Regex.match?(~r/\A[0-9a-f]{40}\z/, sha), do: {:ok, %{pr_url: url, head_sha: sha}}, else: {:error, :invalid_ci_target}
  end

  def target(_), do: {:error, :invalid_ci_target}

  @spec classify(map(), map()) :: :completed | :pending | {:error, :stale_ci_target | :invalid_ci_result}
  def classify(%{pr_url: url, head_sha: sha}, payload) when is_binary(url) and is_binary(sha) and is_map(payload) do
    if payload["url"] != url or payload["headRefOid"] != sha, do: {:error, :stale_ci_target}, else: classify_rollup(payload["statusCheckRollup"])
  end

  def classify(_, _), do: {:error, :invalid_ci_result}

  defp classify_rollup([_ | _] = rollup) when length(rollup) <= 1_000 do
    if Enum.all?(rollup, &terminal?/1), do: :completed, else: :pending
  end

  defp classify_rollup(_), do: :pending
  defp terminal?(%{"__typename" => "CheckRun", "status" => "COMPLETED", "conclusion" => conclusion}) when conclusion in @conclusions, do: true
  defp terminal?(%{"__typename" => "StatusContext", "state" => state}) when state in @states, do: true
  defp terminal?(_), do: false
  defp valid_url?(url), do: Regex.match?(~r/\Ahttps:\/\/github\.com\/[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\/(?!\.{1,2}\/)[A-Za-z0-9_.-]+\/pull\/[1-9][0-9]*\z/, url)
end
