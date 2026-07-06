defmodule RealtimeWeb.TenantBroadcaster do
  @moduledoc """
  Broadcasts tenant messages across the cluster.

  * `pubsub_broadcast/5` and `pubsub_broadcast_from/6` fan out through
    `Realtime.Broker.Syn` via `:syn` process groups, then dispatch locally
    through Phoenix.PubSub.
  * `pubsub_direct_broadcast/6` keeps the original targeted path using
    `Phoenix.PubSub.direct_broadcast/5`.
  """

  alias Phoenix.PubSub
  alias RealtimeWeb.Socket.UserBroadcast

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

  @spec pubsub_broadcast(tenant_id :: String.t(), PubSub.topic(), PubSub.message(), PubSub.dispatcher(), message_type) ::
          :ok
  def pubsub_broadcast(tenant_id, topic, message, dispatcher, message_type) do
    collect_payload_size(tenant_id, message, message_type)
    message = maybe_pre_encode(message, dispatcher)
    Realtime.Broker.Syn.publish(topic, message, dispatcher: dispatcher)
    :ok
  end

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
    message = maybe_pre_encode(message, dispatcher)
    Realtime.Broker.Syn.publish(topic, message, dispatcher: dispatcher, from: from)
    :ok
  end

  defp maybe_pre_encode(%UserBroadcast{} = broadcast, RealtimeWeb.RealtimeChannel.MessageDispatcher) do
    UserBroadcast.encode_for(broadcast, Phoenix.Socket.V2.JSONSerializer)
  end

  defp maybe_pre_encode(message, _dispatcher), do: message

  @payload_size_event [:realtime, :tenants, :payload, :size]

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
