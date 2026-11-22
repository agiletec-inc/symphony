defmodule SymphonyElixir.Control.Outbox do
  @moduledoc "Durable per-session activity sender with bounded retry rate."
  use GenServer

  alias SymphonyElixir.Control.ActivityProjection

  @fast_retry_limit 5
  @base_delay 100
  @recovery_delay 60_000
  @spec activate(GenServer.server()) :: :ok
  def activate(server), do: GenServer.cast(server, :activate)
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec enqueue(GenServer.server(), map(), (String.t(), map(), keyword() -> term()), GenServer.server()) :: :ok | {:error, term()}
  def enqueue(server, item, transport, owner) when is_map(item) and is_function(transport, 3) do
    GenServer.call(server, {:enqueue, item, transport, owner})
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    root = Keyword.get(opts, :state_root, Path.join(System.tmp_dir!(), "symphony-control-state"))
    File.mkdir_p!(root)

    state = %{
      root: root,
      entries: normalize_orders(load(root)),
      transport: Keyword.get(opts, :transport),
      owner: Keyword.get(opts, :owner),
      running: nil,
      paused: Keyword.get(opts, :paused, false),
      wake_timer: nil
    }

    if is_function(state.transport, 3), do: send(self(), :drain)
    {:ok, state}
  end

  @impl true
  def handle_cast(:activate, state) do
    send(self(), :drain)
    {:noreply, %{state | paused: false}}
  end

  @impl true
  def handle_call({:enqueue, item, transport, owner}, _from, state) do
    id = item[:id] || item["id"]
    order = item[:order]

    if not is_binary(id) or (not is_nil(order) and (not is_integer(order) or order < 0)) or not valid_phase?(item) do
      {:reply, {:error, :invalid_order}, state}
    else
      order = order || next_order(state.entries)
      entry = Map.merge(Map.take(item, [:id, :session_id, :activity_id, :body, :phase]), %{id: id, attempts: 0, next_at: 0, order: order})
      entries = Map.put_new(state.entries, id, entry)
      next = %{state | entries: entries, transport: transport, owner: owner}
      persist(next)
      unless state.paused, do: send(self(), :drain)
      {:reply, :ok, next}
    end
  end

  @impl true
  def handle_info(:drain, %{paused: true} = state), do: {:noreply, state}

  def handle_info(:drain, %{running: nil, entries: entries, transport: transport} = state) when is_function(transport, 3) do
    if state.wake_timer, do: Process.cancel_timer(state.wake_timer)
    state = %{state | wake_timer: nil}

    case candidate(entries) do
      nil ->
        schedule_next_entry(entries, state)

      {_id, entry} ->
        parent = self()
        {pid, ref} = spawn_monitor(fn -> send(parent, {:sent, entry.id, safe_deliver(entry, transport)}) end)
        {:noreply, %{state | running: {entry.id, ref, pid}}}
    end
  end

  def handle_info(:drain, state), do: {:noreply, state}

  def handle_info({:sent, id, result}, %{entries: entries} = state) do
    case state.running do
      {^id, ref, _pid} -> Process.demonitor(ref, [:flush])
      _ -> :ok
    end

    entry = Map.get(entries, id)

    cond do
      is_nil(entry) ->
        {:noreply, %{state | running: nil}}

      result == :ok ->
        notify(state.owner, id)
        next = %{state | entries: Map.delete(entries, id), running: nil}
        persist(next)
        send(self(), :drain)
        {:noreply, next}

      entry.attempts + 1 >= @fast_retry_limit ->
        next = %{state | entries: Map.put(entries, id, %{entry | attempts: @fast_retry_limit, next_at: System.system_time(:millisecond) + @recovery_delay}), running: nil}
        persist(next)
        if is_pid(state.owner), do: send(state.owner, {:native_outbox_delayed, id})
        send(self(), :drain)
        {:noreply, next}

      true ->
        attempts = entry.attempts + 1
        delay = @base_delay * trunc(:math.pow(2, attempts - 1))
        next = %{state | entries: Map.put(entries, id, %{entry | attempts: attempts, next_at: System.system_time(:millisecond) + delay}), running: nil}
        persist(next)
        send(self(), :drain)
        {:noreply, next}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, %{running: {id, ref, pid}} = state) do
    send(self(), {:sent, id, :error})
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{running: {_id, _ref, pid}}) when is_pid(pid) do
    Process.exit(pid, :shutdown)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp valid_phase?(%{phase: phase}), do: match?({:ok, _}, ActivityProjection.content(phase))
  defp valid_phase?(_), do: true

  defp schedule_next_entry(entries, state) do
    case entries |> heads() |> Enum.filter(&is_integer(&1.next_at)) |> Enum.min_by(& &1.next_at, fn -> nil end) do
      nil ->
        {:noreply, state}

      entry ->
        timer = Process.send_after(self(), :drain, max(entry.next_at - System.system_time(:millisecond), 0))
        {:noreply, %{state | wake_timer: timer}}
    end
  end

  defp activity_content(%{phase: phase}) do
    {:ok, content} = ActivityProjection.content(phase)
    content
  end

  defp activity_content(entry), do: %{type: "thought", body: entry.body}

  defp deliver(entry, transport) do
    query =
      "query SymphonyAgentSessionActivity($id: String!, $activityId: ID!) { agentSession(id: $id) { id activities(first: 1, filter: {id: {eq: $activityId}}) { nodes { id agentSession { id } } } } }"

    vars = %{id: entry.session_id, activityId: entry.activity_id}

    case transport.(query, vars, []) do
      {:ok, %{"errors" => _}} -> :error
      {:ok, response} -> deliver_response(response, entry, transport)
      _ -> :error
    end
  end

  defp deliver_response(response, entry, transport) do
    case response do
      %{"data" => %{"agentSession" => %{"id" => sid, "activities" => %{"nodes" => [%{"id" => aid, "agentSession" => %{"id" => activity_sid}}]}}}}
      when sid == entry.session_id and aid == entry.activity_id and activity_sid == entry.session_id ->
        :ok

      %{"data" => %{"agentSession" => %{"id" => sid, "activities" => %{"nodes" => []}}}} when sid == entry.session_id ->
        create_activity(entry, transport)

      _ ->
        :error
    end
  end

  defp create_activity(entry, transport) do
    create = "mutation SymphonyAgentActivity($input: AgentActivityCreateInput!) { agentActivityCreate(input: $input) { success agentActivity { id agentSession { id } } } }"
    input = %{agentSessionId: entry.session_id, id: entry.activity_id, content: activity_content(entry)}

    case transport.(create, %{input: input}, []) do
      {:ok, %{"errors" => _}} ->
        :error

      {:ok, %{"data" => %{"agentActivityCreate" => %{"success" => true, "agentActivity" => %{"id" => id, "agentSession" => %{"id" => sid}}}}}}
      when id == entry.activity_id and sid == entry.session_id ->
        :ok

      _ ->
        :error
    end
  end

  defp safe_deliver(entry, transport) do
    deliver(entry, transport)
  rescue
    _ -> :error
  end

  defp notify(owner, id) when is_pid(owner), do: send(owner, {:native_outbox_confirmed, id})
  defp notify(owner, id) when is_atom(owner), do: send(owner, {:native_outbox_confirmed, id})
  defp notify(_, _), do: :ok
  defp path(root), do: Path.join(root, "native-outbox.term")
  defp heads(entries), do: entries |> Map.values() |> Enum.group_by(& &1.session_id) |> Map.values() |> Enum.map(fn group -> Enum.min_by(group, &Map.get(&1, :order, 0)) end)

  defp candidate(entries),
    do:
      Enum.find(heads(entries), fn entry -> is_integer(entry.next_at) and entry.next_at <= System.system_time(:millisecond) end)
      |> then(fn
        nil -> nil
        entry -> {entry.id, entry}
      end)

  defp next_order(entries), do: entries |> Map.values() |> Enum.map(&Map.get(&1, :order, 0)) |> Enum.max(fn -> 0 end) |> Kernel.+(1)

  defp normalize_orders(entries) do
    entries
    |> Enum.with_index()
    |> Map.new(fn {{id, entry}, index} ->
      entry = Map.put_new(entry, :order, index)
      entry = if entry[:next_at] == :infinity, do: Map.put(entry, :next_at, System.system_time(:millisecond) + @recovery_delay), else: entry
      {id, entry}
    end)
  end

  defp load(root) do
    case File.read(path(root)) do
      {:ok, data} -> :erlang.binary_to_term(data, [:safe])
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp persist(%{root: root, entries: entries}), do: File.write!(path(root) <> ".tmp", :erlang.term_to_binary(entries)) |> then(fn _ -> File.rename!(path(root) <> ".tmp", path(root)) end)
end
