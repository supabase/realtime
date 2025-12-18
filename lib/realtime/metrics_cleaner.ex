defmodule Realtime.MetricsCleaner do
  @moduledoc false

  use GenServer
  require Logger

  defstruct [:check_ref, :interval]

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  def init(_args) do
    interval = Application.get_env(:realtime, :metrics_cleaner_schedule_timer_in_ms)

    Logger.info("Starting MetricsCleaner")
    {:ok, %{check_ref: check(interval), interval: interval}}
  end

  def handle_info(:check, %{interval: interval} = state) do
    Process.cancel_timer(state.check_ref)

    {exec_time, _} = :timer.tc(fn -> loop_and_cleanup_metrics_table() end, :millisecond)

    if exec_time > :timer.seconds(5),
      do: Logger.warning("Metrics check took: #{exec_time} ms")

    {:noreply, %{state | check_ref: check(interval)}}
  end

  def handle_info(msg, state) do
    Logger.error("Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp check(interval), do: Process.send_after(self(), :check, interval)

  @peep_filter_spec [{{{:_, %{tenant: :"$1"}}, :_}, [{:is_binary, :"$1"}], [:"$1"]}]

  defp loop_and_cleanup_metrics_table do
    tenant_ids = Realtime.Tenants.Connect.list_tenants() |> MapSet.new()

    {_, {tid, _}} = Peep.Persistent.storage(Realtime.PromEx.Metrics)

    tid
    |> :ets.select(@peep_filter_spec)
    |> Enum.uniq()
    |> Stream.reject(fn tenant_id -> MapSet.member?(tenant_ids, tenant_id) end)
    |> Enum.map(fn tenant_id -> %{tenant: tenant_id} end)
    |> then(&Peep.prune_tags(Realtime.PromEx.Metrics, &1))
  end
end
