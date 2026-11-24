defmodule RealtimeWeb.TenantBroadcaster do
  @moduledoc """
  gen_rpc broadcaster
  """

  alias Phoenix.PubSub

  @type message_type :: :broadcast | :presence | :postgres_changes

  # Every broadcast uses the default `Phoenix.PubSub` dispatcher. Delivery to channels is chosen per
  # subscription with the `:sender` option, see `RealtimeWeb.RealtimeChannel.FastlaneSender` and
  # `Extensions.PostgresCdcRls.FastlaneSender`.

  @spec pubsub_direct_broadcast(
          node :: node(),
          tenant_id :: String.t(),
          PubSub.topic(),
          PubSub.message(),
          message_type
        ) ::
          :ok
  def pubsub_direct_broadcast(node, tenant_id, topic, message, message_type) do
    collect_payload_size(tenant_id, message, message_type)

    do_direct_broadcast(node, topic, message)

    :ok
  end

  # Remote
  defp do_direct_broadcast(node, topic, message) when node != node() do
    PubSub.direct_broadcast(node, Realtime.PubSub, topic, message)
  end

  # Local
  defp do_direct_broadcast(_node, topic, message) do
    PubSub.local_broadcast(Realtime.PubSub, topic, message)
  end

  @spec pubsub_broadcast(tenant_id :: String.t(), PubSub.topic(), PubSub.message(), message_type) :: :ok
  def pubsub_broadcast(tenant_id, topic, message, message_type) do
    collect_payload_size(tenant_id, message, message_type)
    PubSub.broadcast(Realtime.PubSub, topic, tag_tenant(tenant_id, message, message_type))
    :ok
  end

  @spec pubsub_broadcast_from(
          tenant_id :: String.t(),
          from :: pid,
          PubSub.topic(),
          PubSub.message(),
          message_type
        ) ::
          :ok
  def pubsub_broadcast_from(tenant_id, from, topic, message, message_type) do
    collect_payload_size(tenant_id, message, message_type)

    PubSub.broadcast_from(Realtime.PubSub, from, topic, tag_tenant(tenant_id, message, message_type))

    :ok
  end

  # Tag broadcast messages with their tenant_id so the receiving node can attribute the fan-out
  # (see the telemetry in Realtime.GenRpcPubSub.Worker). RealtimeChannel.FastlaneSender unwraps
  # the tag before delivery. A subscriber without that sender receives the tagged tuple.
  # Presence/postgres_changes stay untagged.
  defp tag_tenant(tenant_id, message, :broadcast), do: {:tb, tenant_id, message}
  defp tag_tenant(_tenant_id, message, _message_type), do: message

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
