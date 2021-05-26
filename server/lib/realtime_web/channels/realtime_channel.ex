defmodule RealtimeWeb.RealtimeChannel do
  use RealtimeWeb, :channel
  require Logger, warn: false

  @wait_time  Application.get_env(:realtime, :ws_wait_time)
  @mbox_limit Application.get_env(:realtime, :ws_mbox_limit)

  def join("realtime:" <> _topic, _payload, socket) do
    {:ok, %{}, socket}
  end

  @impl true
  def handle_call({:txn, txn}, _, %{transport_pid: pid} = socket) do
    {_, len} = Process.info(pid, :message_queue_len)
    if len > @mbox_limit do
      Process.sleep(@wait_time)
    end
    # TODO: should to remove https://github.com/supabase/realtime-js/pull/75
    push(socket, "*", txn)
    push(socket, txn.type, txn)
    {:reply, :ok, socket}
  end

  # @doc """
  # Disabling inward messages from the websocket.
  # """
  # def handle_in(event_type, payload, socket) do
  #   Logger.info event_type
  #   broadcast!(socket, event_type, payload)
  #   {:noreply, socket}
  # end

  @doc """
  Handles a full, decoded transation.
  """
  def handle_realtime_transaction(topic, txn) do
    RealtimeWeb.Endpoint.broadcast_from!(self(), topic, "*", txn)
    RealtimeWeb.Endpoint.broadcast_from!(self(), topic, txn.type, txn)
  end

  def handle_realtime_transaction_sync(topic, txn) do
    Registry.dispatch(
      Realtime.PubSub,
      topic,
      {__MODULE__, :dispatch_sync, [txn]}
    )
  end

  def dispatch_sync(entries, txn) do
    for {pid, _} <- entries do
      GenServer.call(pid, {:txn, txn})
    end
  end

end
