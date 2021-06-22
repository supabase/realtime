defmodule RealtimeWeb.RealtimeChannel do
  use RealtimeWeb, :channel
  require Logger, warn: false

  def join("realtime:" <> _topic, _payload, socket) do
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
    RealtimeWeb.Endpoint.broadcast_from!(self(), topic, txn.type, txn)
  end
end
