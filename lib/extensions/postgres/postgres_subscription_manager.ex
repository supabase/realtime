defmodule Extensions.Postgres.SubscriptionManager do
  use GenServer
  require Logger

  alias Extensions.Postgres
  alias Postgres.Subscriptions

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
       publication: opts.publication
     }}
  end

  def subscribe(pid, opts) do
    # TODO: rewrite to call with queue
    send(pid, {:subscribe, opts})
  end

  @spec unsubscribe(atom | pid | port | reference | {atom, atom}, any) :: any
  def unsubscribe(pid, subs_id) do
    # TODO: rewrite to call with queue
    send(pid, {:unsubscribe, subs_id})
  end

  @impl true
  def handle_info({:subscribe, opts}, %{subscribers_tid: tid} = state) do
    Logger.debug("Subscribe #{inspect(opts, pretty: true)}")
    pid = opts.channel_pid
    ref = Process.monitor(pid)
    true = :ets.insert(tid, {pid, opts.id, ref})
    Subscriptions.create(state.conn, state.publication, opts)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{subscribers_tid: tid} = state) do
    case :ets.lookup(tid, pid) do
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
end
