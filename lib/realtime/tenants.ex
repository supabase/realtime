defmodule Realtime.Tenants do
  @moduledoc """
  Everything to do with Tenants.
  """

  require Logger

  alias Realtime.Api
  alias Realtime.Api.Tenant
  alias Realtime.Database
  alias Realtime.RateCounter
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
    UsersCounter.scopes()
    |> Enum.flat_map(fn scope -> :syn.group_names(scope, node) end)
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
      presence_events_per_second_key(tenant)
    ]
  end

  @spec requests_per_second_rate(Tenant.t()) :: RateCounter.Args.t()
  def requests_per_second_rate(%Tenant{} = tenant) do
    %RateCounter.Args{id: requests_per_second_key(tenant), opts: []}
  end

  @doc "The GenCounter key to use for counting requests through Plug."
  @spec requests_per_second_key(Tenant.t() | String.t()) :: {:plug, :requests, String.t()}
  def requests_per_second_key(%Tenant{} = tenant) do
    {:plug, :requests, tenant.external_id}
  end

  @doc "RateCounter arguments for counting joins per second."
  @spec joins_per_second_rate(Tenant.t()) :: RateCounter.Args.t()
  def joins_per_second_rate(%Tenant{} = tenant),
    do: joins_per_second_rate(tenant.external_id, tenant.max_joins_per_second)

  @spec joins_per_second_rate(String.t(), non_neg_integer) :: RateCounter.Args.t()
  def joins_per_second_rate(tenant_id, max_joins_per_second) when is_binary(tenant_id) do
    opts = [
      telemetry: %{
        event_name: [:channel, :joins],
        measurements: %{limit: max_joins_per_second},
        metadata: %{tenant: tenant_id}
      },
      limit: [
        value: max_joins_per_second,
        measurement: :avg,
        log_fn: fn ->
          Logger.critical("ClientJoinRateLimitReached: Too many joins per second",
            external_id: tenant_id,
            project: tenant_id
          )
        end
      ]
    ]

    %RateCounter.Args{id: joins_per_second_key(tenant_id), opts: opts}
  end

  @doc "The GenCounter key to use for counting RealtimeChannel joins."
  @spec joins_per_second_key(Tenant.t() | String.t()) :: {:channel, :joins, String.t()}
  def joins_per_second_key(tenant) when is_binary(tenant) do
    {:channel, :joins, tenant}
  end

  def joins_per_second_key(%Tenant{} = tenant) do
    {:channel, :joins, tenant.external_id}
  end

  @doc "The Register key to use to limit the amount of channels connected to the websocket."
  @spec channels_per_client_key(Tenant.t() | String.t()) :: {:channel, :clients_per, String.t()}
  def channels_per_client_key(tenant) when is_binary(tenant) do
    {:channel, :clients_per, tenant}
  end

  def channels_per_client_key(%Tenant{} = tenant) do
    {:channel, :clients_per, tenant.external_id}
  end

  @doc "RateCounter arguments for counting events per second."
  @spec events_per_second_rate(Tenant.t()) :: RateCounter.Args.t()
  def events_per_second_rate(tenant), do: events_per_second_rate(tenant.external_id, tenant.max_events_per_second)

  def events_per_second_rate(tenant_id, max_events_per_second) do
    opts = [
      telemetry: %{
        event_name: [:channel, :events],
        measurements: %{limit: max_events_per_second},
        metadata: %{tenant: tenant_id}
      },
      limit: [
        value: max_events_per_second,
        measurement: :avg,
        log: true,
        log_fn: fn ->
          Logger.error("MessagePerSecondRateLimitReached: Too many messages per second",
            external_id: tenant_id,
            project: tenant_id
          )
        end
      ]
    ]

    %RateCounter.Args{id: events_per_second_key(tenant_id), opts: opts}
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

  @doc "RateCounter arguments for counting database events per second."
  @spec db_events_per_second_rate(Tenant.t() | String.t()) :: RateCounter.Args.t()
  def db_events_per_second_rate(%Tenant{} = tenant), do: db_events_per_second_rate(tenant.external_id)

  def db_events_per_second_rate(tenant_id) when is_binary(tenant_id) do
    opts = [
      telemetry: %{
        event_name: [:channel, :db_events],
        measurements: %{},
        metadata: %{tenant: tenant_id}
      }
    ]

    %RateCounter.Args{id: db_events_per_second_key(tenant_id), opts: opts}
  end

  @doc "RateCounter arguments for counting database events per second with a limit."
  @spec db_events_per_second_rate(String.t(), non_neg_integer) :: RateCounter.Args.t()
  def db_events_per_second_rate(tenant_id, max_events_per_second) when is_binary(tenant_id) do
    opts = [
      telemetry: %{
        event_name: [:channel, :db_events],
        measurements: %{},
        metadata: %{tenant: tenant_id}
      },
      limit: [
        value: max_events_per_second,
        measurement: :avg,
        log: true,
        log_fn: fn ->
          Logger.error("MessagePerSecondRateLimitReached: Too many postgres changes messages per second",
            external_id: tenant_id,
            project: tenant_id
          )
        end
      ]
    ]

    %RateCounter.Args{id: db_events_per_second_key(tenant_id), opts: opts}
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

  @doc "RateCounter arguments for counting presence events per second."
  @spec presence_events_per_second_rate(Tenant.t()) :: RateCounter.Args.t()
  def presence_events_per_second_rate(tenant) do
    presence_events_per_second_rate(tenant.external_id, tenant.max_presence_events_per_second)
  end

  @spec presence_events_per_second_rate(String.t(), non_neg_integer) :: RateCounter.Args.t()
  def presence_events_per_second_rate(tenant_id, max_presence_events_per_second) do
    opts = [
      telemetry: %{
        event_name: [:channel, :presence_events],
        measurements: %{limit: max_presence_events_per_second},
        metadata: %{tenant: tenant_id}
      },
      limit: [
        value: max_presence_events_per_second,
        measurement: :avg,
        log_fn: fn ->
          Logger.error("PresenceRateLimitReached: Too many presence events per second",
            external_id: tenant_id,
            project: tenant_id
          )
        end
      ]
    ]

    %RateCounter.Args{id: presence_events_per_second_key(tenant_id), opts: opts}
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

  @spec authorization_errors_per_second_rate(Tenant.t()) :: RateCounter.Args.t()
  def authorization_errors_per_second_rate(%Tenant{external_id: external_id} = tenant) do
    opts = [
      max_bucket_len: 30,
      limit: [
        value: pool_size(tenant),
        measurement: :sum,
        log_fn: fn ->
          Logger.critical("IncreaseConnectionPool: Too many database timeouts",
            external_id: external_id,
            project: external_id
          )
        end
      ]
    ]

    %RateCounter.Args{id: {:channel, :authorization_errors, external_id}, opts: opts}
  end

  @connect_errors_per_second_default 10
  @doc "RateCounter arguments for counting connect per second."
  @spec connect_errors_per_second_rate(Tenant.t() | String.t()) :: RateCounter.Args.t()
  def connect_errors_per_second_rate(%Tenant{external_id: external_id}) do
    connect_errors_per_second_rate(external_id)
  end

  def connect_errors_per_second_rate(tenant_id) do
    opts = [
      max_bucket_len: 30,
      limit: [
        value: @connect_errors_per_second_default,
        measurement: :sum,
        log_fn: fn ->
          Logger.critical(
            "DatabaseConnectionRateLimitReached: Too many connection attempts against the tenant database",
            external_id: tenant_id,
            project: tenant_id
          )
        end
      ]
    ]

    %RateCounter.Args{id: {:database, :connect, tenant_id}, opts: opts}
  end

  defp pool_size(%{extensions: [%{settings: settings} | _]}) do
    Database.pool_size_by_application_name("realtime_connect", settings)
  end

  defp pool_size(_), do: 1

  @spec get_tenant_limits(Realtime.Api.Tenant.t(), maybe_improper_list) :: list
  def get_tenant_limits(%Tenant{} = tenant, keys) when is_list(keys) do
    nodes = [Node.self() | Node.list()]

    nodes
    |> Enum.map(fn node ->
      Task.Supervisor.async({Realtime.TaskSupervisor, node}, fn ->
        for key <- keys do
          response = Realtime.GenCounter.get(key)

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
    |> Api.update_tenant(%{suspend: true})
    |> tap(fn _ -> broadcast_operation_event(:suspend_tenant, external_id) end)
  end

  @doc """
  Sets tenant as unsuspended. New connections will be accepted
  """
  @spec unsuspend_tenant_by_external_id(String.t()) :: {:ok, Tenant.t()} | {:error, term()}
  def unsuspend_tenant_by_external_id(external_id) do
    external_id
    |> Cache.get_tenant_by_external_id()
    |> Api.update_tenant(%{suspend: false})
    |> tap(fn _ -> broadcast_operation_event(:unsuspend_tenant, external_id) end)
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

  @doc """
  Returns the region of the tenant based on its extensions.
  If the region is not set, it returns nil.
  """
  @spec region(Tenant.t()) :: String.t() | nil
  def region(%Tenant{extensions: [%{settings: settings}]}), do: Map.get(settings, "region")
  def region(_), do: nil
end
