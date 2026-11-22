defmodule SymphonyElixir.TerminalHandoff do
  @moduledoc "Imports one selected Codex Terminal thread into an isolated issue workspace."

  import Bitwise, only: [&&&: 2]

  alias SymphonyElixir.{Codex.AppServer, Config, PathSafety}

  @type request :: %{
          required(:source_workspace) => Path.t(),
          required(:issue_id) => String.t(),
          required(:thread_id) => String.t(),
          required(:summary_file) => Path.t()
        }

  @spec fingerprint(request(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def fingerprint(request, opts \\ []) do
    with {:ok, input} <- validate_input(request),
         {:ok, source} <- source_repository(input.source_workspace, opts),
         {:ok, summary} <- File.read(input.summary_file) do
      {:ok, selection_fingerprint(source, summary)}
    end
  end

  defp selection_fingerprint(source, summary) do
    :crypto.hash(:sha256, :erlang.term_to_binary({source.path, source.head, source.snapshot.fingerprint, summary}))
    |> Base.encode16(case: :lower)
  end

  defp verify_selection(request, source, summary) do
    case Map.get(request, :expected_fingerprint) do
      nil ->
        :ok

      expected when is_binary(expected) ->
        if expected == selection_fingerprint(source, summary), do: :ok, else: {:error, :selected_snapshot_changed}

      _ ->
        {:error, :invalid_fingerprint}
    end
  end

  @spec import(request(), keyword()) :: {:ok, map()} | {:error, term()}
  def import(request, opts \\ []) when is_map(request) do
    with {:ok, input} <- validate_input(request),
         {:ok, source} <- source_repository(input.source_workspace, opts),
         {:ok, summary} <- File.read(input.summary_file),
         :ok <- verify_selection(request, source, summary),
         {:ok, record_path} <- record_path(input, opts),
         {:ok, existing} <- existing_record(record_path, source, input, summary) do
      case existing do
        nil ->
          create_import(input, source, summary, record_path, opts)

        record ->
          restore_import(record, opts)
      end
    end
  end

  defp restore_import(record, opts) do
    with :ok <- persist_control(record, opts), do: {:ok, record}
  end

  defp validate_input(%{source_workspace: source, issue_id: issue, thread_id: thread, summary_file: summary})
       when is_binary(source) and is_binary(issue) and is_binary(thread) and is_binary(summary) do
    if Enum.any?([source, issue, thread, summary], &(String.trim(&1) == "")) do
      {:error, {:invalid_handoff, :empty_argument}}
    else
      if issue not in [".", ".."] and String.match?(issue, ~r/^[A-Za-z0-9._-]+$/) do
        {:ok, %{source_workspace: Path.expand(source), issue_id: issue, thread_id: thread, summary_file: Path.expand(summary)}}
      else
        {:error, {:invalid_handoff, :issue_id}}
      end
    end
  end

  defp validate_input(_), do: {:error, {:invalid_handoff, :required_arguments}}

  defp source_repository(source, opts) do
    with {:ok, canonical} <- PathSafety.canonicalize(source),
         true <- File.dir?(canonical),
         {:ok, {head, 0}} <- git(canonical, ["rev-parse", "--verify", "HEAD"]),
         {:ok, {root, 0}} <- git(canonical, ["rev-parse", "--show-toplevel"]),
         :ok <- validate_repository_target(canonical, opts),
         {:ok, snapshot} <- source_snapshot(canonical),
         true <- snapshot.head == String.trim(head) do
      {:ok, %{path: canonical, head: String.trim(head), root: String.trim(root), snapshot: snapshot}}
    else
      {:error, _} = error -> error
      false -> {:error, {:source_repository_missing, source}}
      _ -> {:error, {:source_repository_invalid, source}}
    end
  end

  defp validate_repository_target(source, opts) do
    case Keyword.get(opts, :repository) do
      nil ->
        :ok

      target ->
        validate_origin(source, target)
    end
  end

  defp validate_origin(source, target) do
    case git(source, ["remote", "get-url", "origin"]) do
      {:ok, {remote, 0}} ->
        if String.trim(remote) == target, do: :ok, else: {:error, {:source_repository_mismatch, target}}

      _ ->
        {:error, {:source_repository_mismatch, target}}
    end
  end

  defp record_path(input, opts) do
    root = Path.expand(Keyword.get(opts, :state_root, Path.join(System.tmp_dir!(), "symphony-control")))
    File.mkdir_p(root)
    {:ok, Path.join(root, "terminal-handoff-#{safe_key(input.thread_id <> ":" <> input.issue_id)}.json")}
  end

  defp existing_record(path, source, input, summary) do
    case File.read(path) do
      {:ok, body} ->
        decode_existing_record(body, path, source, input, summary)

      {:error, :enoent} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, {:handoff_record_unreadable, path, reason}}
    end
  end

  defp decode_existing_record(body, path, source, input, summary) do
    case Jason.decode(body) do
      {:ok, %{"sourceThread" => source_thread, "sourceHead" => head} = record}
      when source_thread == input.thread_id ->
        cond do
          not same_selection?(record, source, input, summary) ->
            {:error, {:handoff_record_conflict, path}}

          Map.get(record, "status") == "prepared" ->
            {:error, {:handoff_record_conflict, path}}

          Map.has_key?(record, "sourceFingerprint") and record["sourceFingerprint"] != source.snapshot.fingerprint ->
            {:error, {:handoff_record_conflict, path}}

          head != source.head ->
            {:error, {:handoff_record_conflict, path}}

          true ->
            {:ok, record}
        end

      _ ->
        {:error, {:handoff_record_conflict, path}}
    end
  end

  defp same_selection?(record, source, input, summary) do
    record["sourcePath"] == source.path and record["issue"] == input.issue_id and record["summary"] == summary
  end

  defp create_import(input, source, summary, record_path, opts) do
    destination = Path.join(Config.local_workspace_root(), input.issue_id)

    with :ok <- validate_destination(destination),
         {:ok, thread} <- app_server(opts).read_thread(source.path, input.thread_id, Keyword.put(Keyword.get(opts, :app_server, []), :read_only, true)),
         :ok <- validate_thread_cwd(thread, source.path),
         :ok <- ensure_snapshot_unchanged(source),
         :ok <- clone_at_head(source.path, destination, source.head),
         :ok <- apply_snapshot(destination, source.snapshot),
         :ok <- ensure_snapshot_unchanged(source),
         :ok <- persist_prepared(record_path, input, source, destination, summary),
         {:ok, fork} <- app_server(opts).fork_thread(destination, input.thread_id, destination, Keyword.get(opts, :app_server, [])),
         {:ok, new_thread} <- fork_thread_id(fork),
         record <- %{
           issue: input.issue_id,
           sourceThread: input.thread_id,
           sourcePath: source.path,
           sourceHead: source.head,
           sourceFingerprint: source.snapshot.fingerprint,
           thread: new_thread,
           workspace: destination,
           summary: summary
         },
         :ok <- persist_record(record_path, record),
         :ok <- persist_control(record, opts) do
      {:ok, Jason.decode!(Jason.encode!(record))}
    end
  end

  defp persist_prepared(path, input, source, destination, summary) do
    persist_record(path, %{
      issue: input.issue_id,
      sourceThread: input.thread_id,
      sourcePath: source.path,
      sourceHead: source.head,
      sourceFingerprint: source.snapshot.fingerprint,
      workspace: destination,
      summary: summary,
      status: "prepared"
    })
  end

  defp ensure_snapshot_unchanged(source) do
    case source_snapshot(source.path) do
      {:ok, %{head: head, fingerprint: fingerprint}}
      when head == source.head and fingerprint == source.snapshot.fingerprint ->
        :ok

      {:ok, _} ->
        {:error, {:source_snapshot_changed, source.path}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_control(record, opts) do
    case Keyword.get(opts, :control_server) do
      nil -> :ok
      server -> SymphonyElixir.Control.import_handoff(server, record[:issue] || record["issue"], record)
    end
  end

  defp app_server(opts), do: Keyword.get(opts, :app_server_module, AppServer)

  defp validate_destination(destination) do
    root = Config.local_workspace_root()

    with {:ok, canonical_root} <- PathSafety.canonicalize(root),
         {:ok, canonical_destination} <- PathSafety.canonicalize(destination),
         true <- String.starts_with?(canonical_destination <> "/", canonical_root <> "/"),
         true <- canonical_destination != canonical_root,
         false <- File.exists?(canonical_destination) do
      :ok
    else
      _ -> {:error, {:destination_exists_or_unsafe, destination}}
    end
  end

  defp source_snapshot(path) do
    with {:ok, {before_head, 0}} <- git(path, ["rev-parse", "--verify", "HEAD"]),
         {:ok, {tracked, 0}} <- git(path, ["ls-files", "-s", "-z"]),
         :ok <- reject_unsafe_tracked(tracked),
         {:ok, {untracked, 0}} <- git(path, ["ls-files", "--others", "--exclude-standard", "-z"]),
         {:ok, files} <- read_untracked(path, untracked),
         {:ok, {staged, 0}} <- git(path, ["diff", "--no-ext-diff", "--no-textconv", "--binary", "--cached"]),
         {:ok, {unstaged, 0}} <- git(path, ["diff", "--no-ext-diff", "--no-textconv", "--binary"]),
         {:ok, {after_head, 0}} <- git(path, ["rev-parse", "--verify", "HEAD"]),
         true <- String.trim(before_head) == String.trim(after_head) do
      fingerprint = safe_key(:erlang.term_to_binary({staged, unstaged, files}))
      {:ok, %{head: String.trim(before_head), fingerprint: fingerprint, staged: staged, unstaged: unstaged, files: files}}
    else
      false -> {:error, {:source_snapshot_changed, path}}
      {:ok, {_, status}} -> {:error, {:source_snapshot_failed, path, status}}
      {:error, _} = error -> error
    end
  end

  defp reject_unsafe_tracked(output) do
    entries = String.split(output, <<0>>, trim: true)

    if Enum.any?(entries, &unsafe_tracked_entry?/1) do
      {:error, {:source_snapshot_unsafe_entry, :symlink_or_submodule}}
    else
      :ok
    end
  end

  defp unsafe_tracked_entry?(entry) do
    case String.split(entry, " ", parts: 2) do
      [mode, _] -> mode == "160000" or mode == "120000"
      _ -> true
    end
  end

  defp read_untracked(path, output) do
    output
    |> String.split(<<0>>, trim: true)
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, &read_untracked_entry(path, &1, &2))
  end

  defp read_untracked_entry(path, relative, {:ok, acc}) do
    absolute = Path.expand(relative, path)

    case safe_relative?(relative) and File.lstat(absolute) do
      {:ok, %File.Stat{type: :regular}} -> read_untracked_file(absolute, relative, acc, fn -> stat_mode(absolute) end)
      _ -> {:halt, {:error, {:source_snapshot_unsafe_entry, relative}}}
    end
  end

  defp read_untracked_file(absolute, relative, acc, mode) do
    case File.read(absolute) do
      {:ok, contents} -> {:cont, {:ok, [{relative, contents, mode.()}] ++ acc}}
      {:error, reason} -> {:halt, {:error, {:source_snapshot_unreadable, relative, reason}}}
    end
  end

  defp safe_relative?(relative), do: relative != "" and Path.type(relative) != :absolute and not Enum.member?(Path.split(relative), "..")

  defp stat_mode(path) do
    {:ok, stat} = File.stat(path)
    stat.mode &&& 0o777
  end

  defp apply_snapshot(destination, %{staged: staged, unstaged: unstaged, files: files}) do
    with :ok <- apply_patch(destination, staged, true),
         :ok <- apply_patch(destination, unstaged, false) do
      Enum.reduce_while(files, :ok, &write_snapshot_file(destination, &1, &2))
    end
  end

  defp write_snapshot_file(destination, {relative, contents, mode}, :ok) do
    target = Path.join(destination, relative)
    File.mkdir_p!(Path.dirname(target))

    case File.write(target, contents, [:binary]) do
      :ok ->
        File.chmod!(target, mode)
        {:cont, :ok}

      {:error, reason} ->
        {:halt, {:error, {:destination_snapshot_write_failed, relative, reason}}}
    end
  end

  defp apply_patch(_destination, "", _index), do: :ok

  defp apply_patch(destination, patch, index) do
    dir = Path.join(System.tmp_dir!(), "terminal-handoff-#{safe_key(:crypto.strong_rand_bytes(24))}")
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    file = Path.join(dir, "patch")

    try do
      File.write!(file, patch, [:binary, :exclusive])
      args = ["apply", "--binary"] ++ if(index, do: ["--index"], else: []) ++ [file]

      case git(destination, args) do
        {:ok, {_, 0}} -> :ok
        other -> {:error, {:destination_snapshot_patch_failed, other}}
      end
    after
      File.rm_rf(dir)
    end
  end

  defp clone_at_head(source, destination, head) do
    File.mkdir_p!(Path.dirname(destination))

    case git(nil, ["clone", "--no-local", source, destination]) do
      {:ok, {_, 0}} ->
        case git(destination, ["checkout", "--detach", head]) do
          {:ok, {_, 0}} -> :ok
          other -> {:error, {:destination_head_failed, other}}
        end

      other ->
        {:error, {:destination_clone_failed, other}}
    end
  end

  defp fork_thread_id(%{"thread" => %{"id" => id}}) when is_binary(id), do: {:ok, id}
  defp fork_thread_id(_), do: {:error, :invalid_fork_response}

  defp persist_record(path, record) do
    temp = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))
    with :ok <- File.write(temp, Jason.encode!(record), [:binary]), do: File.rename(temp, path)
  end

  defp safe_key(value), do: Base.encode16(:crypto.hash(:sha256, value), case: :lower)

  defp git(nil, args), do: {:ok, System.cmd("git", args, stderr_to_stdout: true, env: [{"GIT_OPTIONAL_LOCKS", "0"}])}
  defp git(cwd, args), do: {:ok, System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true, env: [{"GIT_OPTIONAL_LOCKS", "0"}])}

  defp validate_thread_cwd(%{"thread" => %{"cwd" => cwd}}, source) when is_binary(cwd) do
    case PathSafety.canonicalize(cwd) do
      {:ok, ^source} -> :ok
      _ -> {:error, {:thread_cwd_mismatch, cwd, source}}
    end
  end

  defp validate_thread_cwd(_, _), do: {:error, :thread_metadata_missing}
end
