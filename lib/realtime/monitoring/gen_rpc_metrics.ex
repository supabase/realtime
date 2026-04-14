defmodule Realtime.GenRpcMetrics do
  @moduledoc """
  Gather stats for gen_rpc TCP sockets.

  Tracks per-port snapshots to emit monotonically increasing deltas for byte/packet counters,
  avoiding false metric decreases in Prometheus when TCP connections restart.
  """

  use GenServer

  require Record
  Record.defrecordp(:net_address, Record.extract(:net_address, from_lib: "kernel/include/net_address.hrl"))

  @counter_fields [:recv_oct, :recv_cnt, :send_oct, :send_cnt]
  @zero_counters Map.new(@counter_fields, &{&1, 0})

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{last_port_stats: %{}}, name: __MODULE__)
  end

  @spec info() :: %{
          node() => %{
            inet_stats: %{:inet.stat_option() => integer()},
            queue_size: non_neg_integer(),
            connections: non_neg_integer(),
            deltas: %{atom() => non_neg_integer()}
          }
        }
  def info do
    GenServer.call(__MODULE__, :info)
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call(:info, _from, %{last_port_stats: last_port_stats} = state) do
    if :net_kernel.get_state()[:started] != :no do
      {:ok, nodes_info} = :net_kernel.nodes_info()
      nodes_info = Enum.filter(nodes_info, fn {_k, v} -> v[:type] == :normal end)
      gen_rpc_server_port = server_port()
      ip_address_node = ip_address_node(nodes_info)

      {client_ports, server_ports} = collect_ports(ip_address_node, gen_rpc_server_port)

      {result, new_last_port_stats} =
        Enum.reduce(nodes_info, {%{}, %{}}, fn {node, _}, {result_acc, snapshot_acc} ->
          gen_rpc_ports = Map.get(client_ports, node, []) ++ Map.get(server_ports, node, [])

          if gen_rpc_ports == [] do
            {Map.put(result_acc, node, %{}), snapshot_acc}
          else
            current_snapshot = port_snapshot(gen_rpc_ports)
            prev_snapshot = Map.get(last_port_stats, node, %{})

            node_info = %{
              inet_stats: aggregate_from_snapshot(current_snapshot),
              queue_size: queue_size(gen_rpc_ports),
              connections: length(gen_rpc_ports),
              deltas: compute_deltas(current_snapshot, prev_snapshot)
            }

            {Map.put(result_acc, node, node_info), Map.put(snapshot_acc, node, current_snapshot)}
          end
        end)

      {:reply, result, %{state | last_port_stats: new_last_port_stats}}
    else
      {:reply, %{}, state}
    end
  end

  # Build a map of %{port => %{stat => value}} for all counter fields plus full stats.
  defp port_snapshot(ports) do
    Map.new(ports, fn port ->
      case :inet.getstat(port) do
        {:ok, stats} -> {port, Map.new(stats)}
        _ -> {port, @zero_counters}
      end
    end)
  end

  # Aggregate all port stats into a single map for gauge reporting.
  defp aggregate_from_snapshot(snapshot) do
    Enum.reduce(snapshot, %{}, fn {_port, stats}, acc ->
      Map.merge(acc, stats, fn _k, v1, v2 -> v1 + v2 end)
    end)
  end

  # Compute per-node deltas for counter fields only.
  # New ports contribute their full current value; existing ports contribute the increase.
  # Ports that disappeared between polls contribute 0 (data lost between last poll and close).
  defp compute_deltas(current_snapshot, prev_snapshot) do
    Enum.reduce(current_snapshot, @zero_counters, fn {port, curr_stats}, acc ->
      prev_stats = Map.get(prev_snapshot, port, @zero_counters)

      Enum.reduce(@counter_fields, acc, fn field, field_acc ->
        delta = max(0, Map.get(curr_stats, field, 0) - Map.get(prev_stats, field, 0))
        Map.update!(field_acc, field, &(&1 + delta))
      end)
    end)
  end

  defp collect_ports(ip_address_node, gen_rpc_server_port) do
    :erlang.ports()
    |> Stream.filter(fn port -> :erlang.port_info(port, :name) == {:name, ~c"tcp_inet"} end)
    |> Stream.map(&{:inet.peername(&1), :inet.sockname(&1), &1})
    |> Stream.filter(fn
      {{:ok, _peername}, {:ok, _sockname}, _port} -> true
      _ -> false
    end)
    |> Stream.map(fn {{:ok, {peername_ipaddress, peername_port}}, {:ok, {_, server_port}}, port} ->
      {ip_address_node[peername_ipaddress], peername_port, server_port, port}
    end)
    |> Stream.filter(fn
      {nil, _, _, _} ->
        false

      {node, peername_port, server_port, _port} ->
        {_, client_tcp_or_ssl_port} = :gen_rpc_helper.get_client_config_per_node(node)
        peername_port == client_tcp_or_ssl_port or server_port == gen_rpc_server_port
    end)
    |> Enum.reduce({%{}, %{}}, fn {node, _peername_port, server_port, port}, {clients, servers} ->
      if server_port == gen_rpc_server_port do
        {clients, update_in(servers, [node], fn value -> [port | value || []] end)}
      else
        {update_in(clients, [node], fn value -> [port | value || []] end), servers}
      end
    end)
  end

  defp queue_size(ports) do
    Enum.reduce(ports, 0, fn port, acc ->
      {:queue_size, queue_size} = :erlang.port_info(port, :queue_size)
      acc + queue_size
    end)
  end

  defp server_port() do
    if Application.fetch_env!(:gen_rpc, :default_client_driver) == :tcp do
      Application.fetch_env!(:gen_rpc, :tcp_server_port)
    else
      Application.fetch_env!(:gen_rpc, :ssl_server_port)
    end
  end

  defp ip_address_node(nodes_info) do
    nodes_info
    |> Stream.map(fn {node, info} ->
      case info[:address] do
        net_address(address: {ip_address, _}) ->
          {ip_address, node}

        _ ->
          {nil, node}
      end
    end)
    |> Stream.filter(fn {ip_address, _node} -> ip_address != nil end)
    |> Map.new()
  end
end
