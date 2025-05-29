defmodule Realtime.Tenants.Listen do
  @moduledoc """
  Listen for Postgres notifications to identify issues with the functions that are being called in tenants database
  """
  use GenServer, restart: :transient
  use Realtime.Logs

  alias Realtime.Api.Tenant
  alias Realtime.Database
  alias Realtime.Registry.Unique
  alias Realtime.Tenants.Cache

  @type t :: %__MODULE__{
          tenant_id: binary,
          listen_conn: pid(),
          monitored_pid: pid()
        }
  defstruct tenant_id: nil, listen_conn: nil, monitored_pid: nil

  @topic "realtime:system"
  def start_link(%__MODULE__{tenant_id: tenant_id} = state) do
    name = {:via, Registry, {Unique, {__MODULE__, :tenant_id, tenant_id}}}
    GenServer.start_link(__MODULE__, state, name: name)
  end

  def init(%__MODULE__{tenant_id: tenant_id, monitored_pid: monitored_pid}) do
    Logger.metadata(external_id: tenant_id, project: tenant_id)
    Process.monitor(monitored_pid)

    tenant = Cache.get_tenant_by_external_id(tenant_id)
    connection_opts = Database.from_tenant(tenant, "realtime_listen", :stop)

    name =
      {:via, Registry, {Realtime.Registry.Unique, {Postgrex.Notifications, :tenant_id, tenant_id}}}

    settings =
      [
        hostname: connection_opts.hostname,
        database: connection_opts.database,
        password: connection_opts.password,
        username: connection_opts.username,
        port: connection_opts.port,
        ssl: connection_opts.ssl,
        socket_options: connection_opts.socket_options,
        sync_connect: true,
        auto_reconnect: false,
        backoff_type: :stop,
        max_restarts: 0,
        name: name,
        parameters: [application_name: "realtime_listen"]
      ]

    Logger.info("Listening for notifications on #{@topic}")

    case Postgrex.Notifications.start_link(settings) do
      {:ok, conn} ->
        Postgrex.Notifications.listen!(conn, @topic)
        {:ok, %{tenant_id: tenant.external_id, listen_conn: conn}}

      {:error, {:already_started, conn}} ->
        Postgrex.Notifications.listen!(conn, @topic)
        {:ok, %{tenant_id: tenant.external_id, listen_conn: conn}}

      {:error, reason} ->
        {:stop, reason}
    end
  catch
    e -> {:stop, e}
  end

  @spec start(Realtime.Api.Tenant.t(), pid()) :: {:ok, pid()} | {:error, any()}
  def start(%Tenant{} = tenant, pid) do
    supervisor = {:via, PartitionSupervisor, {Realtime.Tenants.Listen.DynamicSupervisor, self()}}
    spec = {__MODULE__, %__MODULE__{tenant_id: tenant.external_id, monitored_pid: pid}}

    case DynamicSupervisor.start_child(supervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> {:error, error}
    end
  catch
    e -> {:error, e}
  end

  @doc """
  Finds replication connection by tenant_id
  """
  @spec whereis(String.t()) :: pid() | nil
  def whereis(tenant_id) do
    case Registry.lookup(Realtime.Registry.Unique, {Postgrex.Notifications, :tenant_id, tenant_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def handle_info({:notification, _, _, @topic, payload}, state) do
    case Jason.decode(payload) do
      {:ok, %{"function" => "realtime.send"} = parsed} when is_map_key(parsed, "error") ->
        log_error("FailedSendFromDatabase", parsed)

      {:error, _} ->
        log_error("FailedToParseDiagnosticMessage", payload)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, _, :process, _, _}, state), do: {:stop, :normal, state}
  def handle_info(_, state), do: {:noreply, state}
end
