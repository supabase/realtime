defmodule Realtime.Tenants do
  @moduledoc """
  Everything to do with Tenants.
  """

  require Logger

  alias Realtime.Repo
  alias Realtime.Api.Tenant

  @doc """
  Gets a list of connected tenant `external_id` strings in the cluster or a node.
  """

  @spec list_connected_tenants :: [String.t()]
  def list_connected_tenants() do
    :syn.group_names(:users)
  end

  @spec list_connected_tenants(atom()) :: [String.t()]
  def list_connected_tenants(node) do
    :syn.group_names(:users, node)
  end

  @doc """
  All the keys that we use to create counters and RateLimiters for tenants.
  """

  @spec limiter_keys(Tenant.t()) :: [{atom(), atom(), String.t()}]
  def limiter_keys(%Tenant{} = tenant) do
    [
      requests_per_second_key(tenant),
      channels_per_client_key(tenant),
      joins_per_second_key(tenant),
      events_per_second_key(tenant)
    ]
  end

  @doc """
  The GenCounter key to use for counting requests through Plug.
  """

  @spec requests_per_second_key(Tenant.t() | String.t()) :: {:plug, :requests, String.t()}
  def requests_per_second_key(%Tenant{} = tenant) do
    {:plug, :requests, tenant.external_id}
  end

  @doc """
  The GenCounter key to use for counting RealtimeChannel joins.
  """

  @spec joins_per_second_key(Tenant.t() | String.t()) :: {:channel, :joins, String.t()}
  def joins_per_second_key(tenant) when is_binary(tenant) do
    {:channel, :joins, tenant}
  end

  def joins_per_second_key(%Tenant{} = tenant) do
    {:channel, :joins, tenant.external_id}
  end

  @doc """
  The GenCounter key to use to limit the amount of clients connected to the same same channel.
  """

  @spec channels_per_client_key(Tenant.t() | String.t()) :: {:channel, :clients_per, String.t()}
  def channels_per_client_key(tenant) when is_binary(tenant) do
    {:channel, :clients_per, tenant}
  end

  def channels_per_client_key(%Tenant{} = tenant) do
    {:channel, :clients_per, tenant.external_id}
  end

  @doc """
  The GenCounter key to use when counting events for RealtimeChannel events.
  """

  @spec events_per_second_key(Tenant.t() | String.t()) :: {:channel, :events, String.t()}
  def events_per_second_key(tenant) when is_binary(tenant) do
    {:channel, :events, tenant}
  end

  def events_per_second_key(%Tenant{} = tenant) do
    {:channel, :events, tenant.external_id}
  end

  @doc """
  The GenCounter key to use when counting events for RealtimeChannel events.
  """

  @spec db_events_per_second_key(Tenant.t() | String.t()) :: {:channel, :db_events, String.t()}
  def db_events_per_second_key(tenant) when is_binary(tenant) do
    {:channel, :db_events, tenant}
  end

  def db_events_per_second_key(%Tenant{} = tenant) do
    {:channel, :db_events, tenant.external_id}
  end

  @spec get_tenant_limits(Realtime.Api.Tenant.t(), maybe_improper_list) :: list
  def get_tenant_limits(%Tenant{} = tenant, keys) when is_list(keys) do
    nodes = [Node.self() | Node.list()]

    nodes
    |> Enum.map(fn node ->
      Task.Supervisor.async({Realtime.TaskSupervisor, node}, fn ->
        for key <- keys do
          {_status, response} = Realtime.GenCounter.get(key)

          %{
            external_id: tenant.external_id,
            node: node,
            limiter: key,
            counter: response
          }
        end
      end)
    end)
    |> Task.await_many()
    |> List.flatten()
  end

  @spec get_tenant_by_external_id(String.t()) :: Tenant.t() | nil
  def get_tenant_by_external_id(external_id) do
    repo_replica = Repo.replica()

    Tenant
    |> repo_replica.get_by(external_id: external_id)
    |> repo_replica.preload(:extensions)
  end
end
