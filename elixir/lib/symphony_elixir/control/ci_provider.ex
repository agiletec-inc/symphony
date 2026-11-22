defmodule SymphonyElixir.Control.CiProvider do
  @moduledoc "Reads CI metadata for the selected workspace without a model or shell interpolation."
  alias SymphonyElixir.Control.CiResult
  @fields "headRefOid,statusCheckRollup,number,url"
  @limit 1_048_576

  @spec capture(Path.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def capture(workspace, opts \\ []), do: fetch(workspace, nil, opts)

  @spec poll(Path.t(), map(), keyword()) :: {:ok, map()} | {:error, atom()}
  def poll(workspace, %{pr_url: url, head_sha: sha}, opts \\ []) do
    with {:ok, _} <- CiResult.target(%{"url" => url, "headRefOid" => sha}),
         {:ok, payload} <- fetch(workspace, url, opts),
         true <- payload["headRefOid"] == sha do
      {:ok, payload}
    else
      false -> {:error, :stale_ci_target}
      error -> error
    end
  end

  defp fetch(workspace, selector, opts) do
    command = Keyword.get(opts, :command, &command/3)

    with {:ok, head} <- git(command, workspace, ["rev-parse", "HEAD"]),
         {:ok, origin} <- git(command, workspace, ["remote", "get-url", "origin"]),
         {:ok, repo} <- repository(origin),
         {:ok, branch} <- git(command, workspace, ["symbolic-ref", "--quiet", "--short", "HEAD"]),
         true <- valid_branch?(branch) and (is_nil(selector) or String.starts_with?(selector, "https://github.com/" <> repo <> "/pull/")),
         {:ok, body} <- command.("gh", ["pr", "view", selector || branch, "--repo", repo, "--json", @fields], workspace),
         {:ok, payload} when is_map(payload) <- Jason.decode(body),
         {:ok, target} <- CiResult.target(payload),
         true <- String.starts_with?(target.pr_url, "https://github.com/" <> repo <> "/pull/") and target.head_sha == head,
         {:ok, final_head} <- git(command, workspace, ["rev-parse", "HEAD"]),
         true <- final_head == head,
         {:ok, final_origin} <- git(command, workspace, ["remote", "get-url", "origin"]),
         {:ok, final_branch} <- git(command, workspace, ["symbolic-ref", "--quiet", "--short", "HEAD"]),
         true <- final_origin == origin and final_branch == branch do
      {:ok, Map.take(payload, ["url", "headRefOid", "number", "statusCheckRollup"])}
    else
      false -> {:error, :ci_workspace_mismatch}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_ci_response}
    end
  end

  defp git(command, workspace, args) do
    case command.("git", args, workspace) do
      {:ok, output} when is_binary(output) -> {:ok, String.trim(output)}
      _ -> {:error, :ci_git_failed}
    end
  end

  defp repository(origin) do
    case Regex.run(~r/\A(?:https:\/\/github\.com\/|git@github\.com:)([^\s\/?#:@]+\/[^\s\/?#:@]+)\z/, origin) do
      [_, repo] ->
        repo = String.replace_suffix(repo, ".git", "")

        case CiResult.target(%{"url" => "https://github.com/" <> repo <> "/pull/1", "headRefOid" => String.duplicate("a", 40)}) do
          {:ok, _} -> {:ok, repo}
          _ -> {:error, :unsupported_ci_remote}
        end

      _ ->
        {:error, :unsupported_ci_remote}
    end
  end

  defp valid_branch?(branch), do: branch != "" and not String.starts_with?(branch, "-") and not String.contains?(branch, ["\n", "\r", "\0"])

  defp command(name, args, workspace) do
    case System.find_executable(name) do
      nil ->
        {:error, :ci_executable_unavailable}

      executable ->
        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:args, args},
            {:cd, workspace},
            {:env, [{~c"GH_HOST", ~c"github.com"}, {~c"GH_PROMPT_DISABLED", ~c"1"}, {~c"GIT_OPTIONAL_LOCKS", ~c"0"}]}
          ])

        try do
          receive_output(port, "", System.monotonic_time(:millisecond) + 3_000)
        after
          if Port.info(port), do: Port.close(port)
        end
    end
  rescue
    _ -> {:error, :ci_command_failed}
  end

  defp receive_output(port, output, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} when byte_size(output) + byte_size(data) <= @limit ->
        receive_output(port, output <> data, deadline)

      {^port, {:data, _}} ->
        {:error, :ci_response_too_large}

      {^port, {:exit_status, 0}} ->
        {:ok, output}

      {^port, {:exit_status, _}} ->
        {:error, :ci_command_failed}
    after
      remaining -> {:error, :ci_command_timeout}
    end
  end
end
