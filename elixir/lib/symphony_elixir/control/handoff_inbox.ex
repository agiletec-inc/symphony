defmodule SymphonyElixir.Control.HandoffInbox do
  @moduledoc "Durable local intake and single consumer for terminal handoff requests."
  use GenServer

  @states ~w(queued importing complete failed unknown)a
  @required ~w(source_workspace issue_id thread_id summary_file)a

  @spec submit(Path.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def submit(state_root, request) when is_binary(state_root) and is_map(request) do
    with {:ok, request} <- validate_request(state_root, request),
         {:ok, root} <- ensure_inbox(state_root) do
      id = uuid()
      entry = Map.merge(request, %{request_id: id, status: "queued", submitted_at: DateTime.utc_now() |> DateTime.to_iso8601()})
      path = Path.join(root, "queued/#{id}.json")

      case atomic_write(path, Jason.encode!(entry)) do
        :ok -> {:ok, id}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec submit(Path.t(), term()) :: {:error, :invalid_request}
  def submit(_state_root, _request), do: {:error, :invalid_request}

  @spec status(Path.t(), String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def status(state_root, request_id) when is_binary(state_root) and is_binary(request_id) do
    if status_lookup_allowed?(state_root, request_id) do
      case Enum.find_value(@states, &status_entry(state_root, &1, request_id)) do
        nil -> {:error, :not_found}
        entry -> {:ok, Map.drop(entry, ["summary", :summary])}
      end
    else
      {:error, :not_found}
    end
  end

  defp status_lookup_allowed?(root, id), do: valid_id?(id) and not symlink_path?(inbox_root(root))

  defp status_entry(root, state, id) do
    dir = Path.join([root, "handoff-inbox", Atom.to_string(state)])
    if symlink_path?(dir), do: nil, else: read_entry(Path.join(dir, id <> ".json"))
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    root = Keyword.fetch!(opts, :state_root)
    owner = Keyword.fetch!(opts, :owner)
    importer = Keyword.fetch!(opts, :importer)

    unless is_function(importer, 2) do
      raise ArgumentError, "importer must be a function of arity 2"
    end

    ensure_inbox!(root)
    recover_importing(inbox_root(root))
    ref = Process.monitor(owner)
    interval = Keyword.get(opts, :interval_ms, 1_000)
    send(self(), :scan)
    {:ok, %{root: inbox_root(root), opts: opts, importer: importer, interval: interval, owner_ref: ref, running: nil}}
  end

  @impl true
  def handle_info(:scan, %{running: nil} = state) do
    next =
      case next_queued(state.root) do
        nil ->
          state

        {id, path} ->
          importing = Path.join(state.root, "importing/#{id}.json")

          case File.rename(path, importing) do
            :ok ->
              process_queued(state, id, importing)

            _ ->
              state
          end
      end

    schedule_scan(next)
    {:noreply, next}
  end

  def handle_info(:scan, state), do: {:noreply, state}

  def handle_info({:imported, id, result}, %{running: {id, ref, _pid}} = state) do
    Process.demonitor(ref, [:flush])
    target = if result == :ok or match?({:ok, _}, result), do: :complete, else: :failed
    move_status(state.root, id, target)
    next = %{state | running: nil}
    send(self(), :scan)
    {:noreply, next}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{running: {id, ref, _}} = state) do
    move_status(state.root, id, :unknown)
    send(self(), :scan)
    {:noreply, %{state | running: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state), do: {:stop, :owner_down, state}
  def handle_info(_, state), do: {:noreply, state}

  defp process_queued(state, id, importing) do
    case read_entry(importing) do
      entry when is_map(entry) ->
        start_import(state, id, importing, entry)

      _ ->
        quarantine(state.root, id, "malformed request")
        state
    end
  end

  defp start_import(state, id, importing, entry) do
    case persist_status(importing, Map.put(entry, "status", "importing")) do
      :ok ->
        parent = self()
        {pid, ref} = spawn_monitor(fn -> send(parent, {:imported, id, safe_import(state.importer, entry, state.opts)}) end)
        %{state | running: {id, ref, pid}}

      _ ->
        move_status(state.root, id, :unknown)
        state
    end
  end

  @impl true
  def terminate(_reason, %{running: {_id, _ref, pid}}) when is_pid(pid), do: Process.exit(pid, :shutdown)
  def terminate(_reason, _state), do: :ok

  defp validate_request(root, request) do
    request = atomize(request)

    cond do
      not required_valid?(request) -> {:error, :invalid_request}
      not paths_valid?(root, request) -> {:error, :invalid_path}
      true -> {:ok, Map.take(request, @required ++ [:repository, :expected_fingerprint])}
    end
  end

  defp required_valid?(request) do
    Enum.all?(@required, &valid_text?(Map.get(request, &1))) and optional_fields_valid?(request)
  end

  defp optional_fields_valid?(request), do: optional_valid?(request[:repository]) and optional_valid?(request[:expected_fingerprint])
  defp paths_valid?(root, request), do: safe_root?(root) and Enum.all?([request.source_workspace, request.summary_file], &safe_path?/1)

  defp atomize(map),
    do:
      Enum.reduce(map, %{}, fn {k, v}, acc ->
        key = atom_key(k)

        if key, do: Map.put(acc, key, v), else: acc
      end)

  defp atom_key(key) when is_atom(key), do: key
  defp atom_key("source_workspace"), do: :source_workspace
  defp atom_key("issue_id"), do: :issue_id
  defp atom_key("thread_id"), do: :thread_id
  defp atom_key("summary_file"), do: :summary_file
  defp atom_key("repository"), do: :repository
  defp atom_key("expected_fingerprint"), do: :expected_fingerprint
  defp atom_key(_), do: nil

  defp valid_text?(value), do: is_binary(value) and String.trim(value) != ""
  defp optional_valid?(nil), do: true
  defp optional_valid?(value), do: valid_text?(value)
  defp safe_path?(path), do: Path.split(path) |> Enum.all?(&(&1 not in [".", ".."])) and not symlink_path?(path)

  defp symlink_path?(path) do
    Path.split(Path.expand(path))
    |> Enum.reduce_while("/", fn part, current ->
      candidate = Path.join(current, part)

      case File.read_link(candidate) do
        {:ok, _} -> {:halt, true}
        {:error, :enoent} -> {:halt, false}
        _ -> {:cont, candidate}
      end
    end)
    |> Kernel.==(true)
  end

  defp safe_root?(root), do: not symlink_path?(root)
  defp valid_id?(id), do: Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, id)

  defp uuid do
    hex = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    hex = binary_part(hex, 0, 12) <> "4" <> binary_part(hex, 13, 3) <> "8" <> binary_part(hex, 17, 15)
    Enum.join([binary_part(hex, 0, 8), binary_part(hex, 8, 4), binary_part(hex, 12, 4), binary_part(hex, 16, 4), binary_part(hex, 20, 12)], "-")
  end

  defp inbox_root(root), do: Path.join(root, "handoff-inbox")

  defp ensure_inbox(root) do
    ensure_inbox!(root)
    {:ok, inbox_root(root)}
  rescue
    e -> {:error, e}
  end

  defp ensure_inbox!(root) do
    if symlink_path?(root), do: raise("state root is a symlink")
    File.mkdir_p!(inbox_root(root))
    if symlink_path?(inbox_root(root)), do: raise("handoff inbox is a symlink")

    Enum.each(@states, fn state ->
      dir = Path.join(inbox_root(root), Atom.to_string(state))
      if symlink_path?(dir), do: raise("handoff status directory is a symlink")
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o700)
    end)

    File.chmod!(inbox_root(root), 0o700)
  end

  defp atomic_write(path, data) do
    tmp = path <> ".tmp-" <> uuid()
    result = with {:ok, io} <- File.open(tmp, [:write, :exclusive, :binary]), :ok <- IO.binwrite(io, data), :ok <- File.close(io), :ok <- File.chmod(tmp, 0o600), do: File.rename(tmp, path)
    if result != :ok, do: File.rm(tmp)
    result
  end

  defp read_entry(path) do
    with true <- regular_file?(path), {:ok, data} <- File.read(path), {:ok, entry} <- Jason.decode(data), true <- valid_disk_entry?(entry, Path.basename(path)) do
      entry
    else
      _ -> nil
    end
  end

  defp read_entry!(path) do
    case read_entry(path) do
      {:ok, entry} -> entry
      entry when is_map(entry) -> entry
      _ -> raise "invalid handoff request: #{path}"
    end
  end

  defp regular_file?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> true
      _ -> false
    end
  end

  defp valid_disk_entry?(entry, filename) when is_map(entry) do
    id = Path.rootname(filename)
    valid_id?(id) and entry["request_id"] == id and valid_disk_fields?(entry)
  end

  defp valid_disk_entry?(_, _), do: false

  defp valid_disk_fields?(%{"status" => status} = entry) when status in ["queued", "importing", "complete"] do
    Enum.all?(~w(source_workspace issue_id thread_id summary_file), &valid_text?(entry[&1]))
  end

  defp valid_disk_fields?(%{"status" => status, "error" => error}) when status in ["failed", "unknown"], do: valid_text?(error)
  defp valid_disk_fields?(%{"status" => "unknown"} = entry), do: Enum.all?(~w(source_workspace issue_id thread_id summary_file), &valid_text?(entry[&1]))
  defp valid_disk_fields?(_), do: false

  defp next_queued(root) do
    file = root |> Path.join("queued") |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".json")) |> Enum.sort() |> List.first()

    case file do
      nil -> nil
      file -> {Path.rootname(file), Path.join(root, "queued/#{file}")}
    end
  end

  defp persist_status(path, entry), do: atomic_write(path, Jason.encode!(entry))

  defp move_status(root, id, state) do
    source = Path.join(root, "importing/#{id}.json")
    target = Path.join(root, "#{state}/#{id}.json")
    entry = read_entry!(source)
    updated = Map.put(entry, "status", Atom.to_string(state))
    updated = if state == :failed, do: Map.put(updated, "error", "import_failed"), else: updated
    if persist_status(target, updated) == :ok, do: File.rm(source)
  end

  defp quarantine(root, id, reason) do
    source = Path.join(root, "importing/#{id}.json")
    target = Path.join(root, "failed/#{id}.json")
    if atomic_write(target, Jason.encode!(%{"request_id" => id, "status" => "failed", "error" => reason})) == :ok, do: File.rm(source)
  end

  defp recover_importing(root) do
    case File.ls(Path.join(root, "importing")) do
      {:ok, files} ->
        Enum.each(files, &recover_if_json(root, &1))

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        raise "cannot inspect handoff inbox: #{reason}"
    end
  end

  defp recover_if_json(root, file) do
    if String.ends_with?(file, ".json"), do: recover_file(root, file)
  end

  defp recover_file(root, file) do
    id = Path.rootname(file)
    if is_map(read_entry(Path.join([root, "importing", file]))), do: move_status(root, id, :unknown), else: quarantine(root, id, "malformed request")
  end

  defp schedule_scan(%{running: nil, interval: interval}), do: Process.send_after(self(), :scan, interval)
  defp schedule_scan(_), do: :ok

  defp safe_import(importer, entry, opts) do
    importer.(entry, opts)
  rescue
    _ -> {:error, :importer_crashed}
  end
end
