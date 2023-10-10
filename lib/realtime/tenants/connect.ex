defmodule Realtime.Tenants.Connect do
  @moduledoc """
  This module is responsible for attempting to connect to a tenant's database and store the DBConnection in a Syn registry.
  """
  use GenServer

  require Logger

  alias Realtime.Helpers
  alias Realtime.Tenants

  @spec connection_status(binary()) :: {:ok, DBConnection.t()} | {:error, term()}
  def connection_status(tenant_id) do
    case get_status(tenant_id) do
      :undefined -> call_external_node(tenant_id)
      {:ok, conn} -> {:ok, conn}
      _ -> {:error, :tenant_database_unavailable}
    end
  end

  def set_status(tenant_id) do
    :ok = GenServer.cast(__MODULE__, {:set_status, tenant_id})
    set_status_backoff(tenant_id)
  end

  def get_status(tenant_id) do
    case :syn.lookup(__MODULE__, tenant_id) do
      {_, %{conn: conn}} when not is_nil(conn) -> {:ok, conn}
      error -> error
    end
  end

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(state), do: {:ok, state, {:continue, :setup_syn}}

  ## GenServer callbacks
  def handle_continue(:setup_syn, state) do
    :ok = :syn.add_node_to_scopes([__MODULE__])
    {:noreply, state}
  end

  def handle_cast({:set_status, tenant_id}, state) do
    with tenant when not is_nil(tenant) <- Tenants.Cache.get_tenant_by_external_id(tenant_id),
         res <- Helpers.check_tenant_connection(tenant) do
      update_syn_with_conn_check(res, tenant_id)
    end

    {:noreply, state}
  end

  ## Private functions

  defp call_external_node(tenant_id) do
    with tenant <- Tenants.Cache.get_tenant_by_external_id(tenant_id),
         {:ok, node} <- Realtime.Nodes.get_node_for_tenant(tenant),
         :ok <- :erpc.call(node, __MODULE__, :set_status, [tenant_id], 2000) do
      get_status(tenant_id)
    end
  end

  defp set_status_backoff(tenant_id, times \\ 3, backoff \\ 300)
  defp set_status_backoff(_, 0, _), do: {:error, :tenant_database_unavailable}

  defp set_status_backoff(tenant_id, times, backoff) do
    case get_status(tenant_id) do
      :undefined ->
        :timer.sleep(backoff)
        set_status_backoff(tenant_id, times - 1, backoff)

      _ ->
        :ok
    end
  end

  defp update_syn_with_conn_check(res, tenant_id) do
    case res do
      {:ok, conn} ->
        :syn.register(__MODULE__, tenant_id, self(), %{conn: conn})

      {:error, error} ->
        Logger.error("Error connecting to tenant database: #{inspect(error)}")
        :ok
    end
  end
end
