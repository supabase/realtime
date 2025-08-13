defmodule RealtimeWeb.TenantBroadcaster do
  @moduledoc """
  gen_rpc broadcaster
  """

  alias Phoenix.PubSub

  @doc "Wrapper for Phoenix.PubSub.local_broadcast/4 to decompress messages"
  @spec local_broadcast(PubSub.topic(), PubSub.message(), PubSub.dispatcher()) :: :ok
  def local_broadcast(topic, {:compressed, message}, dispatcher) when is_binary(message) do
    # It means that the term was compressed using :erlang.term_to_binary/2
    local_broadcast(topic, :erlang.binary_to_term(message), dispatcher)
  end

  def local_broadcast(topic, message, dispatcher) do
    PubSub.local_broadcast(Realtime.PubSub, topic, message, dispatcher)
  end

  @doc "Wrapper for Phoenix.PubSub.local_broadcast_from/5 to decompress messages"
  @spec local_broadcast_from(pid, PubSub.topic(), PubSub.message(), PubSub.dispatcher()) :: :ok
  def local_broadcast_from(from, topic, {:compressed, message}, dispatcher) when is_binary(message) do
    # It means that the term was compressed using :erlang.term_to_binary/2
    local_broadcast_from(from, topic, :erlang.binary_to_term(message), dispatcher)
  end

  def local_broadcast_from(from, topic, message, dispatcher) do
    PubSub.local_broadcast_from(Realtime.PubSub, from, topic, message, dispatcher)
  end

  @spec pubsub_broadcast(tenant_id :: String.t(), PubSub.topic(), PubSub.message(), PubSub.dispatcher()) :: :ok
  def pubsub_broadcast(tenant_id, topic, message, dispatcher) do
    size = collect_payload_size(tenant_id, message)

    message = maybe_compress(message, size)

    Realtime.GenRpc.multicast(__MODULE__, :local_broadcast, [topic, message, dispatcher], key: topic)

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
    size = collect_payload_size(tenant_id, message)

    message = maybe_compress(message, size)

    Realtime.GenRpc.multicast(
      __MODULE__,
      :local_broadcast_from,
      [from, topic, message, dispatcher],
      key: topic
    )

    :ok
  end

  @payload_size_event [:realtime, :tenants, :payload, :size]

  defp collect_payload_size(tenant_id, payload) when is_struct(payload) do
    # Extracting from struct so the __struct__ bit is not calculated as part of the payload
    collect_payload_size(tenant_id, Map.from_struct(payload))
  end

  defp collect_payload_size(tenant_id, payload) do
    size = :erlang.external_size(payload)
    :telemetry.execute(@payload_size_event, %{size: size}, %{tenant: tenant_id})
    size
  end

  defp maybe_compress(message, size) do
    if size > threshold() do
      {:compressed, :erlang.term_to_iovec(message, [:compressed])}
    else
      message
    end
  end

  defp threshold, do: Application.fetch_env!(:realtime, :pubsub_payload_size_compression_threshold)
end
