defmodule RealtimeWeb.TenantBroadcaster do
  @moduledoc """
  Publishes tenant messages on `Realtime.PubSub` and records metrics about them.

  Every function emits the payload size of the message (`[:realtime, :tenants, :payload, :size]`).

  Tenant broadcasts (`:broadcast` messages dispatched by `MessageDispatcher`) are routed to the
  other nodes first, then the dispatch to the subscribers on this node is timed with
  `RealtimeWeb.BroadcastDeliveryMetrics.with_timing/3`. Each node that receives the broadcast times
  its own dispatch. Presence and Postgres Changes are not timed.
  """

  alias Phoenix.PubSub
  alias RealtimeWeb.BroadcastDeliveryMetrics
  alias RealtimeWeb.RealtimeChannel.MessageDispatcher

  @type message_type :: :broadcast | :presence | :postgres_changes

  @spec pubsub_direct_broadcast(
          node :: node(),
          tenant_id :: String.t(),
          PubSub.topic(),
          PubSub.message(),
          PubSub.dispatcher(),
          message_type
        ) ::
          :ok
  def pubsub_direct_broadcast(node, tenant_id, topic, message, dispatcher, message_type) do
    collect_payload_size(tenant_id, message, message_type)

    do_direct_broadcast(node, topic, message, dispatcher)

    :ok
  end

  # Remote
  defp do_direct_broadcast(node, topic, message, dispatcher) when node != node() do
    PubSub.direct_broadcast(node, Realtime.PubSub, topic, message, dispatcher)
  end

  # Local
  defp do_direct_broadcast(_node, topic, message, dispatcher) do
    PubSub.local_broadcast(Realtime.PubSub, topic, message, dispatcher)
  end

  @doc """
  Sends a message to the subscribers of `topic` on every node, including the caller if it is
  subscribed. Broadcasts dispatched by `MessageDispatcher` are tagged with the tenant so the
  receiving nodes can route and measure them.
  """
  @spec pubsub_broadcast(tenant_id :: String.t(), PubSub.topic(), PubSub.message(), PubSub.dispatcher(), message_type) ::
          :ok
  def pubsub_broadcast(tenant_id, topic, message, dispatcher, message_type) do
    collect_payload_size(tenant_id, message, message_type)
    broadcast(nil, topic, tag_tenant(tenant_id, message, dispatcher, message_type), dispatcher)
    :ok
  end

  @doc "Same as `pubsub_broadcast/5`, but the message is not delivered to `from`."
  @spec pubsub_broadcast_from(
          tenant_id :: String.t(),
          from :: pid,
          PubSub.topic(),
          PubSub.message(),
          PubSub.dispatcher(),
          message_type
        ) ::
          :ok
  def pubsub_broadcast_from(tenant_id, from, topic, message, dispatcher, message_type) do
    collect_payload_size(tenant_id, message, message_type)
    broadcast(from, topic, tag_tenant(tenant_id, message, dispatcher, message_type), dispatcher)
    :ok
  end

  # Tenant broadcasts run the two steps of Phoenix.PubSub.broadcast/4 and broadcast_from/5
  # (phoenix_pubsub 2.1.3): route to the other nodes, then dispatch locally, so only the local
  # dispatch is timed. Re-check this against Phoenix.PubSub when bumping phoenix_pubsub.
  defp broadcast(from, topic, {:tb, tenant_id, _} = message, dispatcher) do
    {:ok, {adapter, name}} = Registry.meta(Realtime.PubSub, :pubsub)

    with :ok <- adapter.broadcast(name, topic, message, dispatcher) do
      BroadcastDeliveryMetrics.with_timing(tenant_id, :local, fn ->
        local_broadcast(from, topic, message, dispatcher)
      end)
    end
  end

  defp broadcast(nil, topic, message, dispatcher), do: PubSub.broadcast(Realtime.PubSub, topic, message, dispatcher)

  defp broadcast(from, topic, message, dispatcher),
    do: PubSub.broadcast_from(Realtime.PubSub, from, topic, message, dispatcher)

  defp local_broadcast(nil, topic, message, dispatcher),
    do: PubSub.local_broadcast(Realtime.PubSub, topic, message, dispatcher)

  defp local_broadcast(from, topic, message, dispatcher),
    do: PubSub.local_broadcast_from(Realtime.PubSub, from, topic, message, dispatcher)

  # Tag broadcast messages with their tenant_id so the receiving node can attribute the fan-out
  # (see the telemetry in Realtime.GenRpcPubSub.Worker). Only tag when MessageDispatcher is the
  # dispatcher, since it is the component that unwraps the tag before delivery
  # Presence/postgres_changes stay untagged.
  defp tag_tenant(tenant_id, message, MessageDispatcher, :broadcast), do: {:tb, tenant_id, message}
  defp tag_tenant(_tenant_id, message, _dispatcher, _message_type), do: message

  @payload_size_event [:realtime, :tenants, :payload, :size]

  @doc """
  Emits the size of `payload` in the external term format, tagged with the tenant and message
  type. Structs are measured as plain maps.
  """
  @spec collect_payload_size(tenant_id :: String.t(), payload :: term, message_type :: message_type) :: :ok
  def collect_payload_size(tenant_id, payload, message_type) when is_struct(payload) do
    # Extracting from struct so the __struct__ bit is not calculated as part of the payload
    collect_payload_size(tenant_id, Map.from_struct(payload), message_type)
  end

  def collect_payload_size(tenant_id, payload, message_type) do
    :telemetry.execute(@payload_size_event, %{size: :erlang.external_size(payload)}, %{
      tenant: tenant_id,
      message_type: message_type
    })
  end
end
