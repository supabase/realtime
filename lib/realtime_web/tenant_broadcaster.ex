defmodule RealtimeWeb.TenantBroadcaster do
  @moduledoc """
  Interface to broadcast messages to tenants
  """

  alias Phoenix.Endpoint
  alias Phoenix.PubSub
  alias Realtime.Api.Tenant

  @callback broadcast(Endpoint.topic(), Endpoint.event(), Endpoint.msg()) :: :ok | {:error, term()}
  @callback broadcast_from(from :: pid(), Endpoint.topic(), Endpoint.event(), Endpoint.msg()) :: :ok | {:error, term()}
  @callback pubsub_broadcast(PubSub.topic(), PubSub.message(), PubSub.dispatcher()) ::
              :ok | {:error, term()}
  @callback pubsub_broadcast_from(from :: pid, PubSub.topic(), PubSub.message(), PubSub.dispatcher()) ::
              :ok | {:error, term()}

  @spec broadcast(tenant :: Tenant.t(), Endpoint.topic(), Endpoint.event(), Endpoint.msg()) :: :ok
  def broadcast(tenant, topic, event, msg) do
    adapter(tenant.broadcast_adapter).broadcast(topic, event, msg)
  end

  @spec broadcast_from(tenant :: Tenant.t(), from :: pid, Endpoint.topic(), Endpoint.event(), Endpoint.msg()) :: :ok
  def broadcast_from(tenant, from, topic, event, msg) do
    adapter(tenant.broadcast_adapter).broadcast_from(from, topic, event, msg)
  end

  @spec pubsub_broadcast(tenant :: Tenant.t(), PubSub.topic(), PubSub.message(), PubSub.dispatcher()) ::
          :ok | {:error, term}
  def pubsub_broadcast(tenant, topic, message, dispatcher) do
    adapter(tenant.broadcast_adapter).pubsub_broadcast(topic, message, dispatcher)
  end

  @spec pubsub_broadcast_from(tenant :: Tenant.t(), from :: pid, PubSub.topic(), PubSub.message(), PubSub.dispatcher()) ::
          :ok | {:error, term}
  def pubsub_broadcast_from(tenant, from, topic, message, dispatcher) do
    adapter(tenant.broadcast_adapter).pubsub_broadcast_from(from, topic, message, dispatcher)
  end

  defp adapter(:gen_rpc), do: RealtimeWeb.TenantBroadcaster.GenRpc
  defp adapter(_), do: RealtimeWeb.TenantBroadcaster.Phoenix
end
