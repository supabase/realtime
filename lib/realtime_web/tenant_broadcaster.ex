defmodule RealtimeWeb.TenantBroadcaster do
  @moduledoc """
  Interface to broadcast messages to tenants
  """

  alias Phoenix.Endpoint
  alias Realtime.Api.Tenant

  @callback broadcast(Endpoint.topic(), Endpoint.event(), Endpoint.msg()) :: :ok | {:error, term()}
  @callback broadcast_from(from :: pid(), Endpoint.topic(), Endpoint.event(), Endpoint.msg()) :: :ok | {:error, term()}

  @spec broadcast(tenant :: Tenant.t(), Endpoint.topic(), Endpoint.event(), Endpoint.msg()) :: :ok
  def broadcast(tenant, topic, event, msg) do
    adapter(tenant.broadcast_adapter).broadcast(topic, event, msg)
  end

  @spec broadcast_from(tenant :: Tenant.t(), from :: pid, Endpoint.topic(), Endpoint.event(), Endpoint.msg()) :: :ok
  def broadcast_from(tenant, from, topic, event, msg) do
    adapter(tenant.broadcast_adapter).broadcast_from(from, topic, event, msg)
  end

  defp adapter(:gen_rpc), do: RealtimeWeb.TenantBroadcaster.GenRpc
  defp adapter(_), do: RealtimeWeb.TenantBroadcaster.Phoenix
end
