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
  alias Realtime.Database
  alias Realtime.Rpc
  alias Realtime.Tenants
  alias Realtime.Tenants.Migrations
  alias Realtime.UsersCounter

  @erpc_timeout_default 5000
  @check_connected_user_interval_default 50_000
  @connected_users_bucket_shutdown [0, 0, 0, 0, 0, 0]
  @application_name "realtime_connect"
  defstruct tenant_id: nil,
            db_conn_reference: nil,
            db_conn_pid: nil,
            check_connected_user_interval: nil,
            connected_users_bucket: [1]

  @doc """
  Returns the database connection for a tenant. If the tenant is not connected, it will attempt to connect to the tenant's database.
  """
  @spec lookup_or_start_connection(binary(), keyword()) ::
          {:ok, DBConnection.t()} | {:error, term()}
  def lookup_or_start_connection(tenant_id, opts \\ []) do
    case get_status(tenant_id) do
      {:ok, conn} -> {:ok, conn}
      {:error, :tenant_database_unavailable} -> call_external_node(tenant_id, opts)
      {:error, :initializing} -> {:error, :tenant_database_unavailable}
    end
  end

  @doc """
  Returns the database connection pid from :syn if it exists.
  """
  @spec get_status(binary()) ::
          {:ok, DBConnection.t()} | {:error, :tenant_database_unavailable | :initializing}
  def get_status(tenant_id) do
    case :syn.lookup(__MODULE__, tenant_id) do
      {_, %{conn: conn}} when not is_nil(conn) -> {:ok, conn}
      {_, %{conn: nil}} -> {:error, :initializing}
      _error -> {:error, :tenant_database_unavailable}
    end
  end

  @doc """
  Connects to a tenant's database and stores the DBConnection in the process :syn metadata
  """
  @spec connect(binary(), keyword()) :: {:ok, DBConnection.t()} | {:error, term()}
  def connect(tenant_id, opts \\ []) do
    supervisor = {:via, PartitionSupervisor, {Realtime.Tenants.Connect.DynamicSupervisor, self()}}
    spec = {__MODULE__, [tenant_id: tenant_id] ++ opts}

    case DynamicSupervisor.start_child(supervisor, spec) do
      {:ok, _} -> get_status(tenant_id)
      {:error, {:already_started, _}} -> get_status(tenant_id)
      _ -> {:error, :tenant_database_unavailable}
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

    GenServer.start_link(__MODULE__, state, name: {:via, :syn, name})
  end

  ## GenServer callbacks
  # Needs to be done on init/1 to guarantee the GenServer only starts if we are able to connect to the database
  @impl GenServer
  def init(%{tenant_id: tenant_id} = state) do
    Logger.metadata(external_id: tenant_id, project: tenant_id)

    with %Tenant{} = tenant <- Tenants.get_tenant_by_external_id(tenant_id),
         res <- Database.check_tenant_connection(tenant, @application_name),
         [%{settings: settings} | _] <- tenant.extensions,
         {:ok, _} <- Migrations.run_migrations(settings) do
      case res do
        {:ok, conn} ->
          :syn.update_registry(__MODULE__, tenant_id, fn _pid, meta -> %{meta | conn: conn} end)

          state = %{state | db_conn_reference: Process.monitor(conn), db_conn_pid: conn}

          {:ok, state, {:continue, :setup_connected_user_events}}

        {:error, error} ->
          log_error("UnableToConnectToTenantDatabase", error)
          {:stop, :normal}
      end
    end
  end

  @impl GenServer
  def handle_continue(
        :setup_connected_user_events,
        %{
          check_connected_user_interval: check_connected_user_interval,
          connected_users_bucket: connected_users_bucket
        } = state
      ) do
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

  def handle_info(:shutdown, %{db_conn_pid: db_conn_pid} = state) do
    Logger.info("Tenant has no connected users, database connection will be terminated")
    :ok = GenServer.stop(db_conn_pid, :normal, 1000)
    {:stop, :normal, state}
  end

  def handle_info({:suspend_tenant, _}, %{db_conn_pid: db_conn_pid} = state) do
    Logger.warning("Tenant was suspended, database connection will be terminated")
    :ok = GenServer.stop(db_conn_pid, :normal, 1000)
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
    {:stop, :normal, state}
  end

  ## Private functions

  defp call_external_node(tenant_id, opts) do
    erpc_timeout = Keyword.get(opts, :erpc_timeout, @erpc_timeout_default)

    with tenant <- Tenants.Cache.get_tenant_by_external_id(tenant_id),
         :ok <- tenant_suspended?(tenant),
         {:ok, node} <- Realtime.Nodes.get_node_for_tenant(tenant) do
      Rpc.enhanced_call(node, __MODULE__, :connect, [tenant_id, opts],
        timeout: erpc_timeout,
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
