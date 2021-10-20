defmodule Multiplayer.SessionsHooksProducer do
  use GenStage
  require Logger

  alias Multiplayer.SessionsHooks

  defmodule(State,
    do:
      defstruct(
        timer: nil,
        empty: true,
        data_ts: 0,
        count: 0,
        last_key: nil
      )
  )

  alias Multiplayer.SessionsHooks

  @timeout_check_queue 1000
  @events_batch 50

  def start_link(_opts) do
    GenStage.start_link(__MODULE__, %{})
  end

  @impl true
  def init(_opts) do
    Logger.debug("Started SessionsHooksProducer", pid: self())
    {:producer, %State{timer: send_check()}}
  end

  @impl true
  def handle_info(:check_queue, %State{timer: ref} = state) do
    Process.cancel_timer(ref)

    if SessionsHooks.emtpy_table?() do
      {:noreply, [], %State{state | timer: send_check()}}
    else
      Logger.debug("New sessions hooks")
      {hooks, state_update} = fetch_hooks(0, ts(), nil)
      updated_state = Map.merge(state, state_update)
      {:noreply, hooks, %State{updated_state | empty: false, data_ts: ts()}}
    end
  end

  @impl true
  def handle_demand(_, %State{empty: true} = state) do
    {:noreply, [], state}
  end

  def handle_demand(_, %State{count: count, data_ts: ts, last_key: key} = state) do
    {hooks, state_update} = fetch_hooks(count, ts, key)
    {:noreply, hooks, Map.merge(state, state_update)}
  end

  defp fetch_hooks(count, ts, last_key) do
    case SessionsHooks.take(@events_batch, last_key) do
      {_, []} ->
        exec = ts() - ts

        Logger.debug(
          "Sessions hooks are empty, #{Integer.to_string(count)} records #{Integer.to_string(exec)} sec"
        )

        {[], %{empty: true, last_key: nil, count: 0, timer: send_check()}}

      {last_key, hooks} ->
        {hooks, %{count: count + length(hooks), last_key: last_key}}
    end
  end

  defp ts() do
    System.system_time(:second)
  end

  @spec send_check :: reference
  defp send_check() do
    Process.send_after(
      self(),
      :check_queue,
      @timeout_check_queue
    )
  end
end
