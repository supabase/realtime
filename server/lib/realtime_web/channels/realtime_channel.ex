defmodule RealtimeWeb.RealtimeChannel do
  use RealtimeWeb, :channel
  require Logger, warn: false

  # Add authorization logic here as required.
  defp authorized?(_payload) do
    true
  end

  def join("realtime:" <> topic, payload, socket) do
    if authorized?(payload) do
      {:ok, %{}, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @doc """
  Disabling inward messages from the websocket.
  """
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
