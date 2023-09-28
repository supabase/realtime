defmodule Realtime.Tenants do
  @moduledoc """
  Everything to do with Tenants.
  """

  require Logger
  alias Realtime.Repo.Replica
  alias Realtime.Api
  alias Realtime.{Api.Tenant, PostgresCdc, UsersCounter}

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
  Gets the database connection pid of the SubscriptionManager `manager` and the
  Postgrex connection pool `subs_pool`.

  When this function returns `:wait` the  database connection tree is starting and the
  caller should not try to start the database connection tree again.

  ## Examples

      iex> get_manager_conn(Extensions.PostgresCdcRls, "not_started_external_id")
      {:error, nil}
  """

  @spec get_manager_conn(:atom, %Tenant{}) :: {:error, :wait | nil} | {:ok, pid(), pid()}
  def get_manager_conn(module, %Tenant{external_id: external_id}) do
    module.get_manager_conn(external_id)
  end

  @doc """
  Checks if a tenant is healthy. A tenant is healthy if:
  - Tenant has no db connection and zero client connetions
  - Teantn has a db connection and >0 client connections

  A tenant is not healthy if a tenant has client connections and no database connection.

  ## Examples

      iex> health_check("not_healthy_external_id")
      {:error, %{healthy: false, db_connected: false, connected_cluster: 10}}
  """

  @spec health_check(binary) ::
          {:error,
           :tenant_not_found
           | String.t()
           | %{connected_cluster: pos_integer, db_connected: false, healthy: false}}
          | {:ok, %{connected_cluster: non_neg_integer, db_connected: true, healthy: true}}
  def health_check(external_id) when is_binary(external_id) do
    with %Tenant{} = tenant <- Api.get_tenant_by_external_id(external_id),
         {:ok, module} <- PostgresCdc.driver(tenant.postgres_cdc_default),
         {:error, _} <- get_manager_conn(module, tenant),
         connected_cluster when connected_cluster > 0 <- UsersCounter.tenant_users(external_id) do
      {:error, %{healthy: false, db_connected: false, connected_cluster: connected_cluster}}
    else
      nil ->
        {:error, :tenant_not_found}

      {:error, _mod} ->
        {:error, "Bad value for tenant field `postgres_cdc_default`"}

      {:ok, _manager, _subs_pool} ->
        connected_cluster = UsersCounter.tenant_users(external_id)

        {:ok, %{healthy: true, db_connected: true, connected_cluster: connected_cluster}}

      connected_cluster when is_integer(connected_cluster) ->
        {:ok, %{healthy: true, db_connected: false, connected_cluster: connected_cluster}}
    end
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
    repo_replica = Replica.replica()

    Tenant
    |> repo_replica.get_by(external_id: external_id)
    |> repo_replica.preload(:extensions)
  end

  @doc """
  Builds a PubSub topic from a tenant and a sub-topic.
  """
  @spec tenant_topic(Tenant.t(), String.t()) :: String.t()
  def tenant_topic(%Tenant{external_id: external_id}, sub_topic) do
    "#{external_id}:#{sub_topic}"
  end
end
