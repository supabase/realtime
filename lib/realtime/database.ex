defmodule Realtime.Database do
  @moduledoc """
  Handles tenant database operations
  """
  require Logger

  import Realtime.Logs

  alias Realtime.Api.Tenant
  alias Realtime.Crypto
  alias Realtime.PostgresCdc
  alias Realtime.Rpc

  defstruct [
    :hostname,
    :port,
    :database,
    :username,
    :password,
    :pool_size,
    :queue_target,
    :application_name,
    :max_restarts,
    :socket_options,
    ssl: true,
    backoff_type: :rand_exp
  ]

  @type t :: %__MODULE__{
          hostname: binary(),
          port: non_neg_integer(),
          database: binary(),
          username: binary(),
          password: binary(),
          pool_size: non_neg_integer(),
          queue_target: non_neg_integer(),
          application_name: binary(),
          max_restarts: non_neg_integer(),
          ssl: boolean(),
          backoff_type: :stop | :exp | :rand | :rand_exp,
          socket_options: [[:inet | :inet6]]
        }

  @cdc "postgres_cdc_rls"
  @doc """
  Creates a database connection struct from the given tenant.
  """
  @spec from_tenant(Tenant.t(), binary(), :stop | :exp | :rand | :rand_exp) :: __MODULE__.t()
  def from_tenant(%Tenant{} = tenant, application_name, backoff \\ :rand_exp) do
    tenant
    |> then(&Realtime.PostgresCdc.filter_settings(@cdc, &1.extensions))
    |> then(&from_settings(&1, application_name, backoff))
  end

  @doc """
  Creates a database connection struct from the given settings.
  """
  @spec from_settings(map(), binary(), :stop | :exp | :rand | :rand_exp) :: any()
  def from_settings(settings, application_name, backoff \\ :rand_exp) do
    pool = pool_size_by_application_name(application_name, settings)

    settings =
      settings
      |> Map.take(["db_host", "db_port", "db_name", "db_user", "db_password"])
      |> Enum.map(fn {k, v} -> {k, Crypto.decrypt!(v)} end)
      |> Map.new()
      |> then(&Map.merge(settings, &1))

    {:ok, addrtype} = detect_ip_version(settings["db_host"])
    ssl = if default_ssl_param(settings), do: [verify: :verify_none], else: false

    %__MODULE__{
      hostname: settings["db_host"],
      port: String.to_integer(settings["db_port"]),
      database: settings["db_name"],
      username: settings["db_user"],
      password: settings["db_password"],
      pool_size: pool,
      queue_target: settings["db_queue_target"] || 5_000,
      application_name: application_name,
      backoff_type: backoff,
      socket_options: [addrtype],
      ssl: ssl
    }
  end

  @doc """
  Checks if the Tenant CDC extension information is properly configured and that we're able to query against the tenant database.
  """
  @spec check_tenant_connection(Tenant.t() | nil, binary()) :: {:error, atom()} | {:ok, pid()}
  def check_tenant_connection(tenant, application_name)
  def check_tenant_connection(nil, _), do: {:error, :tenant_not_found}

  def check_tenant_connection(tenant, application_name) do
    tenant
    |> then(&PostgresCdc.filter_settings(@cdc, &1.extensions))
    |> then(fn settings ->
      check_settings = from_settings(settings, application_name, :stop)
      check_settings = Map.put(check_settings, :max_restarts, 0)

      with {:ok, conn} <- connect_db(check_settings) do
        case Postgrex.query(conn, "SELECT 1", []) do
          {:ok, _} ->
            {:ok, conn}

          {:error, e} ->
            Process.exit(conn, :kill)
            log_error("UnableToConnectToTenantDatabase", e)
            {:error, e}
        end
      end
    end)
  end

  @doc """
  Connects to the database using the given settings.
  """
  @spec connect(Tenant.t(), binary(), :stop | :exp | :rand | :rand_exp) ::
          {:ok, pid()} | {:error, any()}
  def connect(tenant, application_name, backoff \\ :stop) do
    tenant
    |> from_tenant(application_name, backoff)
    |> connect_db()
  end

  @doc """
  If the param `ssl_enforced` is not set, it defaults to true.
  """
  @spec default_ssl_param(map) :: boolean
  def default_ssl_param(%{"ssl_enforced" => ssl_enforced}) when is_boolean(ssl_enforced),
    do: ssl_enforced

  def default_ssl_param(_), do: true

  @doc """
  Runs database transaction in local node or against a target node withing a Postgrex transaction
  """
  @spec transaction(pid | DBConnection.t(), fun(), keyword()) :: {:ok, any()} | {:error, any()}
  def transaction(db_conn, func, opts \\ [], metadata \\ [])

  def transaction(%DBConnection{} = db_conn, func, opts, metadata),
    do: transaction_catched(db_conn, func, opts, metadata)

  def transaction(db_conn, func, opts, metadata) when node() == node(db_conn),
    do: transaction_catched(db_conn, func, opts, metadata)

  def transaction(db_conn, func, opts, metadata) do
    metadata = Keyword.put(metadata, :target, node(db_conn))
    args = [db_conn, func, opts, metadata]
    Rpc.enhanced_call(node(db_conn), __MODULE__, :transaction, args)
  end

  defp transaction_catched(db_conn, func, opts, metadata) do
    Postgrex.transaction(db_conn, func, opts)
  rescue
    e ->
      log_error("ErrorExecutingTransaction", e, metadata)
      {:error, e}
  end

  @spec connect_db(__MODULE__.t()) :: {:ok, pid()} | {:error, any()}
  def connect_db(%__MODULE__{} = settings) do
    %__MODULE__{
      hostname: hostname,
      port: port,
      database: database,
      username: username,
      password: password,
      pool_size: pool_size,
      queue_target: queue_target,
      application_name: application_name,
      backoff_type: backoff_type,
      max_restarts: max_restarts,
      socket_options: socket_options,
      ssl: ssl
    } = settings

    Logger.metadata(application_name: application_name)
    metadata = Logger.metadata()

    [
      hostname: hostname,
      port: port,
      database: database,
      username: username,
      password: password,
      pool_size: pool_size,
      queue_target: queue_target,
      parameters: [application_name: application_name],
      socket_options: socket_options,
      backoff_type: backoff_type,
      ssl: ssl,
      configure: fn args ->
        Logger.metadata(metadata)
        args
      end
    ]
    |> then(fn opts ->
      if max_restarts, do: Keyword.put(opts, :max_restarts, max_restarts), else: opts
    end)
    |> Postgrex.start_link()
  end

  @doc """
  Returns the pool size for a given application name. Override pool size if provided.

  `realtime_rls` and `realtime_broadcast_changes` will be handled as a special scenario as it will need to be hardcoded as 1 otherwise replication slots will be tried to be reused leading to errors
  `realtime_migrations` will be handled as a special scenario as it requires 2 connections.
  """
  @spec pool_size_by_application_name(binary(), map() | nil) :: non_neg_integer()
  def pool_size_by_application_name(application_name, settings) do
    case application_name do
      "realtime_subscription_manager" -> settings["subcriber_pool_size"] || 1
      "realtime_subscription_manager_pub" -> settings["subs_pool_size"] || 1
      "realtime_subscription_checker" -> settings["subs_pool_size"] || 1
      "realtime_connect" -> settings["db_pool"] || 1
      "realtime_health_check" -> 1
      "realtime_janitor" -> 1
      "realtime_migrations" -> 2
      "realtime_broadcast_changes" -> 1
      "realtime_rls" -> 1
      "realtime_replication_slot_teardown" -> 1
      _ -> 1
    end
  end

  @doc """
  Gets the external id from a host connection string found in the conn.
  """
  @spec get_external_id(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def get_external_id(host) when is_binary(host) do
    case String.split(host, ".", parts: 2) do
      [] -> {:error, :tenant_not_found_in_host}
      [id] -> {:ok, id}
      [id, _] -> {:ok, id}
    end
  end

  @doc """
  Detects the IP version for a given host.
  """
  @spec detect_ip_version(String.t()) :: {:ok, :inet | :inet6} | {:error, :nxdomain}
  def detect_ip_version(host) when is_binary(host) do
    host = String.to_charlist(host)

    cond do
      match?({:ok, _}, :inet6_tcp.getaddr(host)) -> {:ok, :inet6}
      match?({:ok, _}, :inet.gethostbyname(host)) -> {:ok, :inet}
      true -> {:error, :nxdomain}
    end
  end

  @doc """
  Terminates all replication slots with the name containing 'realtime' in the tenant database.
  """
  @spec replication_slot_teardown(Tenant.t()) :: :ok
  def replication_slot_teardown(tenant) do
    {:ok, conn} = connect(tenant, "realtime_replication_slot_teardown")

    query =
      "select slot_name from pg_replication_slots where slot_name like '%realtime%'"

    with {:ok, %{rows: [rows]}} <- Postgrex.query(conn, query, []) do
      rows
      |> Enum.reject(&is_nil/1)
      |> Enum.each(&replication_slot_teardown(conn, &1))
    end

    GenServer.stop(conn)
    :ok
  end

  @doc """
  Terminates replication slot with a given name in the tenant database.
  """
  @spec replication_slot_teardown(pid() | Tenant.t(), String.t()) :: :ok
  def replication_slot_teardown(%Tenant{} = tenant, slot_name) do
    {:ok, conn} = connect(tenant, "realtime_replication_slot_teardown")
    replication_slot_teardown(conn, slot_name)
    :ok
  end

  def replication_slot_teardown(conn, slot_name) do
    Postgrex.query(conn, "select pg_drop_replication_slot($1)", [slot_name])
    :ok
  end
end
