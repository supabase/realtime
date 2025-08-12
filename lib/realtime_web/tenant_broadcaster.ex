defmodule RealtimeWeb.TenantBroadcaster do
  @moduledoc """
  gen_rpc broadcaster
  """

  alias Phoenix.PubSub
  alias Phoenix.Socket.Broadcast

  @spec pubsub_broadcast(tenant_id :: String.t(), PubSub.topic(), PubSub.message(), PubSub.dispatcher()) :: :ok
  def pubsub_broadcast(tenant_id, topic, message, dispatcher) do
    collect_payload_size(tenant_id, message)

    Realtime.GenRpc.multicast(PubSub, :local_broadcast, [Realtime.PubSub, topic, message, dispatcher], key: topic)

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

    Realtime.GenRpc.multicast(
      PubSub,
      :local_broadcast_from,
      [Realtime.PubSub, from, topic, message, dispatcher],
      key: topic
    )

    :ok
  end

  @payload_size_event [:realtime, :tenants, :payload, :size]

  defp collect_payload_size(tenant_id, %Broadcast{payload: payload}) do
    collect_payload_size(tenant_id, payload)
  end

  defp collect_payload_size(tenant_id, payload) when is_map(payload) or is_list(payload) do
    case Jason.encode_to_iodata(payload) do
      {:ok, encoded} ->
        :telemetry.execute(@payload_size_event, %{size: :erlang.iolist_size(encoded)}, %{tenant: tenant_id})

      _ ->
        :ok
    end
  end

  defp collect_payload_size(tenant_id, payload) when is_binary(payload) do
    :telemetry.execute(@payload_size_event, %{size: byte_size(payload)}, %{tenant: tenant_id})
  end

  defp collect_payload_size(_tenant_id, _payload), do: :ok
end
