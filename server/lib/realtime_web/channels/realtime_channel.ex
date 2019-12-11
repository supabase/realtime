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


  # It is also common to receive messages from the client and
  # broadcast to everyone in the current topic (realtime:lobby).
  def handle_in("*", payload, socket) do
    broadcast!(socket, "*", payload)
    {:noreply, socket}
  end

  @doc """
  Handles a full, decoded transation.
  """
  def handle_realtime_transaction(topic, txn) do
    # Logger.info 'REALTIME!'
    # Logger.info inspect(txn, pretty: true)
    RealtimeWeb.Endpoint.broadcast_from!(self(), topic, "*", txn)
  end
end
