defmodule Realtime.GenRpcMetrics do
  @moduledoc """
  Gather stats for gen_rpc TCP sockets
  """

  require Record
  Record.defrecordp(:net_address, Record.extract(:net_address, from_lib: "kernel/include/net_address.hrl"))

  @spec info() :: %{node() => %{inet_stats: %{:inet.stat_option() => integer}, queue_size: non_neg_integer()}}
  def info do
    if :net_kernel.get_state()[:started] != :no do
      {:ok, nodes_info} = :net_kernel.nodes_info()
      # All TCP client sockets are managed by this supervisor
      # For each node gen_rpc might have multiple TCP sockets
      # We collect them based on the address + TCP port combination (peername)
      port_addresses =
        Supervisor.which_children(:gen_rpc_client_sup)
        |> Stream.map(fn {_, pid, _, _} ->
          # We then grab the only linked port
          pid
          |> Process.info(:links)
          |> elem(1)
          |> Enum.filter(&is_port/1)
          |> hd()
        end)
        |> Stream.map(&{:inet.peername(&1), &1})
        |> Stream.filter(fn
          {{:ok, _peername}, _port} -> true
          _ -> false
        end)
        |> Stream.map(fn {{:ok, address}, port} -> {address, port} end)
        |> Enum.reduce(%{}, fn {address, port}, acc ->
          update_in(acc, [address], fn value -> [port | value || []] end)
        end)

      Map.new(nodes_info, &info(&1, port_addresses))
    else
      %{}
    end
  end

  defp info({node, info}, port_addresses) do
    {:tcp, tcp_port} = :gen_rpc_helper.get_client_config_per_node(node)

    case info[:address] do
      net_address(address: address) when address != :undefined ->
        {node, info(port_addresses, address, tcp_port)}

      _ ->
        {node, %{}}
    end
  end

  defp info(port_addresses, {address, _}, tcp_port) do
    if gen_rpc_ports = port_addresses[{address, tcp_port}] do
      %{
        inet_stats: inet_stats(gen_rpc_ports),
        queue_size: queue_size(gen_rpc_ports),
        connections: length(gen_rpc_ports)
      }
    else
      %{}
    end
  end

  defp inet_stats(ports) do
    Enum.reduce(ports, %{}, fn port, acc ->
      case :inet.getstat(port) do
        {:ok, stats} -> Map.merge(acc, Map.new(stats), fn _k, v1, v2 -> v1 + v2 end)
        _ -> acc
      end
    end)
  end

  defp queue_size(ports) do
    Enum.reduce(ports, 0, fn port, acc ->
      {:queue_size, queue_size} = :erlang.port_info(port, :queue_size)
      acc + queue_size
    end)
  end
end
