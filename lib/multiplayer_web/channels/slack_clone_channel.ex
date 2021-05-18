defmodule MultiplayerWeb.SlackCloneChannel do
  use MultiplayerWeb, :channel
  alias MultiplayerWeb.Presence

  @impl true
  def join("slack_clone:user_presence", _params, socket) do
    send(self(), :after_join)
    {:ok, assign(socket, :user_id, socket.assigns.user_id)}
  end

  @impl true
  def join("slack_clone:typing_indicator:" <> _slack_channel_id, _params, socket) do
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
  def handle_in("typing_indicator" = event, payload, socket) do
    broadcast_from(socket, event, payload)
    {:noreply, socket}
  end
end
