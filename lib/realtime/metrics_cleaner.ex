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

    {exec_time, _} = :timer.tc(fn -> loop_and_cleanup_metrics_table() end)

    if exec_time > :timer.seconds(5),
      do: Logger.warning("Metrics check took: #{exec_time} ms")

    {:noreply, %{state | check_ref: check(interval)}}
  end

  def handle_info(msg, state) do
    Logger.error("Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp check(interval) do
    Process.send_after(self(), :check, interval)
  end

  @table_name :"syn_registry_by_name_Elixir.Realtime.Tenants.Connect"
  @metrics_table Realtime.PromEx.Metrics
  @filter_spec [{{{:_, %{tenant: :"$1"}}, :_}, [], [:"$1"]}]
  @tenant_id_spec [{{:"$1", :_, :_, :_, :_, :_}, [], [:"$1"]}]
  defp loop_and_cleanup_metrics_table do
    tenant_ids = :ets.select(@table_name, @tenant_id_spec)

    :ets.select(@metrics_table, @filter_spec)
    |> Enum.uniq()
    |> Enum.reject(fn tenant_id -> tenant_id in tenant_ids end)
    |> Enum.each(fn tenant_id -> delete_metric(tenant_id) end)
  end

  @doc """
  Deletes all metrics that contain the given tenant or database_host.
  """
  @spec delete_metric(String.t()) :: :ok
  def delete_metric(tenant) do
    :ets.select_delete(@metrics_table, [
      {{{:_, %{tenant: tenant}}, :_}, [], [true]},
      {{{:_, %{database_host: "db.#{tenant}.supabase.co"}}, :_}, [], [true]}
    ])

    :ok
  end
end
