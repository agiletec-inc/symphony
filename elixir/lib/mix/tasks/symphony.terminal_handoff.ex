defmodule Mix.Tasks.Symphony.TerminalHandoff do
  @moduledoc "Queues a selected Terminal conversation for the Symphony daemon."
  use Mix.Task

  alias SymphonyElixir.Control.HandoffInbox
  alias SymphonyElixir.TerminalHandoff

  @shortdoc "Queues one selected Codex Terminal thread for the running Symphony daemon"
  @switches Enum.map([:source, :issue, :thread, :summary, :repository, :state_root], &{&1, :string})

  @impl Mix.Task
  def run(args) do
    {opts, _, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    request = %{
      source_workspace: canonical_path!(opts[:source], "--source"),
      issue_id: opts[:issue],
      thread_id: opts[:thread],
      summary_file: canonical_path!(opts[:summary], "--summary")
    }

    state_root = opts[:state_root] || Mix.raise("--state-root must identify the running Symphony daemon state directory")

    with {:ok, fingerprint} <- TerminalHandoff.fingerprint(request, repository: opts[:repository]),
         {:ok, request_id} <- HandoffInbox.submit(state_root, Map.merge(request, %{repository: opts[:repository], expected_fingerprint: fingerprint})) do
      Mix.shell().info(Jason.encode!(%{request_id: request_id, status: "queued"}))
    else
      {:error, reason} -> Mix.raise("terminal handoff refused: #{inspect(reason)}")
    end
  end

  defp canonical_path!(value, option) when is_binary(value) do
    case SymphonyElixir.PathSafety.canonicalize(value) do
      {:ok, path} -> path
      {:error, reason} -> Mix.raise("#{option}: #{inspect(reason)}")
    end
  end

  defp canonical_path!(_, option), do: Mix.raise("#{option} is required")
end
