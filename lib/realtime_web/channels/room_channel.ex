defmodule RealtimeWeb.RoomChannel do
  use RealtimeWeb, :channel
  alias RealtimeWeb.Presence

  @impl true
  def join("room:" <> _, _params, socket) do
    send(self(), :after_join)
    {:ok, socket}
  end

  @impl true
  def handle_info(:after_join, socket) do
    params = socket.assigns.params
    {:ok, _} = Presence.track(socket, params.user_id, params)

    push(socket, "presence_state", Presence.list(socket))

    {:noreply, socket}
  end

  @impl true
  def handle_in("broadcast" = event, payload, socket) do
    broadcast(socket, event, payload)
    Presence.update(socket, socket.assigns.params.user_id, payload)
    {:noreply, socket}
  end
end
