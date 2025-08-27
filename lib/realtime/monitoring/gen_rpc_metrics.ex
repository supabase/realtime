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
      gen_rpc_server_port = server_port()
      ip_address_node = ip_address_node(nodes_info)

      {client_ports, server_ports} =
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
          {nil, _, _} ->
            false

          {node, peername_port, server_port, _port} ->
            {_, client_tcp_or_ssl_port} = :gen_rpc_helper.get_client_config_per_node(node)
            # Only keep Erlang ports that are either serving on the gen_rpc server tcp/ssl port or
            # connecting to other nodes using the expected client tcp/ssl port for that node
            peername_port == client_tcp_or_ssl_port or server_port == gen_rpc_server_port
        end)
        |> Enum.reduce({%{}, %{}}, fn {node, _peername_port, server_port, port}, {clients, servers} ->
          if server_port == gen_rpc_server_port do
            # This Erlang port is serving gen_rpc
            {clients, update_in(servers, [node], fn value -> [port | value || []] end)}
          else
            # This Erlang port is requesting gen_rpc
            {update_in(clients, [node], fn value -> [port | value || []] end), servers}
          end
        end)

      Map.new(nodes_info, &info(&1, client_ports, server_ports))
    else
      %{}
    end
  end

  defp info({node, _}, client_ports, server_ports) do
    gen_rpc_ports = Map.get(client_ports, node, []) ++ Map.get(server_ports, node, [])

    if gen_rpc_ports != [] do
      {node,
       %{
         inet_stats: inet_stats(gen_rpc_ports),
         queue_size: queue_size(gen_rpc_ports),
         connections: length(gen_rpc_ports)
       }}
    else
      {node, %{}}
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
