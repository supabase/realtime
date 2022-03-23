defmodule MultiplayerWeb.RealtimeChannel do
  use MultiplayerWeb, :channel
  require Logger

  @impl true
  def join(
        "realtime:" <> sub_topic = topic,
        _,
        %{assigns: %{tenant: tenant, claims: claims, limits: limits}, transport_pid: pid} = socket
      ) do
    if Multiplayer.UsersCounter.tenant_users(tenant) < limits.max_concurrent_users do
      Multiplayer.UsersCounter.add(pid, tenant)
      # used for custom monitoring
      channel_stats(pid, tenant, topic)

      tenant_topic_name = tenant <> ":" <> topic
      make_tenant_topic(socket, tenant_topic_name)

      sub_id = UUID.uuid1()
      # TODO: return sub_id from function
      Ewalrus.subscribe(tenant, sub_id, sub_topic, claims, pid)
      Logger.debug("Start channel, #{inspect([sub_id: sub_id], pretty: true)}")

      new_socket =
        update_topic(socket, tenant_topic_name)
        |> assign(mq: [])
        |> assign(topic: topic)
        |> assign(subs_id: sub_id)

      {:ok, new_socket}
    else
      Logger.error("Reached max_concurrent_users limit")
      {:error, %{reason: "reached max_concurrent_users limit"}}
    end
  end

  @impl true
  def handle_info(
        {:event, %{type: type} = event},
        %{assigns: %{topic: topic}} = socket
      ) do
    # Logger.debug("Got event, #{inspect(event, pretty: true)}")
    update_topic(socket, topic) |> push(type, event)
    {:noreply, socket}
  end

  def handle_info(:kickout_time, socket) do
    Logger.error("kickout_time")
    {:stop, :normal, socket}
  end

  def handle_info({:rls, :accepted}, %{assigns: %{kickout_ref: ref}} = socket) do
    Process.cancel_timer(ref)
    {:noreply, socket}
  end

  # TODO: implement
  def handle_info(%{event: "access_token"}, socket) do
    {:noreply, socket}
  end

  def handle_info(other, socket) do
    Logger.error("Undefined msg #{inspect(other, pretty: true)}")
    {:noreply, socket}
  end

  def mess_len(pid) do
    case Process.info(pid, :message_queue_len) do
      nil -> nil
      {_, len} -> len
    end
  end

  @impl true
  def terminate(reason, _state) do
    Logger.debug(%{terminate: reason})
    :telemetry.execute([:prom_ex, :plugin, :multiplayer, :disconnected], %{})
    :ok
  end

  def merge_presence_diff(old, new) do
    {same, updated_old} = Map.split(old.joins, Map.keys(new.leaves))
    clean_leaves = Map.drop(new.leaves, Map.keys(same))

    %{
      joins: Map.merge(updated_old, new.joins),
      leaves: Map.merge(old.leaves, clean_leaves)
    }
  end

  defp make_tenant_topic(_socket, topic) do
    # Allow sending directly to the transport
    # fastlane = {:fastlane, socket.transport_pid, socket.serializer, ["presence_diff"]}
    # MultiplayerWeb.Endpoint.subscribe(topic, metadata: fastlane)
    MultiplayerWeb.Endpoint.subscribe(topic)
  end

  defp update_topic(socket, topic) do
    Map.put(socket, :topic, topic)
  end

  def channel_stats(pid, tenant, topic) do
    Registry.register(
      Multiplayer.Registry,
      "topics",
      {tenant, topic, System.system_time(:second)}
    )

    Registry.register(
      Multiplayer.Registry.Unique,
      "sessions",
      {pid, System.system_time(:second)}
    )
  end
end
