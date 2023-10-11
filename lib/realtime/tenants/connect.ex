defmodule Realtime.Tenants.Connect do
  @moduledoc """
  This module is responsible for attempting to connect to a tenant's database and store the DBConnection in a Syn registry.
  """
  use GenServer

  require Logger

  alias Realtime.Helpers
  alias Realtime.Tenants

  defstruct tenant_id: nil, db_conn_reference: nil

  @doc """
  Returns the database connection for a tenant. If the tenant is not connected, it will attempt to connect to the tenant's database.
  """
  @spec lookup_or_start_connection(binary()) :: {:ok, DBConnection.t()} | {:error, term()}
  def lookup_or_start_connection(tenant_id) do
    case get_status(tenant_id) do
      :undefined -> call_external_node(tenant_id)
      {:ok, conn} -> {:ok, conn}
      _ -> {:error, :tenant_database_unavailable}
    end
  end

  @doc """
  Connects to a tenant's database and stores the DBConnection in the process :syn metadata
  """
  @spec connect(binary()) :: {:ok, DBConnection.t()} | {:error, term()}
  def connect(tenant_id) do
    supervisor = {:via, PartitionSupervisor, {Realtime.Tenants.Connect.DynamicSupervisor, self()}}
    spec = {__MODULE__, tenant_id: tenant_id}

    case DynamicSupervisor.start_child(supervisor, spec) do
      {:ok, pid} -> GenServer.call(pid, :get_status)
      {:error, {:already_started, pid}} -> GenServer.call(pid, :get_status)
      _ -> {:error, :tenant_database_unavailable}
    end
  end

  def start_link(tenant_id: tenant_id) do
    name = {__MODULE__, tenant_id, %{conn: nil}}
    GenServer.start_link(__MODULE__, %__MODULE__{tenant_id: tenant_id}, name: {:via, :syn, name})
  end

  ## GenServer callbacks
  # Needs to be done on init/1 to guarantee the GenServer only starts if we are able to connect to the database
  @impl GenServer
  def init(%{tenant_id: tenant_id} = state) do
    with tenant when not is_nil(tenant) <- Tenants.Cache.get_tenant_by_external_id(tenant_id),
         res <- Helpers.check_tenant_connection(tenant) do
      case res do
        {:ok, conn} ->
          :syn.update_registry(__MODULE__, tenant_id, fn _pid, meta -> %{meta | conn: conn} end)
          state = %{state | db_conn_reference: Process.monitor(conn)}

          {:ok, state}

        {:error, error} ->
          Logger.error("Error connecting to tenant database: #{inspect(error)}")
          {:stop, :normal, state}
      end
    end
  end

  @impl GenServer
  def handle_call(:get_status, _, %{tenant_id: tenant_id} = state),
    do: {:reply, get_status(tenant_id), state}

  @impl GenServer
  def handle_info(
        {:DOWN, db_conn_reference, _, _, _},
        %{db_conn_reference: db_conn_reference} = state
      ) do
    Logger.info("Database connection has been terminated")
    {:stop, :normal, state}
  end

  ## Private functions

  defp get_status(tenant_id) do
    case :syn.lookup(__MODULE__, tenant_id) do
      {_, %{conn: conn}} when not is_nil(conn) -> {:ok, conn}
      error -> error
    end
  end

  defp call_external_node(tenant_id) do
    with tenant <- Tenants.Cache.get_tenant_by_external_id(tenant_id),
         {:ok, node} <- Realtime.Nodes.get_node_for_tenant(tenant),
         :ok <- :erpc.call(node, __MODULE__, :connect, [tenant_id], 5000) do
      get_status(tenant_id)
    end
  end
end
