defmodule MultiplayerWeb.RoomChannel do
  use Phoenix.Channel
  alias MultiplayerWeb.Presence

  def join("room:" <> room_id, _params, socket) do
    send(self(), :after_join)
    {:ok, %{channel: "room:#{room_id}"}, assign(socket, :room_id, room_id)}
  end

  def handle_info(:after_join, socket) do
    push(socket, "presence_state", Presence.list(socket))

    {:ok, _} =
      Presence.track(socket, socket.assigns.user_id, %{
        user_id: socket.assigns[:user_id],
        online_at: inspect(System.system_time(:second))
      })

    {:noreply, socket}
  end

  @impl true
  def handle_in("broadcast", payload, socket) do
    broadcast(socket, "broadcast", payload)
    Presence.update(socket, socket.assigns[:user_id], payload)
    {:noreply, socket}
  end
end
