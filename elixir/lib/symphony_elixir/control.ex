defmodule SymphonyElixir.Control do
  @moduledoc "Durable, opt-in per-issue control state and protocol seam."
  use GenServer

  alias SymphonyElixir.Config
  alias SymphonyElixir.Control.ActivityProjection
  alias SymphonyElixir.Control.CiMonitor
  alias SymphonyElixir.Control.CiResult
  alias SymphonyElixir.Control.HandoffBinding
  alias SymphonyElixir.Control.HandoffInbox
  alias SymphonyElixir.Control.LinearBridge
  alias SymphonyElixir.Control.Outbox
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.TerminalHandoff

  @states [:ready, :running, :waiting_user, :waiting_ci, :reviewing, :failed, :completed]
  @ci_table :symphony_control_ci_events

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec authorize_comment(GenServer.server(), String.t(), map()) :: term()
  def authorize_comment(server \\ __MODULE__, issue_id, comment), do: GenServer.call(server, {:comment, issue_id, comment})

  @spec snapshot(GenServer.server(), String.t()) :: map()
  def snapshot(server \\ __MODULE__, issue_id), do: GenServer.call(server, {:snapshot, issue_id})

  @spec publish(GenServer.server(), String.t(), {atom(), map()}) :: :ok
  def publish(server \\ __MODULE__, issue_id, {state, data}) when state in @states, do: GenServer.call(server, {:publish, issue_id, state, data})

  @spec dispatchable?(GenServer.server(), String.t()) :: boolean()
  def dispatchable?(server \\ __MODULE__, issue_id), do: GenServer.call(server, {:dispatchable, issue_id})

  @spec reserve_run(GenServer.server(), String.t()) :: :ok | {:error, atom()}
  def reserve_run(server, issue), do: GenServer.call(server, {:reserve_run, issue})

  @spec finish_run(GenServer.server(), String.t(), atom()) :: :ok
  def finish_run(server, issue, outcome), do: GenServer.call(server, {:finish_run, issue, outcome})

  @spec ci_candidates(GenServer.server()) :: [map()]
  def ci_candidates(server), do: GenServer.call(server, :ci_candidates)

  @spec arm_ci_wait(GenServer.server(), String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def arm_ci_wait(server, issue, payload), do: GenServer.call(server, {:arm_ci_wait, issue, payload})

  @spec apply_ci_result(GenServer.server(), String.t(), String.t(), map()) :: :pending | :ignored | :woken | {:error, atom()}
  def apply_ci_result(server, issue, wait_id, payload), do: GenServer.call(server, {:apply_ci_result, issue, wait_id, payload})

  @spec prepare_terminal_session(GenServer.server(), String.t()) :: :create | {:existing, String.t()} | {:error, atom()}
  def prepare_terminal_session(server, issue), do: GenServer.call(server, {:prepare_terminal_session, issue})

  @spec bind_terminal_session(GenServer.server(), String.t(), String.t(), keyword()) :: :ok | {:error, atom()}
  def bind_terminal_session(server, issue, session, opts \\ []), do: GenServer.call(server, {:bind_terminal_session, issue, session, opts})

  @spec begin_handoff(GenServer.server(), String.t()) :: :ok | {:error, atom()}
  def begin_handoff(server, issue), do: GenServer.call(server, {:begin_handoff, issue})

  @spec finish_handoff(GenServer.server(), String.t(), term()) :: :ok
  def finish_handoff(server, issue, result), do: GenServer.call(server, {:finish_handoff, issue, result})

  @spec take_native_prompt(GenServer.server(), String.t()) :: {:ok, String.t()} | :empty | {:error, term()}
  def take_native_prompt(server \\ __MODULE__, issue_id), do: GenServer.call(server, {:take_native_prompt, issue_id})

  @spec acknowledge_native_prompt(GenServer.server(), String.t()) :: :ok | :empty
  def acknowledge_native_prompt(server \\ __MODULE__, issue_id), do: GenServer.call(server, {:ack_native_prompt, issue_id})

  @spec claim(GenServer.server(), String.t(), Path.t()) :: :ok | {:error, term()}
  def claim(server \\ __MODULE__, issue_id, workspace), do: GenServer.call(server, {:claim, issue_id, workspace})

  @spec release(GenServer.server(), String.t()) :: :ok
  def release(server \\ __MODULE__, issue_id), do: GenServer.call(server, {:release, issue_id})

  @spec import_handoff(GenServer.server(), String.t(), map()) :: :ok | {:error, term()}
  def import_handoff(server \\ __MODULE__, issue_id, record), do: GenServer.call(server, {:import_handoff, issue_id, record})

  @spec sync_issue(GenServer.server(), map(), (String.t(), map() -> {:ok, map()} | {:error, term()})) :: {:ok, term()} | {:error, term()}
  def sync_issue(server \\ __MODULE__, issue, graphql_fun), do: GenServer.call(server, {:sync_issue, issue, graphql_fun})

  @spec accept_native(GenServer.server(), map(), binary()) :: :ok | {:error, term()}
  def accept_native(server \\ __MODULE__, event, body_hash), do: GenServer.call(server, {:accept_native, event, body_hash})

  @spec accept_native(GenServer.server(), map(), binary(), keyword()) :: :ok | {:error, term()}
  def accept_native(server, event, body_hash, opts), do: GenServer.call(server, {:accept_native, event, body_hash, opts})

  @spec register_native_turn(GenServer.server(), String.t(), pid(), String.t(), String.t()) :: :ok
  def register_native_turn(server, issue, owner, thread, turn), do: GenServer.call(server, {:register_native_turn, issue, owner, thread, turn})

  @spec clear_native_turn(GenServer.server(), String.t(), String.t()) :: :ok
  def clear_native_turn(server, issue, turn), do: GenServer.call(server, {:clear_native_turn, issue, turn})

  @spec protocol_request(atom(), map()) :: {:ok, map()} | {:error, atom()}
  def protocol_request(:resume, %{thread_id: id} = params) when is_binary(id) do
    if model_available?(Map.get(params, :model)), do: {:ok, %{method: "thread/resume", params: %{"threadId" => id}}}, else: {:error, :model_unavailable}
  end

  def protocol_request(:terminal_handoff, %{source_dirty: true}), do: {:error, :dirty_source}

  def protocol_request(:terminal_handoff, %{thread_id: id, source_dirty: false} = params) when is_binary(id) do
    if model_available?(Map.get(params, :model)) do
      {:ok, %{method: "thread/fork", params: %{"threadId" => id, "cwd" => Path.join(System.tmp_dir!(), "symphony-fork-#{System.unique_integer([:positive])}"), "model" => Map.get(params, :model)}}}
    else
      {:error, :model_unavailable}
    end
  end

  def protocol_request(:review, %{thread_id: id} = params) when is_binary(id) do
    if model_available?(Map.get(params, :model)),
      do:
        {:ok,
         %{method: "thread/start", params: %{"threadId" => id, "model" => Map.get(params, :model), "cwd" => Path.join(System.tmp_dir!(), "symphony-review-#{System.unique_integer([:positive])}")}}},
      else: {:error, :model_unavailable}
  end

  @spec ci_event(String.t(), map()) :: {:ok, :pending | :wake} | {:duplicate, :wake} | {:error, :provider_failed}
  def ci_event(issue_id, %{status: status}) do
    table = ensure_ci_table()

    case status do
      s when s in [:unknown, :pending] ->
        :ets.insert(table, {issue_id, :pending})
        {:ok, :pending}

      :completed ->
        case :ets.lookup(table, issue_id) do
          [{^issue_id, :woken}] ->
            {:duplicate, :wake}

          _ ->
            :ets.insert(table, {issue_id, :woken})
            {:ok, :wake}
        end

      :provider_failed ->
        {:error, :provider_failed}

      _ ->
        {:ok, :pending}
    end
  end

  @impl true
  def init(opts) do
    enabled = Keyword.get(opts, :enabled, false)
    state_root = Keyword.get(opts, :state_root, Path.join(System.tmp_dir!(), "symphony-control-state"))
    workspace_root = Keyword.get(opts, :workspace_root)

    graphql_client =
      Keyword.get(opts, :graphql_client, fn query, variables, graphql_opts ->
        Client.graphql(query, variables, Keyword.put(graphql_opts, :request_timeout_ms, 1_000))
      end)

    with {:ok, canonical_state} <- PathSafety.canonicalize(state_root),
         {:ok, canonical_workspace} <- canonical_workspace_root(workspace_root),
         :ok <- validate_roots(enabled, canonical_state, canonical_workspace) do
      case acquire_lock(enabled, canonical_state) do
        {:error, reason} ->
          {:stop, reason}

        {:ok, lock} ->
          File.mkdir_p!(canonical_state)
          loaded = load_records(canonical_state)
          {outbox, outbox_owned} = start_outbox(enabled, canonical_state, graphql_client, opts)
          inbox = start_inbox(enabled, canonical_state, opts)

          state = %{
            enabled: enabled,
            graphql_client: graphql_client,
            lock: lock,
            state_root: canonical_state,
            workspace_root: canonical_workspace,
            actors: MapSet.new(Keyword.get(opts, :allowed_actor_ids, [])),
            controller: Keyword.get(opts, :controller_actor_id, "controller"),
            records: Map.delete(loaded, "__native_deliveries"),
            runtime_owners: %{},
            claims: %{},
            native_deliveries: Map.get(loaded, "__native_deliveries", %{}),
            outbox: outbox,
            inbox: inbox,
            outbox_owned: outbox_owned
          }

          state = recover_native_outbox(state, opts)
          activate_owned_outbox(outbox_owned, outbox)

          monitor = start_ci_monitor(enabled, opts)

          {:ok, Map.put(state, :ci_monitor, monitor)}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp canonical_workspace_root(root) do
    if root, do: PathSafety.canonicalize(root), else: {:ok, nil}
  end

  defp activate_owned_outbox(true, outbox), do: Outbox.activate(outbox)
  defp activate_owned_outbox(false, _outbox), do: nil

  defp start_ci_monitor(false, _opts), do: nil

  defp start_ci_monitor(true, opts) do
    monitor_opts = [owner: self(), provider: Keyword.get(opts, :ci_provider)]
    interval = Keyword.get(opts, :ci_interval_ms, 30_000)
    {:ok, pid} = CiMonitor.start_link(Keyword.put(monitor_opts, :interval_ms, interval))
    pid
  end

  defp start_outbox(false, _root, _transport, _opts), do: {nil, false}

  defp start_outbox(true, root, transport, opts) do
    case Keyword.get(opts, :outbox_server) do
      nil ->
        {:ok, pid} = Outbox.start_link(name: nil, state_root: root, transport: transport, owner: self(), paused: true)
        {pid, true}

      configured ->
        {configured, false}
    end
  end

  defp start_inbox(false, _root, _opts), do: nil

  defp start_inbox(true, root, opts) do
    owner = self()
    importer = Keyword.get(opts, :handoff_importer, &TerminalHandoff.import/2)

    config =
      Keyword.get_lazy(opts, :native_session_config, fn ->
        Map.from_struct(Config.settings!().linear_agent_session)
      end)

    binding_opts = [config: config, graphql: Keyword.get(opts, :graphql_client, &Client.graphql/3)]
    handler = fn entry, _inbox_opts -> import_inbox_entry(entry, owner, root, importer, binding_opts) end
    {:ok, pid} = HandoffInbox.start_link(state_root: root, owner: owner, importer: handler)
    pid
  end

  defp import_inbox_entry(entry, owner, root, importer, binding_opts) do
    request =
      Map.new([:source_workspace, :issue_id, :thread_id, :summary_file, :expected_fingerprint], fn key ->
        {key, Map.get(entry, Atom.to_string(key))}
      end)

    with {:ok, request} <- HandoffBinding.resolve(request, binding_opts),
         :ok <- begin_handoff(owner, request.issue_id) do
      result = import_bound_handoff(request, entry, owner, root, importer, binding_opts)
      :ok = finish_handoff(owner, request.issue_id, result)
      result
    end
  end

  defp import_bound_handoff(request, entry, owner, root, importer, binding_opts) do
    import_opts = [state_root: root, control_server: owner, repository: entry["repository"]]

    with {:ok, record} <- importer.(request, import_opts),
         :ok <- HandoffBinding.connect(owner, request.issue_id, binding_opts) do
      {:ok, record}
    end
  end

  defp acquire_lock(false, _root), do: {:ok, nil}

  defp acquire_lock(true, root) do
    executable = System.find_executable("python3")

    if executable == nil do
      {:error, :python3_unavailable}
    else
      lockfile = Path.join(root, "control.lock")
      File.mkdir_p!(root)

      port =
        Port.open({:spawn_executable, executable}, [
          :binary,
          {:args, ["-c", "import fcntl,sys\nf=open(sys.argv[1],'a')\nf.fileno()\nf = f\nfcntl.flock(f, fcntl.LOCK_EX|fcntl.LOCK_NB)\nprint('acquired', flush=True)\nsys.stdin.read()", lockfile]}
        ])

      receive do
        {^port, {:data, "acquired\n"}} ->
          {:ok, port}

        {^port, {:data, _}} ->
          Port.close(port)
          {:error, :lock_not_acquired}
      after
        1_000 ->
          Port.close(port)
          {:error, :lock_timeout}
      end
    end
  end

  @impl true
  def handle_info({port, {:exit_status, _status}}, %{lock: port}), do: {:stop, :lock_lost, %{}}
  def handle_info({:EXIT, port, _reason}, %{lock: port}), do: {:stop, :lock_lost, %{}}

  def handle_info({:native_outbox_confirmed, activity_id}, state) do
    records =
      Map.new(state.records, fn {issue, record} ->
        record = if record[:native_activity_id] == activity_id, do: Map.put(record, :projection_pending, false), else: record
        record = if Map.has_key?(Map.get(record, :native_pending_activities, %{}), activity_id), do: Map.update!(record, :native_pending_activities, &Map.delete(&1, activity_id)), else: record

        record =
          if record[:native_delivery_delayed] == true and record[:projection_pending] != true and Map.get(record, :native_pending_activities, %{}) == %{},
            do: Map.put(record, :native_delivery_delayed, false),
            else: record

        {issue, record}
      end)

    next = %{state | records: records}
    if records != state.records, do: persist(next)
    {:noreply, next}
  end

  def handle_info({:native_outbox_delayed, activity_id}, state) do
    records =
      Map.new(state.records, fn {issue, record} ->
        affected = record[:native_activity_id] == activity_id or Map.has_key?(Map.get(record, :native_pending_activities, %{}), activity_id)
        {issue, if(affected, do: Map.put(record, :native_delivery_delayed, true), else: record)}
      end)

    next = %{state | records: records}
    if records != state.records, do: persist(next)
    {:noreply, next}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_pid(state[:ci_monitor]) do
      Process.unlink(state.ci_monitor)
      Process.exit(state.ci_monitor, :shutdown)
    end

    if is_pid(state[:inbox]) and Process.alive?(state.inbox), do: GenServer.stop(state.inbox, :normal)
    if state[:outbox_owned] == true and is_pid(state[:outbox]) and Process.alive?(state.outbox), do: GenServer.stop(state.outbox, :normal)
    :ok
  end

  @impl true
  def handle_call({:comment, _issue, _comment}, _from, %{enabled: false} = state), do: {:reply, {:disabled, :control_disabled}, state}

  def handle_call({:comment, issue, comment}, _from, state) do
    id = comment_field(comment, :id)
    actor = comment_field(comment, :user_id)
    comment_issue = comment_field(comment, :issue_id)
    body = comment_field(comment, :body)

    cond do
      not valid_comment_id?(id) ->
        {:reply, {:error, :invalid_comment}, state}

      comment_issue != issue ->
        {:reply, {:error, :wrong_issue}, state}

      not valid_comment_command?(body) ->
        {:reply, {:error, :invalid_command}, state}

      actor == state.controller ->
        {:reply, {:error, :controller_comment}, state}

      not MapSet.member?(state.actors, actor) ->
        {:reply, {:error, :unauthorized_actor}, state}

      Map.has_key?(Map.get(state.records, issue, %{}), :comments) and id in Map.get(state.records[issue], :comments) ->
        {:reply, {:duplicate, id}, state}

      true ->
        record = Map.get(state.records, issue, %{state: :ready, comments: []}) |> Map.update(:comments, [id], &[id | &1]) |> Map.put(:state, :ready)
        next = put_in(state.records[issue], record)
        persist(next)
        {:reply, {:ok, :resume}, next}
    end
  end

  def handle_call({:publish, _issue, _event, _data}, _from, %{enabled: false} = state), do: {:reply, :ok, state}
  def handle_call({:snapshot, issue}, _from, state), do: {:reply, Map.get(state.records, issue, %{state: :ready}), state}

  def handle_call({:register_native_turn, issue, owner, thread, turn}, _from, state) do
    if get_in(state.records, [issue, :paused]) == true,
      do: {:reply, {:error, :native_paused}, state},
      else: {:reply, :ok, put_in(state.runtime_owners[issue], %{owner: owner, thread_id: thread, turn_id: turn})}
  end

  def handle_call({:clear_native_turn, issue, turn}, _from, state) do
    next = if is_binary(turn) and get_in(state.runtime_owners, [issue, :turn_id]) == turn, do: update_in(state.runtime_owners, &Map.delete(&1, issue)), else: state
    {:reply, :ok, next}
  end

  def handle_call({:accept_native, event, body_hash}, _from, state) do
    if state.enabled do
      handle_native_accept(event, body_hash, [], state)
    else
      {:reply, {:error, :control_disabled}, state}
    end
  end

  def handle_call({:accept_native, event, body_hash, opts}, _from, state) do
    if state.enabled do
      handle_native_accept(event, body_hash, opts, state)
    else
      {:reply, {:error, :control_disabled}, state}
    end
  end

  def handle_call({:publish, issue, event, data}, _from, state) do
    previous = Map.get(state.records, issue, %{})

    event =
      cond do
        previous[:paused] == true -> :waiting_user
        event in [:waiting_user, :waiting_ci, :completed] and pending_input?(previous) -> :ready
        true -> event
      end

    record =
      Map.merge(Map.get(state.records, issue, %{}), %{state: event})
      |> Map.merge(Map.take(data, [:prompt_id, :pr_id, :result, :error, :thread_id, :turn_id, :owner_pid, :workspace, :model, :phase]))

    record = if event == :waiting_ci and previous[:state] != :waiting_ci, do: Map.put(record, :ci_discovery_required, true), else: record
    next = put_in(state.records[issue], record)
    persist(next)
    {:reply, :ok, project_phase(next, issue, event)}
  end

  def handle_call({:import_handoff, _issue, _record}, _from, %{enabled: false} = state), do: {:reply, {:error, :control_disabled}, state}

  def handle_call({:import_handoff, issue, record}, _from, state) when is_map(record) do
    workspace = record[:workspace] || record["workspace"]
    thread = record[:thread] || record["thread"]
    root = state.workspace_root
    canonical_workspace = if is_binary(workspace), do: PathSafety.canonicalize(workspace), else: {:error, :invalid}
    valid = is_binary(thread) and root != nil and match?({:ok, _}, canonical_workspace) and not unsafe_child?(elem(canonical_workspace, 1), Path.expand(root))

    if valid do
      data = %{workspace: workspace, thread_id: thread, handoff: true, summary: record[:summary] || record["summary"]}
      next = put_in(state.records[issue], Map.merge(Map.get(state.records, issue, %{}), data))
      persist(next)
      {:reply, :ok, next}
    else
      {:reply, {:error, :unsafe_handoff}, state}
    end
  end

  def handle_call({:sync_issue, _issue, _fun}, _from, %{enabled: false} = state), do: {:reply, {:ok, :disabled}, state}

  def handle_call({:sync_issue, %{id: issue_id} = issue, graphql_fun}, _from, state) when is_function(graphql_fun, 2) do
    actors = MapSet.to_list(state.actors)

    with {:ok, comments} <- LinearBridge.fetch_comments(issue_id, graphql_fun) do
      Enum.each(comments, fn comment ->
        _ = LinearBridge.command(comment, actors, state.controller)
      end)

      record = Map.get(state.records, issue_id, %{state: :ready})
      stable = Map.get(record, :projection_comment_id) || ""
      pending = Map.put(record, :projection_pending, true) |> Map.put(:projection_comment_id, stable)
      next = put_in(state.records[issue_id], pending)
      persist(next)

      case LinearBridge.project(issue_id, Map.merge(issue, pending), graphql_fun) do
        {:ok, result} ->
          final = put_in(next.records[issue_id][:projection_pending], false)
          persist(final)
          {:reply, {:ok, result}, final}

        {:error, reason} ->
          {:reply, {:error, reason}, next}
      end
    end
  end

  def handle_call({:dispatchable, issue}, _from, state) do
    {:reply, record_dispatchable?(Map.get(state.records, issue, %{})), state}
  end

  def handle_call({:reserve_run, issue}, _from, state) do
    record = Map.get(state.records, issue, %{})

    if state.enabled and record_dispatchable?(record) do
      next = put_in(state.records[issue], Map.merge(record, %{run_reserved: true, state: :running}))
      persist(next)
      {:reply, :ok, project_phase(next, issue, :running)}
    else
      {:reply, {:error, :not_dispatchable}, state}
    end
  end

  def handle_call({:finish_run, issue, outcome}, _from, state) do
    record = Map.get(state.records, issue, %{})

    phase =
      cond do
        record[:paused] == true -> :waiting_user
        outcome != :normal -> :failed
        pending_input?(record) -> :ready
        record[:state] in [:waiting_ci, :completed, :waiting_user] -> record.state
        true -> :waiting_user
      end

    next = put_in(state.records[issue], Map.merge(record, %{run_reserved: false, state: phase}))
    persist(next)
    {:reply, :ok, project_phase(next, issue, phase)}
  end

  def handle_call(:ci_candidates, _from, state) do
    candidates =
      if state.enabled do
        for {id, record} <- state.records,
            waiting_ci?(record) and ci_execution_idle?(record) and is_binary(record[:workspace]) do
          wait = saved_ci_wait(record)
          %{issue_id: id, workspace: record.workspace, wait: wait}
        end
      else
        []
      end

    {:reply, candidates, state}
  end

  def handle_call({:arm_ci_wait, issue, payload}, _from, state) do
    record = Map.get(state.records, issue, %{})

    with true <- state.enabled and waiting_ci?(record),
         {:ok, target} <- CiResult.target(payload) do
      arm_ci_target(state, issue, record, target)
    else
      false -> {:reply, {:error, :not_waiting_ci}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:apply_ci_result, issue, wait_id, payload}, _from, state) do
    record = Map.get(state.records, issue, %{})
    wait = record[:ci_wait]

    eligible = state.enabled and record[:state] == :waiting_ci and record[:paused] != true

    if eligible and ci_execution_idle?(record) and active_ci_wait?(wait, wait_id) do
      case CiResult.classify(wait, payload) do
        :completed ->
          prompt = %{id: "ci:" <> wait_id, body: "CI checks for the saved PR commit have finished. Inspect their results and continue the existing task; completion does not imply success."}
          updated = Map.merge(record, %{state: :ready, ci_wait: Map.put(wait, :consumed, true), prompts: Map.get(record, :prompts, []) ++ [prompt]})
          next = put_in(state.records[issue], updated)
          persist(next)
          {:reply, :woken, project_phase(next, issue, :ready)}

        result ->
          {:reply, result, state}
      end
    else
      {:reply, :ignored, state}
    end
  end

  def handle_call({:prepare_terminal_session, issue}, _from, state) do
    record = Map.get(state.records, issue, %{})

    cond do
      not state.enabled or record[:handoff] != true ->
        {:reply, {:error, :handoff_required}, state}

      is_binary(record[:native_session_id]) ->
        {:reply, {:existing, record.native_session_id}, state}

      record[:session_creation_pending] == true ->
        {:reply, {:error, :session_creation_unresolved}, state}

      true ->
        next = put_in(state.records[issue], Map.put(record, :session_creation_pending, true))
        persist(next)
        {:reply, :create, next}
    end
  end

  def handle_call({:bind_terminal_session, issue, session, opts}, _from, state) do
    record = Map.get(state.records, issue, %{})

    cond do
      not state.enabled or record[:handoff] != true ->
        {:reply, {:error, :handoff_required}, state}

      not is_binary(session) or session == "" ->
        {:reply, {:error, :invalid_session}, state}

      record[:native_session_id] not in [nil, session] ->
        {:reply, {:error, :native_session_conflict}, state}

      true ->
        data = %{
          native_session_id: session,
          issue_id: issue,
          session_creation_pending: false,
          initial_prompt: nil,
          native_activity_id: record[:native_activity_id] || uuid_v4(),
          projection_pending: true
        }

        next = put_in(state.records[issue], Map.merge(record, data))
        persist(next)
        {:reply, :ok, schedule_native_ack(next, opts)}
    end
  end

  def handle_call({:begin_handoff, _issue}, _from, %{enabled: false} = state), do: {:reply, {:error, :control_disabled}, state}

  def handle_call({:begin_handoff, issue}, _from, state) do
    record = Map.get(state.records, issue, %{})

    if record[:run_reserved] == true or record[:state] == :running or record[:handoff_status] == :importing do
      {:reply, {:error, :issue_busy}, state}
    else
      next = put_in(state.records[issue], Map.merge(record, %{handoff_pending: true, handoff_status: :importing, state: :waiting_user}))
      persist(next)
      {:reply, :ok, next}
    end
  end

  def handle_call({:finish_handoff, issue, result}, _from, state) do
    record = Map.get(state.records, issue, %{})
    success = match?({:ok, _}, result)

    phase =
      cond do
        not success -> :failed
        record[:paused] != true and pending_input?(record) -> :ready
        true -> :waiting_user
      end

    data = %{handoff_pending: false, handoff_status: if(success, do: :complete, else: :failed), state: phase}
    next = put_in(state.records[issue], Map.merge(record, data))
    persist(next)
    {:reply, :ok, project_phase(next, issue, data.state)}
  end

  def handle_call({:take_native_prompt, issue}, _from, state) do
    record = Map.get(state.records, issue, %{})
    prompts = Map.get(record, :prompts, [])
    consumed_ids = Map.get(record, :consumed_prompt_ids, [])
    claimed_ids = Map.get(record, :claimed_prompt_ids, [])

    initial = Map.get(record, :initial_prompt)

    if available_prompt?(initial, consumed_ids, claimed_ids) do
      prompt_id = initial[:id] || initial["id"]
      updated = Map.put(record, :claimed_prompt_ids, [prompt_id | claimed_ids])
      next = put_in(state.records[issue], updated)
      persist(next)
      {:reply, {:ok, initial[:body] || initial["body"]}, next}
    else
      take_queued_native_prompt(issue, record, prompts, consumed_ids, claimed_ids, state)
    end
  end

  def handle_call({:ack_native_prompt, issue}, _from, state) do
    record = Map.get(state.records, issue, %{})
    claimed_ids = Map.get(record, :claimed_prompt_ids, [])

    case claimed_ids do
      [prompt_id | rest] ->
        updated = Map.merge(record, %{claimed_prompt_ids: rest, consumed_prompt_ids: [prompt_id | Map.get(record, :consumed_prompt_ids, [])]})
        next = put_in(state.records[issue], updated)
        persist(next)
        {:reply, :ok, next}

      [] ->
        {:reply, :empty, state}
    end
  end

  def handle_call({:claim, _issue, _workspace}, _from, %{enabled: false} = state), do: {:reply, :ok, state}

  def handle_call({:claim, issue, workspace}, _from, %{workspace_root: root} = state) do
    case PathSafety.canonicalize(workspace) do
      {:error, reason} -> {:reply, {:error, reason}, state}
      {:ok, expanded} -> claim_canonical(state, issue, workspace, expanded, root)
    end
  end

  def handle_call({:release, issue}, _from, state), do: {:reply, :ok, update_in(state.claims, &Map.delete(&1, issue))}

  defp handle_native_accept(event, body_hash, opts, state) do
    state = %{state | graphql_client: Keyword.get(opts, :graphql_client, state.graphql_client)}
    delivery = event["_delivery"]
    deliveries = Map.get(state, :native_deliveries, %{})

    case Map.get(deliveries, delivery) do
      ^body_hash ->
        {:reply, :ok, if(event["action"] == "created", do: schedule_native_ack(state, opts), else: state)}

      existing when not is_nil(existing) ->
        {:reply, {:error, :delivery_body_collision}, state}

      nil ->
        accept_new_native_delivery(event, body_hash, opts, state, deliveries, delivery)
    end
  end

  defp accept_new_native_delivery(event, body_hash, opts, state, deliveries, delivery) do
    case native_record(event, state, opts) do
      {:ok, next} ->
        next = %{next | native_deliveries: Map.put(deliveries, delivery, body_hash)}
        persist(next)
        issue_id = get_in(event, ["agentSession", "issue", "id"])
        previous = Map.get(state.records, issue_id, %{})
        current = Map.get(next.records, issue_id, %{})

        next =
          if event["action"] == "prompted" and previous[:paused] != current[:paused] do
            project_phase(next, issue_id, current[:state])
          else
            next
          end

        invoke_native_interrupt(event, Keyword.put(opts, :runtime_owner, state.runtime_owners[issue_id]), issue_id, current)

        {:reply, :ok, schedule_native_ack(next, opts)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp invoke_native_interrupt(%{"action" => "prompted", "agentActivity" => %{"signal" => "stop"}}, opts, issue_id, _record) do
    case Keyword.get(opts, :interrupt) do
      interrupt when is_function(interrupt, 1) ->
        interrupt.(issue_id)

      _ ->
        case get_in(opts, [:runtime_owner]) do
          %{owner: owner, thread_id: thread, turn_id: turn}
          when is_pid(owner) and is_binary(thread) and is_binary(turn) ->
            send(owner, {:native_interrupt, thread, turn})

          _ ->
            :ok
        end
    end
  end

  defp invoke_native_interrupt(_event, _opts, _issue_id, _record), do: :ok

  defp comment_field(comment, key), do: Map.get(comment, key) || Map.get(comment, Atom.to_string(key))

  defp valid_comment_id?(id), do: is_binary(id) and String.trim(id) != ""

  defp valid_comment_command?(body) when is_binary(body) do
    Regex.match?(~r/^\/symphony\s+(resume|pause|review|approve)(?:\s+.*)?$/u, String.trim(body))
  end

  defp valid_comment_command?(_body), do: false

  defp saved_ci_wait(%{ci_discovery_required: true}), do: nil
  defp saved_ci_wait(record), do: record[:ci_wait]

  defp active_ci_wait?(wait, wait_id) when is_map(wait) do
    wait[:id] == wait_id and wait[:consumed] == false
  end

  defp active_ci_wait?(_wait, _wait_id), do: false

  defp waiting_ci?(record) do
    record[:state] == :waiting_ci and record[:paused] != true and is_binary(record[:native_session_id])
  end

  defp ci_execution_idle?(record) do
    record[:run_reserved] != true and not pending_input?(record)
  end

  defp arm_ci_target(state, issue, record, target) do
    old = record[:ci_wait]

    cond do
      is_map(old) and Map.take(old, [:pr_url, :head_sha]) == target and old[:consumed] == true ->
        {:reply, {:error, :ci_already_handled}, state}

      is_map(old) and Map.take(old, [:pr_url, :head_sha]) == target ->
        next = put_in(state.records[issue], Map.put(record, :ci_discovery_required, false))
        if record[:ci_discovery_required] == true, do: persist(next)
        {:reply, {:ok, old}, next}

      true ->
        wait = Map.merge(target, %{id: uuid_v4(), consumed: false})
        next = put_in(state.records[issue], Map.merge(record, %{ci_wait: wait, ci_discovery_required: false}))
        persist(next)
        {:reply, {:ok, wait}, next}
    end
  end

  defp available_prompt?(prompt, consumed_ids, claimed_ids) when is_map(prompt) do
    id = prompt[:id] || prompt["id"]
    id not in consumed_ids and id not in claimed_ids
  end

  defp available_prompt?(_prompt, _consumed_ids, _claimed_ids), do: false

  defp take_queued_native_prompt(issue, record, prompts, consumed_ids, claimed_ids, state) do
    case Enum.split_while(prompts, fn prompt ->
           id = Map.get(prompt, :id) || Map.get(prompt, "id")
           id in consumed_ids or id in claimed_ids
         end) do
      {_consumed, []} ->
        {:reply, :empty, state}

      {consumed, [prompt | rest]} ->
        body = Map.get(prompt, :body) || Map.get(prompt, "body")
        prompt_id = Map.get(prompt, :id) || Map.get(prompt, "id")
        updated = Map.merge(record, %{prompts: consumed ++ [prompt | rest], claimed_prompt_ids: [prompt_id | claimed_ids]})
        next = put_in(state.records[issue], updated)
        persist(next)
        {:reply, if(is_binary(body), do: {:ok, body}, else: {:error, :invalid_prompt}), next}
    end
  end

  defp claim_canonical(state, issue, workspace, expanded, root) do
    cond do
      root && unsafe_child?(expanded, Path.expand(root)) -> {:reply, {:error, :unsafe_workspace}, state}
      Map.has_key?(state.claims, issue) -> {:reply, {:error, :already_claimed}, state}
      true -> {:reply, :ok, put_in(state.claims[issue], workspace)}
    end
  end

  defp model_available?(nil), do: false
  defp model_available?("gpt-5.6-luna"), do: true
  defp model_available?(_), do: false

  defp validate_roots(true, state, workspace) when is_binary(workspace) do
    prefix = workspace <> "/"

    if state == workspace or String.starts_with?(state <> "/", prefix) do
      {:error, :state_root_inside_workspace}
    else
      :ok
    end
  end

  defp validate_roots(_enabled, _state, _workspace), do: :ok

  defp unsafe_child?(path, root) do
    path == root or not String.starts_with?(path <> "/", root <> "/")
  end

  defp ensure_ci_table do
    case :ets.whereis(@ci_table) do
      :undefined -> :ets.new(@ci_table, [:named_table, :public, read_concurrency: true])
      _ -> @ci_table
    end
  end

  defp load_records(root) do
    case File.read(Path.join(root, "records.term")) do
      {:ok, data} ->
        try do
          records = :erlang.binary_to_term(data, [:safe])

          if is_map(records) and Enum.all?(records, fn {key, value} -> is_binary(key) and is_map(value) end) do
            records
          else
            raise ArgumentError, "invalid control state"
          end
        rescue
          _ -> reraise ArgumentError, [message: "invalid control state; restore durable state before starting"], __STACKTRACE__
        end

      {:error, :enoent} ->
        %{}

      {:error, _} ->
        raise ArgumentError, "control state could not be read"
    end
  end

  defp persist(%{state_root: root, records: records, native_deliveries: deliveries}) do
    path = Path.join(root, "records.term")
    tmp = path <> ".tmp"
    File.write!(tmp, :erlang.term_to_binary(Map.put(records, "__native_deliveries", deliveries)))
    File.rename!(tmp, path)
    :ok
  end

  defp native_record(%{"action" => "created", "agentSession" => session} = event, state, _opts) do
    id = session["id"]
    issue_id = get_in(session, ["issue", "id"])
    existing = Map.get(state.records, issue_id, %{})

    if existing[:native_session_id] in [nil, id] do
      prompt_context = event["promptContext"] || session["promptContext"]

      initial_prompt = initial_native_prompt(existing, id, prompt_context)

      record = Map.merge(existing, %{native_session_id: id, issue_id: issue_id, prompt_context: prompt_context, initial_prompt: initial_prompt})
      record = if Map.has_key?(existing, :state), do: record, else: Map.put(record, :state, :ready)
      record = Map.put_new(record, :native_activity_id, uuid_v4())

      {:ok, put_in(state.records[issue_id], Map.put(record, :projection_pending, true))}
    else
      {:error, :native_session_conflict}
    end
  end

  defp native_record(%{"action" => "prompted", "agentSession" => session, "agentActivity" => activity}, state, _opts) do
    id = session["id"]
    issue_id = get_in(session, ["issue", "id"])
    activity_id = activity["id"]
    record = Map.get(state.records, issue_id)

    if is_nil(record) or record[:native_session_id] != id do
      {:error, :unknown_native_session}
    else
      append_native_activity(state, issue_id, record, activity_id, activity)
    end
  end

  defp native_record(_, _state, _opts), do: {:error, :invalid_event}

  defp initial_native_prompt(existing, id, context) do
    if existing[:handoff] != true and existing[:handoff_pending] != true and is_binary(context) and context != "" do
      %{id: "native-created:" <> id, body: context}
    end
  end

  defp append_native_activity(state, issue_id, record, activity_id, activity) do
    body = get_in(activity, ["content", "body"]) || activity["body"]
    prompts = Map.get(record, :prompts, [])

    if Enum.any?(prompts, &(&1[:id] == activity_id)) do
      {:ok, state}
    else
      updated =
        record
        |> Map.put(:prompts, prompts ++ [%{id: activity_id, body: body}])
        |> apply_native_signal(activity, body)

      {:ok, put_in(state.records[issue_id], updated)}
    end
  end

  defp apply_native_signal(record, %{"signal" => "stop"} = activity, _body) do
    consumed = [activity["id"] | Map.get(record, :consumed_prompt_ids, [])]
    Map.merge(record, %{state: :waiting_user, paused: true, consumed_prompt_ids: consumed})
  end

  defp apply_native_signal(record, _activity, body) do
    cond do
      explicit_resume?(body) -> Map.merge(record, %{state: :ready, paused: false})
      record[:paused] == true -> Map.put(record, :state, :waiting_user)
      true -> Map.put(record, :state, :ready)
    end
  end

  defp explicit_resume?(body) when is_binary(body), do: String.downcase(String.trim(body)) in ["resume", "/resume", "再開"]
  defp explicit_resume?(_), do: false

  defp initial_projection_pending?(record) do
    record[:projection_pending] == true and
      is_binary(record[:native_session_id]) and is_binary(record[:native_activity_id])
  end

  defp initial_projection_item(record) do
    %{
      id: record[:native_activity_id],
      session_id: record[:native_session_id],
      activity_id: record[:native_activity_id],
      order: 0,
      body: "依頼を受け付けました。実行を準備しています。"
    }
  end

  defp schedule_native_ack(%{outbox: outbox} = state, opts) do
    transport = Keyword.get(opts, :graphql_client, state.graphql_client)

    Enum.each(state.records, fn {_issue, record} ->
      if initial_projection_pending?(record) do
        item = initial_projection_item(record)
        _ = Outbox.enqueue(outbox, item, transport, self())
      end
    end)

    state
  end

  defp recover_native_outbox(%{enabled: true, outbox: outbox} = state, opts) do
    transport = Keyword.get(opts, :graphql_client, state.graphql_client)

    _ = schedule_native_ack(state, opts)

    Enum.each(state.records, fn {_issue, record} ->
      record
      |> Map.get(:native_pending_activities, %{})
      |> Map.values()
      |> Enum.sort_by(& &1.order)
      |> Enum.each(fn item -> Outbox.enqueue(outbox, item, transport, self()) end)
    end)

    state
  end

  defp recover_native_outbox(state, _opts), do: state

  defp project_phase(%{enabled: true} = state, issue, phase) do
    record = Map.get(state.records, issue, %{})
    phase = if record[:paused] == true, do: :paused, else: phase

    if is_binary(record[:native_session_id]) and record[:last_native_phase] != phase and
         match?({:ok, _}, ActivityProjection.content(phase)) do
      sequence = Map.get(record, :native_activity_sequence, 0) + 1
      id = uuid_v4()
      item = %{id: id, activity_id: id, session_id: record.native_session_id, phase: phase, order: sequence}
      pending = Map.put(Map.get(record, :native_pending_activities, %{}), id, item)
      record = Map.merge(record, %{last_native_phase: phase, native_activity_sequence: sequence, native_pending_activities: pending})
      next = put_in(state.records[issue], record)
      persist(next)
      Outbox.enqueue(state.outbox, item, state.graphql_client, self())
      next
    else
      state
    end
  end

  defp project_phase(state, _issue, _phase), do: state

  defp record_dispatchable?(record) do
    holds = [:projection_pending, :handoff_pending, :run_reserved, :paused]
    Enum.all?(holds, &(record[&1] != true)) and record[:state] in [nil, :ready]
  end

  defp pending_input?(record) do
    used = Map.get(record, :consumed_prompt_ids, []) ++ Map.get(record, :claimed_prompt_ids, [])
    prompts = List.wrap(record[:initial_prompt]) ++ Map.get(record, :prompts, [])
    Enum.any?(prompts, fn prompt -> (prompt[:id] || prompt["id"]) not in used end)
  end

  defp uuid_v4, do: Ecto.UUID.generate()
end
