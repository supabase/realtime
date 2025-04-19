defmodule Realtime.PubSubAdapter.TenantGroupRefresher do
  @moduledoc """
  A GenServer that periodically refreshes tenant group mappings in cache.

  This module maintains a cache of tenant groups by periodically scanning :syn and Phoenix.PubSub
  ETS tables to build a mapping of tenant groups to their associated processes. This is used
  to optimize tenant-specific pub/sub operations.
  """

  use GenServer
  require Logger

  @tenant_group_cache Realtime.PubSubAdapter.Cachex
  @syn_users_table :syn_pg_by_name_users
  @pubsub_table Phoenix.PubSub

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(_) do
    Logger.info("Starting TenantGroupRefresher")
    interval = Application.get_env(:realtime, :tenant_map_refresh_interval)
    schedule_refresh(interval)
    {:ok, %{refresh_interval: interval}}
  end

  @impl true
  def handle_info(:refresh, state) do
    :users
    |> :syn.local_group_names()
    |> Enum.each(fn tenant_id ->
      group = tenant_group(tenant_id)
      Cachex.put(@tenant_group_cache, tenant_id, group)
    end)

    schedule_refresh(state.refresh_interval)
    {:noreply, state}
  end

  ### Internal functions

  defp schedule_refresh(interval), do: Process.send_after(self(), :refresh, interval)

  @spec tenant_group(String.t()) :: %{atom() => [pid()]}
  defp tenant_group(tenant_id) do
    tenant_nodes =
      :ets.foldl(
        fn
          {{^tenant_id, _}, _, _, _, node}, acc -> MapSet.put(acc, node)
          _, acc -> acc
        end,
        MapSet.new(),
        @syn_users_table
      )

    :ets.foldl(
      fn
        {adapter_name, group, _}, acc ->
          filtered_pids = Enum.filter(group, fn pid -> MapSet.member?(tenant_nodes, node(pid)) end)
          Map.put(acc, adapter_name, filtered_pids)
      end,
      %{},
      @pubsub_table
    )
  end
end
