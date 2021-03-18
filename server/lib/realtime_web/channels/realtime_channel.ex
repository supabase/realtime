defmodule RealtimeWeb.RealtimeChannel do
  use Phoenix.Channel, hibernate_after: 1
  require Logger, warn: false

  def join("realtime:" <> _topic, _payload, %{transport_pid: transport_pid} = socket) do
    Realtime.ChannelProcessTracker.track_transport_pid(transport_pid)
    {:ok, %{}, socket}
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
end
