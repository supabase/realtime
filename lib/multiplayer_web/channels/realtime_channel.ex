defmodule MultiplayerWeb.RealtimeChannel do
  use MultiplayerWeb, :channel
  require Logger
  alias MultiplayerWeb.Presence

  intercept ["presence_diff"]
  @empty_presence_diff %{joins: %{}, leaves: %{}}
  @timeout_presence_diff 1000
  @mbox_limit 100
  @wait_time 500

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
    presence_timer = Process.send_after(self(), :presence_agg, @timeout_presence_diff)
    new_socket =
      update_topic(socket, scope_topic_name)
      |> assign(presence_timer: presence_timer)
      |> assign(mq: [])
      |> assign(presence_diff: @empty_presence_diff)
      |> assign(topic: topic)


    if Application.fetch_env!(:multiplayer, :presence) do
      Multiplayer.PresenceNotify.track_me(self(), new_socket)
    end
    {:ok, new_socket}
  end

  @impl true
  def handle_info(:presence_state, socket) do
    add_message("presence_state", Presence.list(socket) |> :maps.size)
    {:noreply, socket}
  end

  def handle_info({:message, msg, event}, %{assigns: %{mq: mq}} = socket) do
    send(self(), :check_mq)
    {:noreply, socket |> assign(mq: mq ++ [{msg, event}])}
  end

  def handle_info(:check_mq, %{assigns: %{mq: []}} = socket) do
    {:noreply, socket}
  end

  def handle_info(:check_mq, %{transport_pid: pid, assigns: %{mq: [{msg, event} | mq], topic: topic}} = socket) do
    proc_len = case Process.info(pid, :message_queue_len) do
      nil -> nil
      {_, len} -> len
    end
    if proc_len > @mbox_limit or proc_len == nil  do
      Process.send_after(self(), :check_mq, @wait_time)
      {:noreply, socket |> assign(mq: [{msg, event} | mq])}
    else
      update_topic(socket, topic) |> push(event, msg)
      :telemetry.execute([:prom_ex, :plugin, :multiplayer, :msg_sent], %{})
      send(self(), :check_mq)
      {:noreply, socket |> assign(mq: mq)}
    end
  end

  def handle_info(:presence_agg, %{assigns: %{presence_timer: ref, presence_diff: diff}} = socket) do
    Process.cancel_timer(ref)
    info = %{joins: diff.joins |> :maps.size, leaves: diff.leaves |> :maps.size}
    if !Map.equal?(diff, @empty_presence_diff) do
      add_message("presence_diff", info)
    end
    presence_timer = Process.send_after(self(), :presence_agg, @timeout_presence_diff)
    {:noreply, socket
               |> assign(presence_timer: presence_timer)
               |> assign(presence_diff: @empty_presence_diff)}
  end

  def handle_info({:event, %{"type" => type} = event}, %{assigns: %{topic: topic}} = socket) do
    add_message(type, event)
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

  @impl true
  def terminate(reason, _socket) do
    Logger.debug(%{terminate: reason})
    :telemetry.execute([:prom_ex, :plugin, :multiplayer, :disconnected], %{})
    :ok
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

  defp add_message(event, messsage) do
    send(self(), {:message, messsage, event})
  end

end
