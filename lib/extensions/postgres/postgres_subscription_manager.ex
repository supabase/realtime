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
    {:ok, %{conn: opts.conn, id: opts.id, publication: opts.publication}}
  end

  def subscribe(pid, opts) do
    # TODO: rewrite to call with queue
    send(pid, {:subscribe, opts})
  end

  def unsubscribe(pid, subs_id) do
    # TODO: rewrite to call with queue
    send(pid, {:unsubscribe, subs_id})
  end

  @impl true
  def handle_info({:subscribe, opts}, state) do
    Logger.debug("Subscribe #{inspect(opts, pretty: true)}")
    Subscriptions.create(state.conn, state.publication, opts)
    {:noreply, state}
  end

  def handle_info({:unsubscribe, subs_id}, state) do
    Subscriptions.delete(state.conn, subs_id)

    if :syn.member_count(Postgres.Subscribers, state.id) == 0 do
      Subscriptions.delete_all(state.conn)
      Postgres.stop(state.id)
    end

    {:noreply, state}
  end
end
