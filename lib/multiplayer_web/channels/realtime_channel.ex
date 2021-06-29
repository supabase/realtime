defmodule MultiplayerWeb.RealtimeChannel do
  use MultiplayerWeb, :channel
  require Logger
  alias MultiplayerWeb.Presence
  alias Phoenix.PubSub

  @impl true
  def join(topic, _, %{assigns: %{scope: scope}} = socket) do
    scope_topic = scope <> ":" <> topic
    fastlane = {:fastlane, socket.transport_pid, socket.serializer, []}
    MultiplayerWeb.Endpoint.subscribe(scope_topic, metadata: fastlane)
    send(self(), :after_join)
    {:ok, %{socket | topic: scope_topic}}
  end

  @impl true
  def handle_info(:after_join, socket) do
    {:ok, _} = Presence.track(
      socket,
      socket.assigns.params.user_id,
      socket.assigns.params
    )
    push(socket, "presence_state", Presence.list(socket))
    {:noreply, socket}
  end

  def handle_info({:event, %{"type" => type} = event}, socket) do
    push(%{socket | topic: "realtime:*"}, type, event)
    {:noreply, socket}
  end

  def handle_info(_, socket) do
    {:noreply, socket}
  end

  defp no_scope(scope, topic) do
    String.slice(topic, String.length("topic")..-1)
  end

end
