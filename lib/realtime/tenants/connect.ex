defmodule Realtime.Tenants.Connect do
  @moduledoc """
  This module is responsible for attempting to connect to a tenant's database and store the DBConnection in a Syn registry.

  ## Options
  * `:check_connected_user_interval` - The interval in milliseconds to check if there are any connected users to a tenant channel. If there are no connected users, the connection will be stopped.
  * `:erpc_timeout` - The timeout in milliseconds for the `:erpc` calls to the tenant's database.
  """
  use GenServer, restart: :transient

  require Logger

  import Realtime.Logs

  alias Realtime.Api.Tenant
  alias Realtime.Rpc
  alias Realtime.Tenants
  alias Realtime.Tenants.ReplicationConnection
  alias Realtime.Tenants.Connect.CheckConnection
  alias Realtime.Tenants.Connect.GetTenant
  alias Realtime.Tenants.Connect.Piper
  alias Realtime.Tenants.Connect.RegisterProcess
  alias Realtime.Tenants.Connect.StartCounters
  alias Realtime.Tenants.Listen
  alias Realtime.Tenants.Migrations
  alias Realtime.UsersCounter

  @rpc_timeout_default 30_000
  @check_connected_user_interval_default 50_000
  @connected_users_bucket_shutdown [0, 0, 0, 0, 0, 0]

  defstruct tenant_id: nil,
            db_conn_reference: nil,
            db_conn_pid: nil,
            broadcast_changes_pid: nil,
            listen_pid: nil,
            check_connected_user_interval: nil,
            connected_users_bucket: [1],
            tenant: nil  # Added to store tenant data for logging

  @doc """
  Returns the database connection for a tenant. If the tenant is not connected, it will attempt to connect to the tenant's database.
  """
  @spec lookup_or_start_connection(binary(), keyword()) ::
          {:ok, pid()}
          | {:error, :tenant_database_unavailable}
          | {:error, :initializing}
          | {:error, :tenant_database_connection_initializing}
          | {:error, :rpc_error, term()}
  def lookup_or_start_connection(tenant_id, opts \\ []) when is_binary(tenant_id) do
    Logger.info("Looking up or starting connection for tenant: #{tenant_id}")
    case get_status(tenant_id) do
      {:ok, conn} ->
        Logger.info("Found existing connection for tenant: #{tenant_id}, pid: #{inspect(conn)}")
        {:ok, conn}

      {:error, :tenant_database_unavailable} ->
        Logger.warning("Tenant database unavailable for: #{tenant_id}, attempting external node")
        call_external_node(tenant_id, opts)

      {:error, :tenant_database_connection_initializing} ->
        Logger.info("Connection initializing for tenant: #{tenant_id}, retrying after 100ms")
        Process.sleep(100)
        call_external_node(tenant_id, opts)

      {:error, :initializing} ->
        Logger.warning("Tenant connection in initializing state for: #{tenant_id}")
        {:error, :tenant_database_unavailable}
    end
  end

  @doc """
  Returns the database connection pid from :syn if it exists.
  """
  @spec get_status(binary()) ::
          {:ok, pid()}
          | {:error, :tenant_database_unavailable}
          | {:error, :initializing}
          | {:error, :tenant_database_connection_initializing}
  def get_status(tenant_id) do
    Logger.debug("Checking connection status for tenant: #{tenant_id}")
    case :syn.lookup(__MODULE__, tenant_id) do
      {_, %{conn: nil}} ->
        Logger.debug("Tenant #{tenant_id} in initializing state")
        {:error, :initializing}

      {_, %{conn: conn}} ->
        Logger.debug("Found active connection for tenant: #{tenant_id}, pid: #{inspect(conn)}")
        {:ok, conn}

      :undefined ->
        Logger.info("No connection found for tenant: #{tenant_id}, starting connection process")
        {:error, :tenant_database_connection_initializing}

      error ->
        log_error("SynInitializationError", error)
        Logger.error("Syn lookup failed for tenant #{tenant_id}: #{inspect(error)}")
        {:error, :tenant_database_unavailable}
    end
  end

  @doc """
  Connects to a tenant's database and stores the DBConnection in the process :syn metadata
  """
  @spec connect(binary(), keyword()) :: {:ok, DBConnection.t()} | {:error, term()}
  def connect(tenant_id, opts \\ []) do
    Logger.info("Initiating connection process for tenant: #{tenant_id}")
    supervisor =
      {:via, PartitionSupervisor, {Realtime.Tenants.Connect.DynamicSupervisor, tenant_id}}

    spec = {__MODULE__, [tenant_id: tenant_id] ++ opts}

    case DynamicSupervisor.start_child(supervisor, spec) do
      {:ok, _} ->
        Logger.info("Successfully started connection process for tenant: #{tenant_id}")
        get_status(tenant_id)

      {:error, {:already_started, _}} ->
        Logger.info("Connection process already started for tenant: #{tenant_id}")
        get_status(tenant_id)

      {:error, {:shutdown, :tenant_db_too_many_connections}} ->
        Logger.error("Too many connections for tenant: #{tenant_id}")
        {:error, :tenant_db_too_many_connections}

      {:error, {:shutdown, :tenant_not_found}} ->
        Logger.error("Tenant not found: #{tenant_id}")
        {:error, :tenant_not_found}

      {:error, :shutdown} ->
        log_error("UnableToConnectToTenantDatabase", "Unable to connect to tenant database")
        Logger.error("Unable to connect to tenant database for: #{tenant_id}")
        {:error, :tenant_database_unavailable}

      {:error, error} ->
        log_error("UnableToConnectToTenantDatabase", error)
        Logger.error("Connection failed for tenant #{tenant_id}: #{inspect(error)}")
        {:error, :tenant_database_unavailable}
    end
  end

  @doc """
  Returns the pid of the tenant Connection process
  """
  @spec whereis(binary()) :: pid | nil
  def whereis(tenant_id) do
    Logger.debug("Looking up pid for tenant: #{tenant_id}")
    case :syn.lookup(__MODULE__, tenant_id) do
      {pid, _} -> pid
      :undefined -> nil
    end
  end

  @doc """
  Shutdown the tenant Connection and linked processes
  """
  @spec shutdown(binary()) :: :ok | nil
  def shutdown(tenant_id) do
    Logger.info("Shutting down connection for tenant: #{tenant_id}")
    case whereis(tenant_id) do
      pid when is_pid(pid) ->
        Logger.info("Stopping connection process for tenant: #{tenant_id}, pid: #{inspect(pid)}")
        GenServer.stop(pid)

      _ ->
        Logger.debug("No connection process found to shutdown for tenant: #{tenant_id}")
        :ok
    end
  end

  def start_link(opts) do
    tenant_id = Keyword.get(opts, :tenant_id)
    Logger.info("Starting connection GenServer for tenant: #{tenant_id}")

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
  @impl GenServer
  def init(%{tenant_id: tenant_id} = state) do
    Logger.metadata(external_id: tenant_id, project: tenant_id)
    Logger.info("Initializing connection for tenant: #{tenant_id}")

    pipes = [
      GetTenant,
      CheckConnection,
      StartCounters,
      RegisterProcess
    ]

    Logger.debug("Running connection pipeline for tenant: #{tenant_id}, pipes: #{inspect(pipes)}")
    case Piper.run(pipes, state) do
      {:ok, %{tenant: tenant} = acc} ->
        Logger.info("Connection pipeline completed successfully for tenant: #{tenant_id}, external_id: #{tenant.external_id}")
        {:ok, %{acc | tenant: tenant}, {:continue, :run_migrations}}

      {:error, :tenant_not_found} ->
        Logger.error("Tenant not found during initialization: #{tenant_id}")
        {:stop, {:shutdown, :tenant_not_found}}

      {:error, :tenant_db_too_many_connections} ->
        Logger.error("Too many connections for tenant: #{tenant_id}")
        {:stop, {:shutdown, :tenant_db_too_many_connections}}

      {:error, error} ->
        log_error("UnableToConnectToTenantDatabase", error)
        Logger.error("Connection initialization failed for tenant #{tenant_id}: #{inspect(error)}")
        {:stop, :shutdown}
    end
  end

  def handle_continue(:run_migrations, %{tenant: tenant, db_conn_pid: db_conn_pid} = state) do
    Logger.info("Running migrations for tenant: #{tenant.external_id}, db_conn_pid: #{inspect(db_conn_pid)}")

    # Run migrations with detailed logging
    Logger.debug("Starting migrations for tenant: #{tenant.external_id}")
    case Migrations.run_migrations(tenant) do
      :ok ->
        Logger.info("✅ Migrations completed successfully for tenant: #{tenant.external_id}")

      {:error, error} ->
        log_error("MigrationsFailedToRun", error)
        Logger.error("❌ Migrations failed for tenant #{tenant.external_id}: #{inspect(error)}")
    end

    # Run partition creation with detailed logging
    Logger.debug("Creating partitions for tenant: #{tenant.external_id}")
    case Migrations.create_partitions(db_conn_pid) do
      :ok ->
        Logger.info("✅ Partitions created successfully for tenant: #{tenant.external_id}")

      {:error, error} ->
        log_error("PartitionCreationFailed", error)
        Logger.error("❌ Partition creation failed for tenant #{tenant.external_id}: #{inspect(error)}")
    end

    Logger.info("Proceeding to start listen and replication for tenant: #{tenant.external_id}")
    {:noreply, state, {:continue, :start_listen_and_replication}}
  rescue
    error ->
      log_error("UnexpectedMigrationError", error)
      Logger.error("❌ Unexpected error during migrations for tenant #{state.tenant && state.tenant.external_id || state.tenant_id}: #{inspect(error)}")
      {:noreply, state, {:continue, :start_listen_and_replication}}
  end

  def handle_continue(:start_listen_and_replication, %{tenant: tenant} = state) do
    Logger.info("Starting listen and replication for tenant: #{tenant.external_id}")

    Logger.debug("Starting replication connection for tenant: #{tenant.external_id}")
    with {:ok, broadcast_changes_pid} <- ReplicationConnection.start(tenant, self()),
         Logger.debug("Starting listen process for tenant: #{tenant.external_id}"),
         {:ok, listen_pid} <- Listen.start(tenant, self()) do
      Logger.info("✅ Listen and replication started successfully for tenant: #{tenant.external_id}, broadcast_pid: #{inspect(broadcast_changes_pid)}, listen_pid: #{inspect(listen_pid)}")
      {:noreply, %{state | broadcast_changes_pid: broadcast_changes_pid, listen_pid: listen_pid},
       {:continue, :setup_connected_user_events}}
    else
      {:error, :max_wal_senders_reached} ->
        log_error("ReplicationMaxWalSendersReached", "Tenant database has reached the maximum number of WAL senders")
        Logger.error("❌ Max WAL senders reached for tenant: #{tenant.external_id}")
        {:stop, :shutdown, state}

      {:error, error} ->
        log_error("StartListenAndReplicationFailed", error)
        Logger.error("❌ Failed to start listen and replication for tenant #{tenant.external_id}: #{inspect(error)}")
        {:stop, :shutdown, state}
    end
  rescue
    error ->
      log_error("StartListenAndReplicationFailed", error)
      Logger.error("❌ Unexpected error during listen/replication setup for tenant #{state.tenant && state.tenant.external_id || state.tenant_id}: #{inspect(error)}")
      {:stop, :shutdown, state}
  end

  @impl true
  def handle_continue(:setup_connected_user_events, state) do
    %{
      check_connected_user_interval: check_connected_user_interval,
      connected_users_bucket: connected_users_bucket,
      tenant_id: tenant_id,
      tenant: tenant
    } = state

    Logger.info("Setting up connected user events for tenant: #{tenant_id}, external_id: #{tenant.external_id}")
    Logger.debug("Subscribing to PubSub topic: realtime:operations:#{tenant_id}")
    :ok = Phoenix.PubSub.subscribe(Realtime.PubSub, "realtime:operations:" <> tenant_id)

    Logger.debug("Scheduling connected user check with interval: #{check_connected_user_interval}ms")
    send_connected_user_check_message(connected_users_bucket, check_connected_user_interval)

    Logger.debug("Inserting tenant_id into ETS: #{tenant_id}")
    :ets.insert(__MODULE__, {tenant_id})

    Logger.info("✅ Connected user events setup completed for tenant: #{tenant_id}")
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(
        :check_connected_users,
        %{
          tenant_id: tenant_id,
          check_connected_user_interval: check_connected_user_interval,
          connected_users_bucket: connected_users_bucket,
          tenant: tenant
        } = state
      ) do
    Logger.debug("Checking connected users for tenant: #{tenant_id}, external_id: #{tenant.external_id}")
    connected_users_bucket =
      tenant_id
      |> update_connected_users_bucket(connected_users_bucket)
      |> send_connected_user_check_message(check_connected_user_interval)

    Logger.debug("Updated connected users bucket: #{inspect(connected_users_bucket)}")
    {:noreply, %{state | connected_users_bucket: connected_users_bucket}}
  end

  def handle_info(:shutdown, %{tenant_id: tenant_id, tenant: tenant} = state) do
    %{
      db_conn_pid: db_conn_pid,
      broadcast_changes_pid: broadcast_changes_pid,
      listen_pid: listen_pid
    } = state

    Logger.info("Initiating shutdown for tenant: #{tenant_id}, external_id: #{tenant.external_id} due to no connected users")
    Logger.debug("Stopping database connection, pid: #{inspect(db_conn_pid)}")
    :ok = GenServer.stop(db_conn_pid, :normal, 500)

    if broadcast_changes_pid && Process.alive?(broadcast_changes_pid) do
      Logger.debug("Stopping broadcast changes process, pid: #{inspect(broadcast_changes_pid)}")
      GenServer.stop(broadcast_changes_pid, :normal, 500)
    end

    if listen_pid && Process.alive?(listen_pid) do
      Logger.debug("Stopping listen process, pid: #{inspect(listen_pid)}")
      GenServer.stop(listen_pid, :normal, 500)
    end

    {:stop, :normal, state}
  end

  def handle_info(:suspend_tenant, %{tenant_id: tenant_id, tenant: tenant} = state) do
    %{
      db_conn_pid: db_conn_pid,
      broadcast_changes_pid: broadcast_changes_pid,
      listen_pid: listen_pid
    } = state

    Logger.warning("Suspending tenant: #{tenant_id}, external_id: #{tenant.external_id}")
    Logger.debug("Stopping database connection, pid: #{inspect(db_conn_pid)}")
    :ok = GenServer.stop(db_conn_pid, :normal, 500)

    if broadcast_changes_pid && Process.alive?(broadcast_changes_pid) do
      Logger.debug("Stopping broadcast changes process, pid: #{inspect(broadcast_changes_pid)}")
      GenServer.stop(broadcast_changes_pid, :normal, 500)
    end

    if listen_pid && Process.alive?(listen_pid) do
      Logger.debug("Stopping listen process, pid: #{inspect(listen_pid)}")
      GenServer.stop(listen_pid, :normal, 500)
    end

    {:stop, :normal, state}
  end

  def handle_info(
        {:DOWN, db_conn_reference, _, _, reason},
        %{db_conn_reference: db_conn_reference, tenant_id: tenant_id, tenant: tenant} = state
      ) do
    Logger.info("Database connection terminated for tenant: #{tenant_id}, external_id: #{tenant.external_id}, reason: #{inspect(reason)}")
    {:stop, :normal, state}
  end

  # Ignore messages to avoid handle_info unmatched functions
  def handle_info(msg, %{tenant_id: tenant_id, tenant: tenant} = state) do
    Logger.debug("Ignoring unknown message for tenant #{tenant_id}, external_id: #{tenant && tenant.external_id || "unknown"}: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, %{tenant_id: tenant_id, tenant: tenant}) do
    Logger.info("Tenant #{tenant_id}, external_id: #{tenant && tenant.external_id || "unknown"} terminated, reason: #{inspect(reason)}")
    Realtime.MetricsCleaner.delete_metric(tenant_id)
    :ok
  end

  ## Private functions
  defp call_external_node(tenant_id, opts) do
    rpc_timeout = Keyword.get(opts, :rpc_timeout, @rpc_timeout_default)
    Logger.info("Calling external node for tenant: #{tenant_id}, timeout: #{rpc_timeout}ms")

    with tenant <- Tenants.Cache.get_tenant_by_external_id(tenant_id),
         :ok <- tenant_suspended?(tenant),
         {:ok, node} <- Realtime.Nodes.get_node_for_tenant(tenant) do
      Logger.debug("Found node for tenant: #{tenant_id}, node: #{inspect(node)}")
      result = Rpc.enhanced_call(node, __MODULE__, :connect, [tenant_id, opts], timeout: rpc_timeout, tenant: tenant_id)
      Logger.info("External node call result for tenant #{tenant_id}: #{inspect(result)}")
      result
    else
      error ->
        Logger.error("External node call failed for tenant #{tenant_id}: #{inspect(error)}")
        {:error, :rpc_error, error}
    end
  end

  defp update_connected_users_bucket(tenant_id, connected_users_bucket) do
    Logger.debug("Updating connected users bucket for tenant: #{tenant_id}")
    new_bucket = connected_users_bucket
    |> then(&(&1 ++ [UsersCounter.tenant_users(tenant_id)]))
    |> Enum.take(-6)
    Logger.debug("New connected users bucket: #{inspect(new_bucket)}")
    new_bucket
  end

  defp send_connected_user_check_message(
         @connected_users_bucket_shutdown,
         check_connected_user_interval
       ) do
    Logger.info("Scheduling shutdown check due to no connected users, interval: #{check_connected_user_interval}ms")
    Process.send_after(self(), :shutdown, check_connected_user_interval)
  end

  defp send_connected_user_check_message(connected_users_bucket, check_connected_user_interval) do
    Logger.debug("Scheduling next connected users check, interval: #{check_connected_user_interval}ms")
    Process.send_after(self(), :check_connected_users, check_connected_user_interval)
    connected_users_bucket
  end

  defp tenant_suspended?(%Tenant{suspend: true}) do
    Logger.warning("Tenant is suspended")
    {:error, :tenant_suspended}
  end

  defp tenant_suspended?(_), do: :ok
end
