defmodule Realtime.Tenants do
  @moduledoc """
  Everything to do with Tenants.
  """

  require Logger
  alias Realtime.Tenants.Migrations
  alias Realtime.Api.Tenant
  alias Realtime.Tenants.Connect
  alias Realtime.Repo
  alias Realtime.Repo.Replica
  alias Realtime.Tenants.Cache
  alias Realtime.UsersCounter
  alias Realtime.Database

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
  Gets the database connection pid managed by the Tenants.Connect process.

  ## Examples

      iex> Realtime.Tenants.get_health_conn(%Realtime.Api.Tenant{external_id: "not_found_tenant"})
      {:error, :tenant_database_unavailable}
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
           | %{connected_cluster: pos_integer, db_connected: false, healthy: false}}
          | {:ok, %{connected_cluster: non_neg_integer, db_connected: true, healthy: true}}
  def health_check(external_id) when is_binary(external_id) do
    with %Tenant{} = tenant <- Cache.get_tenant_by_external_id(external_id),
         {:error, _} <- get_health_conn(tenant),
         connected_cluster when connected_cluster > 0 <- UsersCounter.tenant_users(external_id) do
      {:error, %{healthy: false, db_connected: false, connected_cluster: connected_cluster}}
    else
      nil ->
        {:error, :tenant_not_found}

      {:ok, health_conn} ->
        connected_cluster = UsersCounter.tenant_users(external_id)
        %{extensions: [%{settings: settings} | _]} = Cache.get_tenant_by_external_id(external_id)

        query =
          "select * from pg_catalog.pg_tables where schemaname = 'realtime' and tablename = 'schema_migrations';"

        Database.transaction(health_conn, fn transaction_conn ->
          res = Postgrex.query!(transaction_conn, query, [])

          if res.rows == [] do
            Migrations.run_migrations(settings)
          end
        end)

        {:ok, %{healthy: true, db_connected: true, connected_cluster: connected_cluster}}

      connected_cluster when is_integer(connected_cluster) ->
        {:ok, db_conn} = Connect.lookup_or_start_connection(external_id)
        %{extensions: [%{settings: settings} | _]} = Cache.get_tenant_by_external_id(external_id)

        Database.transaction(db_conn, fn transaction_conn ->
          query =
            "select * from pg_catalog.pg_tables where schemaname = 'realtime' and tablename = 'schema_migrations';"

          res = Postgrex.query!(transaction_conn, query, [])

          if res.rows == [] do
            Migrations.run_migrations(settings)
          end
        end)

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
  ## Examples

      iex> Realtime.Tenants.tenant_topic(%Realtime.Api.Tenant{external_id: "tenant_id"}, "sub_topic")
      "tenant_id:sub_topic"
      iex> Realtime.Tenants.tenant_topic("tenant_id", "sub_topic")
      "tenant_id:sub_topic"
      iex> Realtime.Tenants.tenant_topic(%Realtime.Api.Tenant{external_id: "tenant_id"}, "sub_topic", false)
      "tenant_id:private:sub_topic"
      iex> Realtime.Tenants.tenant_topic("tenant_id", "sub_topic", false)
      "tenant_id:private:sub_topic"
  """
  @spec tenant_topic(Tenant.t() | binary(), String.t(), boolean()) :: String.t()
  def tenant_topic(external_id, sub_topic, public? \\ true)

  def tenant_topic(%Tenant{external_id: external_id}, sub_topic, public?) do
    tenant_topic(external_id, sub_topic, public?)
  end

  def tenant_topic(external_id, sub_topic, false), do: "#{external_id}:private:#{sub_topic}"

  def tenant_topic(external_id, sub_topic, true), do: "#{external_id}:#{sub_topic}"

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
  end

  defp broadcast_operation_event(action, external_id) do
    Phoenix.PubSub.broadcast!(
      Realtime.PubSub,
      "realtime:operations:invalidate_cache",
      {action, external_id}
    )
  end
end
