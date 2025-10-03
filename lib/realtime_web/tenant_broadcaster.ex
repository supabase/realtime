defmodule RealtimeWeb.TenantBroadcaster do
  @moduledoc """
  gen_rpc broadcaster
  """

  alias Phoenix.PubSub

  @type message_type :: :broadcast | :presence | :postgres_changes

  @spec pubsub_broadcast(tenant_id :: String.t(), PubSub.topic(), PubSub.message(), PubSub.dispatcher(), message_type) ::
          :ok
  def pubsub_broadcast(tenant_id, topic, message, dispatcher, message_type) do
    collect_payload_size(tenant_id, message, message_type)

    if pubsub_adapter() == :gen_rpc do
      PubSub.broadcast(Realtime.PubSub, topic, message, dispatcher)
    else
      Realtime.GenRpc.multicast(PubSub, :local_broadcast, [Realtime.PubSub, topic, message, dispatcher], key: topic)
    end

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

    if pubsub_adapter() == :gen_rpc do
      PubSub.broadcast_from(Realtime.PubSub, from, topic, message, dispatcher)
    else
      Realtime.GenRpc.multicast(
        PubSub,
        :local_broadcast_from,
        [Realtime.PubSub, from, topic, message, dispatcher],
        key: topic
      )
    end

    :ok
  end

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

  defp pubsub_adapter, do: Application.fetch_env!(:realtime, :pubsub_adapter)
end
