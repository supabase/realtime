defmodule RealtimeWeb.RealtimeChannel do
  use RealtimeWeb, :channel
  require Logger

  alias RealtimeWeb.{Endpoint, Presence}
  alias Phoenix.Socket.Broadcast

  @impl true
  def join(
        "realtime:" <> sub_topic = topic,
        _,
        %{assigns: %{tenant: tenant, claims: claims, limits: limits}, transport_pid: pid} = socket
      ) do
    if Realtime.UsersCounter.tenant_users(tenant) < limits.max_concurrent_users do
      Realtime.UsersCounter.add(pid, tenant)
      # used for custom monitoring
      channel_stats(pid, tenant, topic)

      tenant_topic = tenant <> ":" <> sub_topic
      :ok = tenant_topic(socket, tenant_topic)

      id = UUID.uuid1()
      Extensions.Postgres.subscribe(tenant, id, sub_topic, claims, pid)
      Logger.debug("Start channel, #{inspect([id: id], pretty: true)}")

      send(self(), :after_join)
      {:ok, assign(socket, %{id: id, tenant_topic: tenant_topic})}
    else
      Logger.error("Reached max_concurrent_users limit")
      {:error, %{reason: "reached max_concurrent_users limit"}}
    end
  end

  @impl true
  def handle_info(:after_join, %{assigns: %{tenant_topic: topic}} = socket) do
    push(socket, "presence_state", Presence.list(topic))
    {:noreply, socket}
  end

  def handle_info(%Broadcast{event: type, payload: payload}, socket) do
    push(socket, type, payload)
    {:noreply, socket}
  end

  def handle_info(other, socket) do
    Logger.error("Undefined msg #{inspect(other, pretty: true)}")
    {:noreply, socket}
  end

  @impl true
  # TODO: implement
  def handle_in("access_token", _, socket) do
    {:noreply, socket}
  end

  def handle_in("broadcast" = type, payload, %{assigns: %{tenant_topic: topic}} = socket) do
    Endpoint.broadcast_from(self(), topic, type, payload)
    {:noreply, socket}
  end

  def handle_in(
        "presence",
        %{"event" => "TRACK", "payload" => payload} = msg,
        %{assigns: %{id: id, tenant_topic: topic}} = socket
      ) do
    case Presence.track(self(), topic, Map.get(msg, "key", id), payload) do
      {:ok, _} ->
        :ok

      {:error, {:already_tracked, _, _, _}} ->
        Presence.update(self(), topic, Map.get(msg, "key", id), payload)
    end

    {:reply, :ok, socket}
  end

  def handle_in(
        "presence",
        %{"event" => "UNTRACK"} = msg,
        %{assigns: %{id: id, tenant_topic: topic}} = socket
      ) do
    Presence.untrack(self(), topic, Map.get(msg, "key", id))

    {:reply, :ok, socket}
  end

  @impl true
  def terminate(reason, _state) do
    Logger.debug(%{terminate: reason})
    :telemetry.execute([:prom_ex, :plugin, :realtime, :disconnected], %{})
    :ok
  end

  defp tenant_topic(_socket, topic) do
    # Allow sending directly to the transport
    # fastlane = {:fastlane, socket.transport_pid, socket.serializer, ["presence_diff"]}
    # RealtimeWeb.Endpoint.subscribe(topic, metadata: fastlane)
    RealtimeWeb.Endpoint.subscribe(topic)
  end

  def channel_stats(pid, tenant, topic) do
    Registry.register(
      Realtime.Registry,
      "topics",
      {tenant, topic, System.system_time(:second)}
    )

    Registry.register(
      Realtime.Registry.Unique,
      "sessions",
      {pid, System.system_time(:second)}
    )
  end
end
