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

  # Channels can be used in a request/response fashion
  # by sending replies to requests from the client
  def handle_in("ping", payload, socket) do
    {:reply, {:ok, payload}, socket}
  end

  # It is also common to receive messages from the client and
  # broadcast to everyone in the current topic (realtime:lobby).
  def handle_in("shout", payload, socket) do
    broadcast! socket, "shout", payload
    {:noreply, socket}
  end

  # We want to be able to send a message internally from the GenServer. 
  # With this we can just send it a payload and it will "shout" it on the channel
  def handle_info(payload) do
    # Logger.info'REALTIME! #{inspect(payload)}'
    RealtimeWeb.Endpoint.broadcast_from! self(), "realtime", "shout", payload
  end


end
