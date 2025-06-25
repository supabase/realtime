defmodule Realtime.Tenants do
  @moduledoc """
  Everything to do with Tenants.
  """

  require Logger

  alias Realtime.Api.Tenant
  alias Realtime.Database
  alias Realtime.Repo
  alias Realtime.Repo.Replica
  alias Realtime.Tenants.Cache
  alias Realtime.Tenants.Connect
  alias Realtime.Tenants.Migrations
  alias Realtime.UsersCounter

  @doc """
  Gets a list of connected tenant `external_id` strings in the cluster or a node.
  """
  @spec list_connected_tenants(atom()) :: [String.t()]
  def list_connected_tenants(node) do
    :syn.group_names(:users, node)
  end

  @doc """
  Gets the database connection pid managed by the Tenants.Connect process.

  ## Examples

      iex> Realtime.Tenants.get_health_conn(%Realtime.Api.Tenant{external_id: "not_found_tenant"})
      {:error, :tenant_database_connection_initializing}
  """

  @spec get_health_conn(Tenant.t()) :: {:error, term()} | {:ok, pid()}
  def get_health_conn(%Tenant{external_id: external_id}) do
    Connect.get_status(external_id)
  end

  @doc """
  Checks if a tenant is healthy. A tenant is healthy if:
  - Tenant has no db connection and zero client connetions
  - Tenant has a db connection and >0 client connections

  A tenant is not healthy if a tenant has client connections and no database connection.
  """

  @spec health_check(binary) ::
          {:error,
           :tenant_not_found
           | String.t()
           | %{
               connected_cluster: pos_integer,
               db_connected: false,
               healthy: false,
               region: String.t(),
               node: String.t()
             }}
          | {:ok,
             %{
               connected_cluster: non_neg_integer,
               db_connected: true,
               healthy: true,
               region: String.t(),
               node: String.t()
             }}
  def health_check(external_id) when is_binary(external_id) do
    region = Application.get_env(:realtime, :region)
    node = Node.self() |> to_string()

    with %Tenant{} = tenant <- Cache.get_tenant_by_external_id(external_id),
         {:error, _} <- get_health_conn(tenant),
         connected_cluster when connected_cluster > 0 <- UsersCounter.tenant_users(external_id) do
      {:error,
       %{
         healthy: false,
         db_connected: false,
         connected_cluster: connected_cluster,
         region: region,
         node: node
       }}
    else
      nil ->
        {:error, :tenant_not_found}

      {:ok, _health_conn} ->
        connected_cluster = UsersCounter.tenant_users(external_id)

        {:ok,
         %{
           healthy: true,
           db_connected: true,
           connected_cluster: connected_cluster,
           region: region,
           node: node
         }}

      connected_cluster when is_integer(connected_cluster) ->
        tenant = Cache.get_tenant_by_external_id(external_id)
        {:ok, db_conn} = Database.connect(tenant, "realtime_health_check")
        Process.alive?(db_conn) && GenServer.stop(db_conn)
        Migrations.run_migrations(tenant)

        {:ok,
         %{
           healthy: true,
           db_connected: false,
           connected_cluster: connected_cluster,
           region: region,
           node: node
         }}
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
      events_per_second_key(tenant),
      db_events_per_second_key(tenant),
      connection_attempts_per_second_key(tenant),
      presence_events_per_second_key(tenant)
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
  ## Examples
    iex> Realtime.Tenants.events_per_second_key("tenant_id")
    {:channel, :events, "tenant_id"}
    iex> Realtime.Tenants.events_per_second_key(%Realtime.Api.Tenant{external_id: "tenant_id"})
    {:channel, :events, "tenant_id"}
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
    iex> Realtime.Tenants.db_events_per_second_key("tenant_id")
    {:channel, :db_events, "tenant_id"}
    iex> Realtime.Tenants.db_events_per_second_key(%Realtime.Api.Tenant{external_id: "tenant_id"})
    {:channel, :db_events, "tenant_id"}
  """
  @spec db_events_per_second_key(Tenant.t() | String.t()) :: {:channel, :db_events, String.t()}
  def db_events_per_second_key(tenant) when is_binary(tenant) do
    {:channel, :db_events, tenant}
  end

  def db_events_per_second_key(%Tenant{} = tenant) do
    {:channel, :db_events, tenant.external_id}
  end

  @doc """
  The GenCounter key to use when counting presence events for RealtimeChannel events.
  ## Examples
    iex> Realtime.Tenants.presence_events_per_second_key("tenant_id")
    {:channel, :presence_events, "tenant_id"}
    iex> Realtime.Tenants.presence_events_per_second_key(%Realtime.Api.Tenant{external_id: "tenant_id"})
    {:channel, :presence_events, "tenant_id"}
  """
  @spec presence_events_per_second_key(Tenant.t() | String.t()) :: {:channel, :presence_events, String.t()}
  def presence_events_per_second_key(tenant) when is_binary(tenant) do
    {:channel, :presence_events, tenant}
  end

  def presence_events_per_second_key(%Tenant{} = tenant) do
    {:channel, :presence_events, tenant.external_id}
  end

  @doc """
  The GenCounter key to use when counting connection attempts against Realtime.Tenants.Connect
  ## Examples
    iex> Realtime.Tenants.connection_attempts_per_second_key("tenant_id")
    {:tenant, :connection_attempts, "tenant_id"}
    iex> Realtime.Tenants.connection_attempts_per_second_key(%Realtime.Api.Tenant{external_id: "tenant_id"})
    {:tenant, :connection_attempts, "tenant_id"}
  """
  @spec connection_attempts_per_second_key(Tenant.t() | String.t()) :: {:tenant, :connection_attempts, String.t()}
  def connection_attempts_per_second_key(tenant) when is_binary(tenant) do
    {:tenant, :connection_attempts, tenant}
  end

  def connection_attempts_per_second_key(%Tenant{} = tenant) do
    {:tenant, :connection_attempts, tenant.external_id}
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
  ## Examples

      iex> Realtime.Tenants.tenant_topic(%Realtime.Api.Tenant{external_id: "tenant_id"}, "sub_topic")
      "tenant_id:sub_topic"
      iex> Realtime.Tenants.tenant_topic("tenant_id", "sub_topic")
      "tenant_id:sub_topic"
      iex> Realtime.Tenants.tenant_topic(%Realtime.Api.Tenant{external_id: "tenant_id"}, "sub_topic", false)
      "tenant_id-private:sub_topic"
      iex> Realtime.Tenants.tenant_topic("tenant_id", "sub_topic", false)
      "tenant_id-private:sub_topic"
      iex> Realtime.Tenants.tenant_topic("tenant_id", ":sub_topic", false)
      "tenant_id-private::sub_topic"
  """
  @spec tenant_topic(Tenant.t() | binary(), String.t(), boolean()) :: String.t()
  def tenant_topic(external_id, sub_topic, public? \\ true)

  def tenant_topic(%Tenant{external_id: external_id}, sub_topic, public?),
    do: tenant_topic(external_id, sub_topic, public?)

  def tenant_topic(external_id, sub_topic, false),
    do: "#{external_id}-private:#{sub_topic}"

  def tenant_topic(external_id, sub_topic, true),
    do: "#{external_id}:#{sub_topic}"

  @doc """
  Sets tenant as suspended. New connections won't be accepted
  """
  @spec suspend_tenant_by_external_id(String.t()) :: {:ok, Tenant.t()} | {:error, term()}
  def suspend_tenant_by_external_id(external_id) do
    external_id
    |> Cache.get_tenant_by_external_id()
    |> Tenant.changeset(%{suspend: true})
    |> Repo.update!()
    |> tap(fn _ -> broadcast_operation_event(:suspend_tenant, external_id) end)
    |> tap(fn _ -> Cache.distributed_invalidate_tenant_cache(external_id) end)
  end

  @doc """
  Sets tenant as unsuspended. New connections will be accepted
  """
  @spec unsuspend_tenant_by_external_id(String.t()) :: {:ok, Tenant.t()} | {:error, term()}
  def unsuspend_tenant_by_external_id(external_id) do
    external_id
    |> Cache.get_tenant_by_external_id()
    |> Tenant.changeset(%{suspend: false})
    |> Repo.update!()
    |> tap(fn _ -> broadcast_operation_event(:unsuspend_tenant, external_id) end)
    |> tap(fn _ -> Cache.distributed_invalidate_tenant_cache(external_id) end)
  end

  @doc """
  Checks if migrations for a given tenant need to run.
  """
  @spec run_migrations?(Tenant.t()) :: boolean()
  def run_migrations?(%Tenant{} = tenant) do
    tenant.migrations_ran < Enum.count(Migrations.migrations())
  end

  @doc """
  Updates the migrations_ran field for a tenant.
  """
  @spec update_migrations_ran(binary(), integer()) :: {:ok, Tenant.t()} | {:error, term()}
  def update_migrations_ran(external_id, count) do
    external_id
    |> Cache.get_tenant_by_external_id()
    |> Tenant.changeset(%{migrations_ran: count})
    |> Repo.update!()
    |> tap(fn _ -> Cache.distributed_invalidate_tenant_cache(external_id) end)
  end

  @doc """
  Broadcasts an operation event to the tenant's operations channel.
  """
  @spec broadcast_operation_event(:suspend_tenant | :unsuspend_tenant | :disconnect, String.t()) :: :ok
  def broadcast_operation_event(action, external_id),
    do: Phoenix.PubSub.broadcast!(Realtime.PubSub, "realtime:operations:" <> external_id, action)
end
