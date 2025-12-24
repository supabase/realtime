defmodule Realtime.MetricsCleaner do
  @moduledoc false

  use GenServer
  require Logger

  defstruct [:check_ref, :interval]

  def handle_event([:beacon, :users, :group, :vacant], _measurements, %{group: tenant_id}, cleaner_table) do
    :ets.insert(cleaner_table, {tenant_id, DateTime.to_unix(DateTime.utc_now(), :second)})
  end

  def handle_event([:beacon, :users, :group, :occupied], _measurements, %{group: tenant_id}, cleaner_table) do
    :ets.delete(cleaner_table, tenant_id)
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  # 5 minutes
  @default_vacant_metric_threshold_in_seconds 300

  @impl true
  def init(opts) do
    interval =
      opts[:metrics_cleaner_schedule_timer_in_ms] ||
        Application.fetch_env!(:realtime, :metrics_cleaner_schedule_timer_in_ms)

    vacant_metric_threshold_in_seconds =
      opts[:vacant_metric_threshold_in_seconds] || @default_vacant_metric_threshold_in_seconds

    Logger.info("Starting MetricsCleaner")

    tid = :ets.new(:metrics_cleaner, [:set, :public, read_concurrency: false, write_concurrency: :auto])

    :ok =
      :telemetry.attach_many(
        self(),
        [[:beacon, :users, :group, :occupied], [:beacon, :users, :group, :vacant]],
        &__MODULE__.handle_event/4,
        tid
      )

    {:ok,
     %{
       check_ref: check(interval),
       interval: interval,
       vacant_metric_threshold_in_seconds: vacant_metric_threshold_in_seconds,
       tid: tid
     }}
  end

  @impl true
  def handle_info(:check, %{interval: interval} = state) do
    Process.cancel_timer(state.check_ref)

    {exec_time, _} =
      :timer.tc(
        fn -> loop_and_cleanup_metrics_table(state.tid, state.vacant_metric_threshold_in_seconds) end,
        :millisecond
      )

    if exec_time > :timer.seconds(5),
      do: Logger.warning("Metrics check took: #{exec_time} ms")

    {:noreply, %{state | check_ref: check(interval)}}
  end

  def handle_info(msg, state) do
    Logger.error("Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp check(interval), do: Process.send_after(self(), :check, interval)

  defp loop_and_cleanup_metrics_table(cleaner_table, vacant_metric_cleanup_threshold_in_seconds) do
    threshold =
      DateTime.utc_now()
      |> DateTime.add(-vacant_metric_cleanup_threshold_in_seconds, :second)
      |> DateTime.to_unix(:second)

    # We do this to have a consistent view of the table while we read and delete
    :ets.safe_fixtable(cleaner_table, true)

    try do
      # Look for tenant_ids that have been vacant for more than threshold
      vacant_tenant_ids =
        :ets.select(cleaner_table, [
          {{:"$1", :"$2"}, [{:<, :"$2", threshold}], [:"$1"]}
        ])

      vacant_tenant_ids
      |> Enum.map(fn tenant_id -> %{tenant: tenant_id} end)
      |> then(&Peep.prune_tags(Realtime.PromEx.Metrics, &1))

      # Delete them from the table
      :ets.select_delete(cleaner_table, [
        {{:"$1", :"$2"}, [{:<, :"$2", threshold}], [true]}
      ])
    after
      :ets.safe_fixtable(cleaner_table, false)
    end
  end
end
