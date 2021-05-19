defmodule MultiplayerWeb.RoomChannel do
  use MultiplayerWeb, :channel
  alias MultiplayerWeb.Presence

  @impl true
  def join("room:" <> _, _params, socket) do
    send(self(), :after_join)
    {:ok, socket}
  end

  @impl true
  def handle_info(:after_join, socket) do
    {:ok, _} = Presence.track(socket, socket.assigns.user_id, %{
      user_id: socket.assigns.user_id
    })

    push(socket, "presence_state", Presence.list(socket))

    {:noreply, socket}
  end

  @impl true
  def handle_in("broadcast" = event, payload, socket) do
    broadcast(socket, event, payload)
    Presence.update(socket, socket.assigns.user_id, payload)
    {:noreply, socket}
  end
end
