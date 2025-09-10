defmodule RealtimeWeb.TenantBroadcaster do
  @moduledoc """
  gen_rpc broadcaster
  """

  alias Phoenix.PubSub

  @spec pubsub_broadcast(tenant_id :: String.t(), PubSub.topic(), PubSub.message(), PubSub.dispatcher()) :: :ok
  def pubsub_broadcast(tenant_id, topic, message, dispatcher) do
    collect_payload_size(tenant_id, message)

    PubSub.broadcast(Realtime.PubSub, topic, message, dispatcher)

    :ok
  end

  @spec pubsub_broadcast_from(
          tenant_id :: String.t(),
          from :: pid,
          PubSub.topic(),
          PubSub.message(),
          PubSub.dispatcher()
        ) ::
          :ok
  def pubsub_broadcast_from(tenant_id, from, topic, message, dispatcher) do
    collect_payload_size(tenant_id, message)

    PubSub.broadcast_from(Realtime.PubSub, from, topic, message, dispatcher)
    :ok
  end

  @payload_size_event [:realtime, :tenants, :payload, :size]

  defp collect_payload_size(tenant_id, payload) when is_struct(payload) do
    # Extracting from struct so the __struct__ bit is not calculated as part of the payload
    collect_payload_size(tenant_id, Map.from_struct(payload))
  end

  defp collect_payload_size(tenant_id, payload) do
    :telemetry.execute(@payload_size_event, %{size: :erlang.external_size(payload)}, %{tenant: tenant_id})
  end
end
