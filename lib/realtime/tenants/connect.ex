defmodule Realtime.Tenants.Connect do
  @moduledoc """
  This module is responsible for attempting to connect to a tenant's database and store the DBConnection in a Syn registry.

  ## Options
  * `:check_connected_user_interval` - The interval in milliseconds to check if there are any connected users to a tenant channel. If there are no connected users, the connection will be stopped.
  * `:erpc_timeout` - The timeout in milliseconds for the `:erpc` calls to the tenant's database.
  """
  use GenServer, restart: :transient

  require Logger

  import Realtime.Helpers, only: [log_error: 2]

  alias Realtime.Api.Tenant
  alias Realtime.Rpc
  alias Realtime.Tenants
  alias Realtime.Tenants.Migrations
  alias Realtime.UsersCounter
  alias Realtime.Tenants.Connect.Piper
  alias Realtime.Tenants.Connect.CheckConnection
  alias Realtime.Tenants.Connect.StartReplication
  alias Realtime.Tenants.Connect.Migrations
  alias Realtime.Tenants.Connect.GetTenant
  alias Realtime.Tenants.Connect.RegisterProcess
  alias Realtime.Tenants.Connect.StartCounters
  alias Realtime.Tenants.Connect.CreatePartitions

  @pipes [
    GetTenant,
    CheckConnection,
    Migrations,
    StartCounters,
    StartReplication,
    RegisterProcess,
    CreatePartitions
  ]
  @rpc_timeout_default 30_000
  @check_connected_user_interval_default 50_000
  @connected_users_bucket_shutdown [0, 0, 0, 0, 0, 0]

  defstruct tenant_id: nil,
            db_conn_reference: nil,
            db_conn_pid: nil,
            broadcast_changes_pid: nil,
            check_connected_user_interval: nil,
            connected_users_bucket: [1]

  @doc """
  Returns the database connection for a tenant. If the tenant is not connected, it will attempt to connect to the tenant's database.
  """
  @spec lookup_or_start_connection(binary(), keyword()) ::
          {:ok, DBConnection.t()} | {:error, term()}
  def lookup_or_start_connection(tenant_id, opts \\ []) do
    case get_status(tenant_id) do
      {:ok, conn} ->
        {:ok, conn}

      {:error, :tenant_database_unavailable} ->
        call_external_node(tenant_id, opts)

      {:error, :tenant_database_connection_initializing} ->
        :timer.sleep(100)
        call_external_node(tenant_id, opts)

      {:error, :initializing} ->
        {:error, :tenant_database_unavailable}
    end
  end

  @doc """
  Returns the database connection pid from :syn if it exists.
  """
  @spec get_status(binary()) ::
          {:ok, pid()}
          | {:error,
             :tenant_database_unavailable
             | :initializing
             | :tenant_database_connection_initializing}
  def get_status(tenant_id) do
    case :syn.lookup(__MODULE__, tenant_id) do
      {_, %{conn: conn}} when not is_nil(conn) ->
        {:ok, conn}

      {_, %{conn: nil}} ->
        {:error, :initializing}

      :undefined ->
        Logger.warning("Connection process starting up")
        {:error, :tenant_database_connection_initializing}

      error ->
        log_error("SynInitializationError", error)
        {:error, :tenant_database_unavailable}
    end
  end

  @doc """
  Connects to a tenant's database and stores the DBConnection in the process :syn metadata
  """
  @spec connect(binary(), keyword()) :: {:ok, DBConnection.t()} | {:error, term()}
  def connect(tenant_id, opts \\ []) do
    supervisor =
      {:via, PartitionSupervisor, {Realtime.Tenants.Connect.DynamicSupervisor, tenant_id}}

    spec = {__MODULE__, [tenant_id: tenant_id] ++ opts}

    case DynamicSupervisor.start_child(supervisor, spec) do
      {:ok, _} -> get_status(tenant_id)
      {:error, {:already_started, _}} -> get_status(tenant_id)
      _ -> {:error, :tenant_database_unavailable}
    end
  end

  def shutdown(tenant_id) do
    case get_status(tenant_id) do
      {:ok, conn} ->
        Process.exit(conn, :kill)
        {:ok, :shutdown}

      _ ->
        {:error, :unable_to_shutdown}
    end
  end

  def start_link(opts) do
    tenant_id = Keyword.get(opts, :tenant_id)

    check_connected_user_interval =
      Keyword.get(opts, :check_connected_user_interval, @check_connected_user_interval_default)

    name = {__MODULE__, tenant_id, %{conn: nil}}

    state = %__MODULE__{
      tenant_id: tenant_id,
      check_connected_user_interval: check_connected_user_interval
    }

    opts = Keyword.put(opts, :name, {:via, :syn, name})

    GenServer.start_link(__MODULE__, state, opts)
  end

  ## GenServer callbacks
  # Needs to be done on init/1 to guarantee the GenServer only starts if we are able to connect to the database
  @impl GenServer
  def init(%{tenant_id: tenant_id} = state) do
    Logger.metadata(external_id: tenant_id, project: tenant_id)

    with {:ok, acc} <- Piper.run(@pipes, state) do
      {:ok, acc, {:continue, :setup_connected_user_events}}
    else
      {:error, :tenant_not_found} ->
        log_error("TenantNotFound", "Tenant not found")
        {:stop, :shutdown}

      {:error, error} ->
        log_error("UnableToConnectToTenantDatabase", error)
        {:stop, :shutdown}
    end
  end

  @impl true
  def handle_continue(:setup_connected_user_events, state) do
    %{
      check_connected_user_interval: check_connected_user_interval,
      connected_users_bucket: connected_users_bucket
    } = state

    :ok = Phoenix.PubSub.subscribe(Realtime.PubSub, "realtime:operations:invalidate_cache")
    send_connected_user_check_message(connected_users_bucket, check_connected_user_interval)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(
        :check_connected_users,
        %{
          tenant_id: tenant_id,
          check_connected_user_interval: check_connected_user_interval,
          connected_users_bucket: connected_users_bucket
        } = state
      ) do
    connected_users_bucket =
      tenant_id
      |> update_connected_users_bucket(connected_users_bucket)
      |> send_connected_user_check_message(check_connected_user_interval)

    {:noreply, %{state | connected_users_bucket: connected_users_bucket}}
  end

  def handle_info(
        :shutdown,
        %{db_conn_pid: db_conn_pid, broadcast_changes_pid: broadcast_changes_pid} = state
      ) do
    Logger.info("Tenant has no connected users, database connection will be terminated")
    :ok = GenServer.stop(db_conn_pid, :normal, 500)

    broadcast_changes_pid && Process.alive?(broadcast_changes_pid) &&
      GenServer.stop(broadcast_changes_pid, :normal, 500)

    {:stop, :normal, state}
  end

  def handle_info(
        {:suspend_tenant, _},
        %{db_conn_pid: db_conn_pid, broadcast_changes_pid: broadcast_changes_pid} = state
      ) do
    Logger.warning("Tenant was suspended, database connection will be terminated")
    :ok = GenServer.stop(db_conn_pid, :normal, 500)

    broadcast_changes_pid && Process.alive?(broadcast_changes_pid) &&
      GenServer.stop(broadcast_changes_pid, :normal, 500)

    {:stop, :normal, state}
  end

  # Ignore unsuspend messages to avoid handle_info unmatched functions
  def handle_info({:unsuspend_tenant, _}, state) do
    {:noreply, state}
  end

  # Ignore invalidate_cache messages to avoid handle_info unmatched functions
  def handle_info({:invalidate_cache, _}, state) do
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, db_conn_reference, _, _, _},
        %{db_conn_reference: db_conn_reference} = state
      ) do
    Logger.info("Database connection has been terminated")
    {:stop, :kill, state}
  end

  ## Private functions

  defp call_external_node(tenant_id, opts) do
    rpc_timeout = Keyword.get(opts, :rpc_timeout, @rpc_timeout_default)

    with tenant <- Tenants.Cache.get_tenant_by_external_id(tenant_id),
         :ok <- tenant_suspended?(tenant),
         {:ok, node} <- Realtime.Nodes.get_node_for_tenant(tenant) do
      Rpc.enhanced_call(node, __MODULE__, :connect, [tenant_id, opts],
        timeout: rpc_timeout,
        tenant: tenant_id
      )
    end
  end

  defp update_connected_users_bucket(tenant_id, connected_users_bucket) do
    connected_users_bucket
    |> then(&(&1 ++ [UsersCounter.tenant_users(tenant_id)]))
    |> Enum.take(-6)
  end

  defp send_connected_user_check_message(
         @connected_users_bucket_shutdown,
         check_connected_user_interval
       ) do
    Process.send_after(self(), :shutdown, check_connected_user_interval)
  end

  defp send_connected_user_check_message(connected_users_bucket, check_connected_user_interval) do
    Process.send_after(self(), :check_connected_users, check_connected_user_interval)
    connected_users_bucket
  end

  defp tenant_suspended?(%Tenant{suspend: true}), do: {:error, :tenant_suspended}
  defp tenant_suspended?(_), do: :ok
end
