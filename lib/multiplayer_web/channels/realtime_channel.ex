defmodule MultiplayerWeb.RealtimeChannel do
  use MultiplayerWeb, :channel
  require Logger
  alias MultiplayerWeb.Presence

  intercept ["presence_diff"]
  @empty_presence_diff %{joins: %{}, leaves: %{}}
  @timeout_presence_diff 1000

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
    timer_ref = Process.send_after(self(), :check_diff, @timeout_presence_diff)
    {:ok, update_topic(socket, scope_topic_name)
            |> assign(timer_ref: timer_ref)
            |> assign(presence_diff: @empty_presence_diff)
            |> assign(topic: topic)}
  end

  @impl true
  def handle_info(:after_join, socket) do
    Multiplayer.PresenceNotify.track_me(self(), socket)
    {:noreply, socket}
  end

  def handle_info(:presence_state, socket) do
    push(socket, "presence_state", Presence.list(socket))
    {:noreply, socket}
  end

  def handle_info(:check_diff, %{assigns: %{timer_ref: ref, presence_diff: diff}} = socket) do
    Process.cancel_timer(ref)
    if !Map.equal?(diff, @empty_presence_diff) do
      push(socket, "presence_diff", diff)
    end
    timer_ref = Process.send_after(self(), :check_diff, @timeout_presence_diff)
    {:noreply, socket
               |> assign(timer_ref: timer_ref)
               |> assign(presence_diff: @empty_presence_diff)}
  end

  def handle_info({:event, %{"type" => type} = event}, %{assigns: %{topic: topic}} = socket) do
    update_topic(socket, topic) |> push(type, event)
    {:noreply, socket}
  end

  def handle_info(_, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_out("presence_diff", msg, %{assigns: %{presence_diff: diff}} = socket) do
    new_diff = merge_presence_diff(diff, msg)
    {:noreply, assign(socket, presence_diff: new_diff)}
  end

  def handle_out(_, _, socket) do
    {:noreply, socket}
  end

  def merge_presence_diff(old, new) do
    {same, updated_old} = Map.split(old.joins, Map.keys(new.leaves))
    clean_leaves = Map.drop(new.leaves, Map.keys(same))
    %{
      joins: Map.merge(updated_old, new.joins),
      leaves: Map.merge(old.leaves, clean_leaves)
    }
  end

  defp make_scope_topic(socket, topic) do
    # Allow sending directly to the transport
    # fastlane = {:fastlane, socket.transport_pid, socket.serializer, ["presence_diff"]}
    # MultiplayerWeb.Endpoint.subscribe(topic, metadata: fastlane)
    MultiplayerWeb.Endpoint.subscribe(topic)
  end

  defp update_topic(socket, topic) do
    Map.put(socket, :topic, topic)
  end

end
