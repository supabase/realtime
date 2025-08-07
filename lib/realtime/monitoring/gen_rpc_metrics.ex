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
      # Ignore "hidden" nodes (remote shell)
      nodes_info = Enum.filter(nodes_info, fn {_k, v} -> v[:type] == :normal end)

      # All TCP server sockets are managed by gen_rpc_acceptor_sup supervisor
      # All TCP client sockets are managed by gen_rpc_client_sup supervisor
      # For each node gen_rpc might have multiple TCP sockets

      # For client processes we use the remote address (peername)
      client_port_addresses =
        port_addresses(:gen_rpc_client_sup)
        |> Enum.reduce(%{}, fn {address, port}, acc ->
          update_in(acc, [address], fn value -> [port | value || []] end)
        end)

      # For server processes we use the ip address without the tcp port because it's randomly assigned
      server_port_addresses =
        port_addresses(:gen_rpc_acceptor_sup)
        |> Enum.reduce(%{}, fn {{ip_address, _tcp_port}, port}, acc ->
          update_in(acc, [ip_address], fn value -> [port | value || []] end)
        end)

      Map.new(nodes_info, &info(&1, client_port_addresses, server_port_addresses))
    else
      %{}
    end
  end

  defp port_addresses(supervisor) do
    Supervisor.which_children(supervisor)
    |> Stream.flat_map(fn {_, pid, _, _} ->
      # We then grab the only linked port if available
      case Process.info(pid, :links) do
        {:links, links} ->
          links
          |> Enum.filter(&is_port/1)
          |> hd()
          |> List.wrap()

        _ ->
          []
      end
    end)
    |> Stream.map(&{:inet.peername(&1), &1})
    |> Stream.filter(fn
      {{:ok, _sockname}, _port} -> true
      _ -> false
    end)
    |> Stream.map(fn {{:ok, address}, port} -> {address, port} end)
  end

  defp info({node, info}, client_port_addresses, server_port_addresses) do
    case info[:address] do
      net_address(address: address) when address != :undefined ->
        {node, info(node, client_port_addresses, server_port_addresses, address)}

      _ ->
        {node, %{}}
    end
  end

  defp info(node, client_port_addresses, server_port_addresses, {ip_address, _}) do
    {:tcp, client_tcp_port} = :gen_rpc_helper.get_client_config_per_node(node)

    gen_rpc_client_ports = Map.get(client_port_addresses, {ip_address, client_tcp_port}, [])
    gen_rpc_server_ports = Map.get(server_port_addresses, ip_address, [])
    gen_rpc_ports = gen_rpc_client_ports ++ gen_rpc_server_ports

    if gen_rpc_ports != [] do
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
