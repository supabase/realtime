defmodule Realtime.Database do
  @moduledoc """
  Handles tenant database operations
  """

  alias Realtime.Api.Tenant
  alias Realtime.Crypto
  alias Realtime.Helpers
  alias Realtime.PostgresCdc
  alias Realtime.Rpc

  defstruct [
    :host,
    :port,
    :name,
    :user,
    :pass,
    :pool,
    :queue_target,
    ssl_enforced: true,
    application_name: "realtime_supabase",
    backoff: :rand_exp
  ]

  @type t :: %__MODULE__{
          host: binary(),
          port: binary(),
          name: binary(),
          user: binary(),
          pass: binary(),
          pool: non_neg_integer(),
          queue_target: non_neg_integer(),
          ssl_enforced: boolean(),
          application_name: binary(),
          backoff: :stop | :exp | :rand | :rand_exp
        }

  @spec from_settings(map(), binary(), :stop | :exp | :rand | :rand_exp) :: Realtime.Database.t()
  def from_settings(settings, application_name, backoff \\ :rand_exp) do
    pool =
      settings["subs_pool_size"] || settings["subcriber_pool_size"] || settings["db_pool"] || 1

    %__MODULE__{
      host: settings["db_host"],
      port: settings["db_port"],
      name: settings["db_name"],
      user: settings["db_user"],
      pass: settings["db_password"],
      pool: pool,
      queue_target: settings["db_queue_target"] || 5_000,
      ssl_enforced: default_ssl_param(settings),
      application_name: application_name,
      backoff: backoff
    }
  end

  @spec connect_db(__MODULE__.t()) :: {:error, any} | {:ok, pid}
  def connect_db(%__MODULE__{} = settings) do
    %__MODULE__{
      host: host,
      port: port,
      name: name,
      user: user,
      pass: pass,
      pool: pool,
      queue_target: queue_target,
      ssl_enforced: ssl_enforced,
      application_name: application_name,
      backoff: backoff
    } = settings

    connect_db(
      host,
      port,
      name,
      user,
      pass,
      pool,
      queue_target,
      ssl_enforced,
      application_name,
      backoff
    )
  end

  @cdc "postgres_cdc_rls"
  @doc """
  Checks if the Tenant CDC extension information is properly configured and that we're able to query against the tenant database.
  """
  @spec check_tenant_connection(Tenant.t(), binary()) :: {:error, atom()} | {:ok, pid()}
  def check_tenant_connection(nil, _, _), do: {:error, :tenant_not_found}

  def check_tenant_connection(tenant, application_name) do
    tenant
    |> then(&PostgresCdc.filter_settings(@cdc, &1.extensions))
    |> then(fn settings ->
      check_settings = from_settings(settings, application_name, :stop)

      with {:ok, conn} <- connect_db(check_settings) do
        case Postgrex.query(conn, "SELECT 1", []) do
          {:ok, _} ->
            {:ok, conn}

          {:error, e} ->
            Process.exit(conn, :kill)
            Helpers.log_error("UnableToConnectToTenantDatabase", e)

            {:error, :tenant_database_unavailable}
        end
      end
    end)
  end

  @doc """
  If the param `ssl_enforced` is not set, it defaults to true.
  """
  @spec default_ssl_param(map) :: boolean
  def default_ssl_param(%{"ssl_enforced" => ssl_enforced}) when is_boolean(ssl_enforced),
    do: ssl_enforced

  def default_ssl_param(_), do: true

  @doc """
  Enforces SSL configuration on the database connection if `ssl_enforced` is set to true.
  """
  @spec maybe_enforce_ssl_config(maybe_improper_list, boolean()) :: maybe_improper_list
  def maybe_enforce_ssl_config(db_config, true) when is_list(db_config) do
    enforce_ssl_config(db_config)
  end

  def maybe_enforce_ssl_config(db_config, false) when is_list(db_config) do
    db_config
  end

  def maybe_enforce_ssl_config(db_config, _) do
    enforce_ssl_config(db_config)
  end

  defp enforce_ssl_config(db_config) when is_list(db_config) do
    db_config ++ [ssl: true, ssl_opts: [verify: :verify_none]]
  end

  @doc """
  Gets the external id from a host connection string found in the conn.

  ## Examples

  iex> Realtime.Database.get_external_id("tenant.realtime.supabase.co")
  {:ok, "tenant"}

  iex> Realtime.Database.get_external_id("tenant.supabase.co")
  {:ok, "tenant"}

  iex> Realtime.Database.get_external_id("localhost")
  {:ok, "localhost"}

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
  Terminates all replication slots with the name containing 'realtime' in the tenant database.
  """
  @spec replication_slot_teardown(Tenant.t()) :: :ok
  def replication_slot_teardown(tenant) do
    {:ok, conn} = check_tenant_connection(tenant, "replication_slot_teardown")

    with {:ok, %{rows: rows}} <-
           Postgrex.query(
             conn,
             "select active_pid from pg_replication_slots where slot_name ilike '%realtime%'",
             []
           ) do
      Enum.each(rows, fn [pid] ->
        Postgrex.query!(conn, "select pg_terminate_backend(#{pid})", [])
      end)

      :ok
    end
  end

  @doc """
  Runs database transaction in local node or against a target node withing a Postgrex transaction
  """
  @spec transaction(pid | DBConnection.t(), fun) :: any()
  def transaction(%DBConnection{} = db_conn, func) do
    with {:ok, result} <- Postgrex.transaction(db_conn, func) do
      result
    else
      {:error, error} -> error
    end
  end

  def transaction(db_conn, func) when node() == node(db_conn) do
    with {:ok, result} <- Postgrex.transaction(db_conn, func) do
      result
    else
      {:error, error} -> error
    end
  end

  def transaction(db_conn, func) do
    Rpc.enhanced_call(node(db_conn), __MODULE__, :transaction, [db_conn, func], timeout: 15_000)
  end

  @doc """
  Detects the IP version for a given host.

  ## Examples
      # Using ipv4.google.com
      iex> Realtime.Database.detect_ip_version("ipv4.google.com")
      {:ok, :inet}

      # Using ipv6.google.com
      iex> Realtime.Database.detect_ip_version("ipv6.google.com")
      {:ok, :inet6}

      # Using 2001:0db8:85a3:0000:0000:8a2e:0370:7334
      iex> Realtime.Database.detect_ip_version("2001:0db8:85a3:0000:0000:8a2e:0370:7334")
      {:ok, :inet6}

      # Using 127.0.0.1
      iex> Realtime.Database.detect_ip_version("127.0.0.1")
      {:ok, :inet}

      # Using invalid domain
      iex> Realtime.Database.detect_ip_version("potato")
      {:error, :nxdomain}
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

  defp connect_db(
         host,
         port,
         name,
         user,
         pass,
         pool,
         queue_target,
         ssl_enforced,
         application_name,
         backoff_type
       ) do
    Logger.metadata(application_name: application_name)
    metadata = Logger.metadata()
    {host, port, name, user, pass} = Crypto.decrypt_creds(host, port, name, user, pass)
    {:ok, addrtype} = detect_ip_version(host)

    [
      hostname: host,
      port: port,
      database: name,
      password: pass,
      username: user,
      pool_size: pool,
      queue_target: queue_target,
      parameters: [
        application_name: application_name
      ],
      socket_options: [addrtype],
      backoff_type: backoff_type,
      configure: fn args ->
        Logger.metadata(metadata)
        args
      end
    ]
    |> maybe_enforce_ssl_config(ssl_enforced)
    |> Postgrex.start_link()
  end
end
