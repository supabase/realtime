defmodule Extensions.Postgres.SubscriptionManager do
  use GenServer
  require Logger

  alias Extensions.Postgres
  alias Postgres.Subscriptions

  import Realtime.Helpers, only: [cancel_timer: 1]

  @check_active_interval 15_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    :global.register_name({:subscription_manager, opts.id}, self())
    Subscriptions.delete_all(opts.conn)

    {:ok,
     %{
       conn: opts.conn,
       id: opts.id,
       subscribers_tid: opts.subscribers_tid,
       publication: opts.publication,
       check_active_pids: nil
     }}
  end

  def subscribe(pid, opts) do
    send(pid, {:subscribe, opts})
  end

  def subscribers_list(pid) do
    GenServer.call(pid, :subscribers_list)
  end

  @spec unsubscribe(atom | pid | port | reference | {atom, atom}, any) :: any
  def unsubscribe(pid, subs_id) do
    send(pid, {:unsubscribe, subs_id})
  end

  @impl true
  def handle_info({:subscribe, opts}, %{check_active_pids: ref, subscribers_tid: tid} = state) do
    Logger.debug("Subscribe #{inspect(opts, pretty: true)}")
    pid = opts.channel_pid
    true = :ets.insert(tid, {pid, opts.id, Process.monitor(pid)})
    Subscriptions.create(state.conn, state.publication, opts)

    new_state =
      if ref == nil do
        %{state | check_active_pids: check_active_pids()}
      else
        state
      end

    {:noreply, new_state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{subscribers_tid: tid} = state) do
    case :ets.take(tid, pid) do
      [{_pid, postgres_id, _ref}] ->
        Subscriptions.delete(state.conn, UUID.string_to_binary!(postgres_id))

      _ ->
        Logger.error("Undefined PID: #{inspect(pid)}")
        nil
    end

    {:noreply, state}
  end

  def handle_info({:unsubscribe, subs_id}, state) do
    Subscriptions.delete(state.conn, subs_id)
    {:noreply, state}
  end

  def handle_info(:check_active_pids, %{check_active_pids: ref, subscribers_tid: tid} = state) do
    cancel_timer(ref)

    delete_zombi = fn {pid, postgres_id, _monitor_ref}, acc ->
      if !Process.alive?(pid) do
        Logger.error("Detected zombi subscriber")
        :ets.delete(tid, pid)
        Subscriptions.delete(state.conn, UUID.string_to_binary!(postgres_id))
      end

      acc + 1
    end

    objects = :ets.foldl(delete_zombi, 0, tid)

    new_ref =
      if objects == 0 do
        Logger.debug("Cancel check_active_pids")
        nil
      else
        check_active_pids()
      end

    {:noreply, %{state | check_active_pids: new_ref}}
  end

  @impl true
  def handle_call(:subscribers_list, _, state) do
    subscribers =
      :ets.foldl(
        fn {pid, _, _}, acc ->
          [pid | acc]
        end,
        [],
        state.subscribers_tid
      )

    {:reply, subscribers, state}
  end

  defp check_active_pids() do
    Process.send_after(
      self(),
      :check_active_pids,
      @check_active_interval
    )
  end
end
