defmodule Realtime.SynHandler do
  @moduledoc """
  Custom defined Syn's callbacks
  """
  require Logger
  alias RealtimeWeb.Endpoint

  def on_process_unregistered(mod, name, _pid, _meta, reason) do
    Logger.warn("#{mod} terminated: #{inspect(name)} #{node()}")

    if reason != :syn_conflict_resolution do
      Endpoint.local_broadcast("postgres_cdc:" <> name, "postgres_cdc_down", nil)
    end
  end

  def resolve_registry_conflict(mod, name, {pid1, %{region: region}, time1}, {pid2, _, time2}) do
    platform_region = Realtime.PostgresCdc.platform_region_translator(region)

    platform_region_nodes =
      RegionNodes
      |> :syn.members(platform_region)
      |> Enum.map(fn {_, [node: node]} -> node end)

    {keep, stop} =
      [pid1, pid2]
      |> Enum.filter(fn pid ->
        Enum.member?(platform_region_nodes, node(pid))
      end)
      |> then(fn
        [pid] ->
          {pid, if(pid != pid1, do: pid1, else: pid2)}

        _ ->
          if time1 < time2 do
            {pid1, pid2}
          else
            {pid2, pid1}
          end
      end)

    if node() == node(stop) do
      spawn(fn -> resolve_conflict(stop, name) end)
    else
      Logger.warn("Resolving #{name} conflict, remote pid: #{inspect(stop)}")
    end

    keep
  end

  defp resolve_conflict(stop, name) do
    resp =
      if Process.alive?(stop) do
        try do
          DynamicSupervisor.stop(stop, :shutdown, 30_000)
        catch
          error, reason -> {:error, {error, reason}}
        end
      else
        :not_alive
      end

    Endpoint.broadcast("postgres_cdc:" <> name, "postgres_cdc_down", nil)

    Logger.warn(
      "Resolving #{name} conflict, stop local pid: #{inspect(stop)}, response: #{inspect(resp)}"
    )
  end
end
