defmodule MultiplayerWeb.RealtimeChannel do
  use MultiplayerWeb, :channel
  require Logger
  alias MultiplayerWeb.Presence

  @impl true
  def join(topic, _, %{assigns: %{scope: scope}} = socket) do
    # used for monitoring
    Registry.register(
      Multiplayer.Registry,
      "channels",
      {scope, topic, System.system_time(:second)}
    )
    scope_topic_name = scope <> ":" <> topic
    make_scope_topic(socket, scope_topic_name)
    send(self(), :after_join)
    {:ok, update_topic(socket, scope_topic_name)
            |> assign(topic: topic)}
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

  def handle_info({:event, %{"type" => type} = event}, %{assigns: %{topic: topic}} = socket) do
    update_topic(socket, topic) |> push(type, event)
    {:noreply, socket}
  end

  def handle_info(_, socket) do
    {:noreply, socket}
  end

  defp make_scope_topic(socket, topic) do
    fastlane = {:fastlane, socket.transport_pid, socket.serializer, []}
    MultiplayerWeb.Endpoint.subscribe(topic, metadata: fastlane)
  end

  defp update_topic(socket, topic) do
    Map.put(socket, :topic, topic)
  end

end
