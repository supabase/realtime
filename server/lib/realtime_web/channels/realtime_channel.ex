defmodule RealtimeWeb.RealtimeChannel do
  use RealtimeWeb, :channel
  require Logger, warn: false

  # Add authorization logic here as required.
  defp authorized?(_payload) do
    true
  end

  def join("realtime", payload, socket) do
    if authorized?(payload) do
      { :ok, %{}, socket }
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  # It is also common to receive messages from the client and
  # broadcast to everyone in the current topic (realtime:lobby).
  def handle_in("*", payload, socket) do
    broadcast! socket, "*", payload
    {:noreply, socket}
  end

  # We want to be able to send a message internally from the GenServer. 
  # With this we can just send it a payload and it will "shout" it on the channel
  def handle_info(payload) do
    # Logger.info'REALTIME! #{inspect(payload)}'

    # Optimally we would want subscriptions to be specific to the row || table name
    # RealtimeWeb.Endpoint.broadcast_from! self(), "realtime", payload.event, payload

    RealtimeWeb.Endpoint.broadcast_from! self(), "realtime", "*", payload
  end


end
