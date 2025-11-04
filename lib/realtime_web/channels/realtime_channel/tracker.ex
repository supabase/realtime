defmodule RealtimeWeb.RealtimeChannel.Tracker do
  @moduledoc """
  Tracks if the user has any channels open.

  Stores in :ets table the data.

  If the user has no channels open, we kill the transport pid.
  """
  use GenServer
  require Logger
  alias Realtime.Helpers

  defstruct [
    :no_channel_timeout_in_ms,
    :no_channel_timeout_ref,
    :egress_telemetry_interval_in_ms,
    :egress_telemetry_ref
  ]

  @table :channel_tracker
  @zero_count_match [{{{:"$1", :_}, :"$2"}, [{:"=<", :"$2", 0}], [:"$1"]}]
  @zero_count_delete [{{{:"$1", :_}, :"$2"}, [{:"=<", :"$2", 0}], [true]}]
  @egress_telemetry_match [{{{:"$1", :"$2"}, :"$3"}, [{:>, :"$3", 0}], [[:"$1", :"$2"]]}]

  @doc """
  Tracks a transport pid.
  """
  @spec track(pid(), binary()) :: integer()
  def track(pid, tenant_external_id),
    do: :ets.update_counter(@table, {pid, tenant_external_id}, 1, {{pid, tenant_external_id}, 0})

  @doc """
  Un-tracks a transport pid.
  """
  @spec untrack(pid(), binary()) :: integer()
  def untrack(pid, tenant_external_id),
    do: :ets.update_counter(@table, {pid, tenant_external_id}, -1, {{pid, tenant_external_id}, 0})

  @doc """
  Returns the number of channels open for a transport pid.
  """
  @spec count(pid(), binary()) :: integer()
  def count(pid, tenant_external_id) do
    case :ets.lookup(@table, {pid, tenant_external_id}) do
      [{{^pid, ^tenant_external_id}, count}] -> count
      [] -> 0
    end
  end

  @doc """
  Returns a list of all pids in the table and their count.
  """
  @spec list_pids() :: [{pid(), integer()}]
  def list_pids, do: :ets.tab2list(@table)

  def start_link(opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        {:decentralized_counters, true},
        {:write_concurrency, true}
      ])
    end

    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    no_channel_timeout_in_ms = Keyword.fetch!(opts, :no_channel_timeout_in_ms)
    no_channel_timeout_ref = Process.send_after(self(), :check_channels, no_channel_timeout_in_ms)
    egress_telemetry_interval_in_ms = Keyword.fetch!(opts, :egress_telemetry_interval_in_ms)
    egress_telemetry_ref = Process.send_after(self(), :send_egress_telemetry, egress_telemetry_interval_in_ms)

    {:ok,
     %{
       no_channel_timeout_in_ms: no_channel_timeout_in_ms,
       no_channel_timeout_ref: no_channel_timeout_ref,
       egress_telemetry_interval_in_ms: egress_telemetry_interval_in_ms,
       egress_telemetry_ref: egress_telemetry_ref
     }}
  end

  @impl true
  def handle_info(:check_channels, state) do
    %{no_channel_timeout_ref: no_channel_timeout_ref, no_channel_timeout_in_ms: no_channel_timeout_in_ms} = state
    chunked_killing()
    :ets.select_delete(@table, @zero_count_delete)
    Helpers.cancel_timer(no_channel_timeout_ref)
    no_channel_timeout_ref = Process.send_after(self(), :check_channels, no_channel_timeout_in_ms)
    {:noreply, %{state | no_channel_timeout_ref: no_channel_timeout_ref}}
  end

  def handle_info(:send_egress_telemetry, state) do
    %{egress_telemetry_ref: egress_telemetry_ref, egress_telemetry_interval_in_ms: egress_telemetry_interval_in_ms} =
      state

    Port.list()
    |> Enum.flat_map(fn port ->
      case Port.info(port, :links) do
        {:links, pids} -> Enum.map(pids, fn pid -> {pid, port} end)
        _ -> []
      end
    end)
    |> Enum.group_by(fn {pid, _} -> pid end, fn {_, port} -> port end)
    |> collect_egress_telemetry()
    |> Enum.each(fn {tenant_external_id, output_bytes} ->
      if output_bytes > 0 do
        :telemetry.execute([:realtime, :connections, :output_bytes], %{output_bytes: output_bytes}, %{
          tenant_external_id: tenant_external_id
        })
      end
    end)

    Helpers.cancel_timer(egress_telemetry_ref)
    egress_telemetry_ref = Process.send_after(self(), :send_egress_telemetry, egress_telemetry_interval_in_ms)
    {:noreply, %{state | egress_telemetry_ref: egress_telemetry_ref}}
  end

  defp chunked_killing(cont \\ nil) do
    result = if cont, do: :ets.select(cont), else: :ets.select(@table, @zero_count_match, 1000)

    case result do
      :"$end_of_table" ->
        :ok

      {pids, cont} ->
        Logger.info("Killing #{length(pids)} transport pids with no channels open")
        Enum.each(pids, fn pid -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
        chunked_killing(cont)
    end
  end

  defp collect_egress_telemetry(pid_and_port_list, cont \\ nil, acc \\ %{}) do
    result = if cont, do: :ets.select(cont), else: :ets.select(@table, @egress_telemetry_match, 1000)

    case result do
      :"$end_of_table" ->
        acc

      {pids, cont} ->
        acc =
          Enum.reduce(pids, acc, fn [pid, tenant_external_id], acc ->
            ports = Map.get(pid_and_port_list, pid, [])

            output_bytes =
              Enum.sum_by(ports, fn port ->
                case :inet.getstat(port, [:send_oct]) do
                  {:ok, stats} -> stats[:send_oct]
                  _ -> 0
                end
              end)

            {_, acc} =
              Map.get_and_update(acc, tenant_external_id, fn
                nil -> {output_bytes, output_bytes}
                output_bytes -> {output_bytes, output_bytes + output_bytes}
              end)

            acc
          end)

        collect_egress_telemetry(pid_and_port_list, cont, acc)
    end
  end

  def table_name, do: @table
end
