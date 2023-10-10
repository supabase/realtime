defmodule Realtime.Tenants.Connect do
  @moduledoc """
  This module is responsible for attempting to connect to a tenant's database and store the DBConnection in a Syn registry.
  """
  use GenServer

  require Logger

  alias Realtime.Helpers
  alias Realtime.Tenants

  defstruct reference_tenant_id_mapping: %{}

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

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)

  def init(state), do: {:ok, state, {:continue, :setup_syn}}

  ## GenServer callbacks

  def handle_continue(:setup_syn, state) do
    :ok = :syn.add_node_to_scopes([__MODULE__])
    {:noreply, state}
  end

  def handle_cast({:set_status, tenant_id}, state) do
    with tenant when not is_nil(tenant) <- Tenants.Cache.get_tenant_by_external_id(tenant_id),
         res <- Helpers.check_tenant_connection(tenant) do
      case res do
        {:ok, conn} ->
          ref = Process.monitor(conn)

          state =
            Map.update(state, :reference_tenant_id_mapping, %{}, fn map ->
              Map.put(map, ref, tenant_id)
            end)

          :syn.register(__MODULE__, tenant_id, self(), %{conn: conn})
          {:noreply, state}

        {:error, error} ->
          Logger.error("Error connecting to tenant database: #{inspect(error)}")
          {:noreply, state}
      end
    end
  end

  def handle_info({:DOWN, ref, _, _, _}, state) do
    tenant_id = state |> Map.from_struct() |> get_in([:reference_tenant_id_mapping, ref])
    :syn.unregister(__MODULE__, tenant_id)
    {:noreply, state}
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
         :ok <- :erpc.call(node, __MODULE__, :set_status, [tenant_id], 3000) do
      get_status(tenant_id)
    end
  end

  defp set_status_backoff(tenant_id, times \\ 5, backoff \\ 500)
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
end
