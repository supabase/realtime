defmodule Extensions.PostgresCdcRls.SynHandler do
  @moduledoc """
  Custom defined Syn's callbacks
  """
  require Logger
  alias RealtimeWeb.Endpoint

  def on_process_unregistered(Extensions.PostgresCdcRls, name, _pid, _meta, reason) do
    Logger.info("PostgresCdcRls terminated: #{inspect(name)} #{node()}")

    broadcast_method =
      if reason == :syn_conflict_resolution do
        :broadcast
      else
        :local_broadcast
      end

    apply(Endpoint, broadcast_method, ["postgres_cdc:" <> name, "postgres_cdc_down", nil])
  end

  def resolve_registry_conflict(
        Extensions.PostgresCdcRls,
        name,
        {pid1, %{region: region}, time1},
        {pid2, _, time2}
      ) do
    fly_region = Realtime.PostgresCdc.aws_to_fly(region)

    fly_region_nodes =
      :syn.members(RegionNodes, fly_region)
      |> Enum.map(fn {_, [node: node]} -> node end)

    {keep, stop} =
      Enum.filter([pid1, pid2], fn pid ->
        Enum.member?(fly_region_nodes, node(pid))
      end)
      |> case do
        [pid] ->
          {pid, if(pid != pid1, do: pid1, else: pid2)}

        _ ->
          if time1 < time2 do
            {pid1, pid2}
          else
            {pid2, pid1}
          end
      end

    if node() == node(stop) do
      resp =
        if Process.alive?(stop) do
          DynamicSupervisor.stop(stop, :shutdown, 4_000)
        else
          :not_alive
        end

      "Resolving #{name} conflict, stop local pid: #{inspect(stop)}, response: #{inspect(resp)}"
    else
      "Resolving #{name} conflict, remote pid: #{inspect(stop)}"
    end
    |> Logger.warn()

    keep
  end
end
