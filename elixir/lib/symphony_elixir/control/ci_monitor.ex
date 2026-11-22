defmodule SymphonyElixir.Control.CiMonitor do
  @moduledoc "Owner-bound serial CI monitor."
  use GenServer
  alias SymphonyElixir.Control
  alias SymphonyElixir.Control.CiProvider

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

  @spec poll_now(GenServer.server()) :: :ok
  def poll_now(server), do: GenServer.call(server, :poll_now, :infinity)

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    Process.link(owner)
    ref = Process.monitor(owner)
    interval = Keyword.get(opts, :interval_ms, 30_000)
    state = %{owner: owner, owner_ref: ref, provider: Keyword.get(opts, :provider) || (&read_provider/2), interval: interval, timer: nil, timer_token: nil}
    {:ok, schedule(state, interval)}
  end

  @impl true
  def handle_call(:poll_now, _from, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    state = poll(state)
    {:reply, :ok, schedule(state, state.interval)}
  end

  @impl true
  def handle_info({:poll, token}, %{timer_token: token} = state), do: {:noreply, schedule(poll(state), state.interval)}
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state), do: {:stop, :owner_down, state}
  def handle_info(_, state), do: {:noreply, state}

  defp poll(state) do
    Enum.each(Control.ci_candidates(state.owner), &poll_candidate(state, &1))
    state
  end

  defp poll_candidate(state, %{issue_id: issue, workspace: workspace, wait: wait}) do
    with {:ok, payload} <- state.provider.(workspace, wait),
         {:ok, armed} <- Control.arm_ci_wait(state.owner, issue, payload) do
      Control.apply_ci_result(state.owner, issue, armed.id, payload)
    else
      _ -> :ignored
    end
  rescue
    _ -> :ignored
  end

  defp read_provider(workspace, nil), do: CiProvider.capture(workspace)
  defp read_provider(workspace, wait), do: CiProvider.poll(workspace, wait)

  defp schedule(state, delay) do
    token = make_ref()
    %{state | timer: Process.send_after(self(), {:poll, token}, delay), timer_token: token}
  end
end
