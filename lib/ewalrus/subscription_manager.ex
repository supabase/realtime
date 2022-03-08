defmodule Ewalrus.SubscriptionManager do
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    :global.register_name({:subscription_manager, opts.id}, self())
    # :syn.register(Ewalrus.Managers, opts.id, self())
    {:ok, %{conn: opts.conn, id: opts.id}}
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
    IO.inspect({:msg, opts})
    Ewalrus.Subscriptions.create(state.conn, opts)
    {:noreply, state}
  end

  def handle_info({:unsubscribe, subs_id}, state) do
    Ewalrus.Subscriptions.delete(state.conn, subs_id)
    {:noreply, state}
  end
end
