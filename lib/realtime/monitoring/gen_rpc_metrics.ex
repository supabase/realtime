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

      {client_port_addresses, server_port_addresses} =
        :erlang.ports()
        |> Stream.filter(fn port ->
          :erlang.port_info(port, :name) == {:name, ~c"tcp_inet"}
        end)
        |> Stream.map(&{:inet.peername(&1), :inet.sockname(&1), &1})
        |> Stream.filter(fn
          {{:ok, _peername}, {:ok, _sockname}, _port} -> true
          _ -> false
        end)
        |> Stream.map(fn {{:ok, peername}, {:ok, sockname}, port} ->
          {peername, sockname, port}
        end)
        |> Enum.reduce({%{}, %{}}, fn {peername, {sockname_ipaddress, server_port}, port}, {clients, servers} ->
          if server_port == gen_rpc_server_port do
            # We only store the ipaddress because the client port is randomly assigned
            {clients, update_in(servers, [sockname_ipaddress], fn value -> [port | value || []] end)}
          else
            {update_in(clients, [peername], fn value -> [port | value || []] end), servers}
          end
        end)

      Map.new(nodes_info, &info(&1, client_port_addresses, server_port_addresses))
    else
      %{}
    end
  end

  defp server_port() do
    if Application.fetch_env!(:gen_rpc, :default_client_driver) == :tcp do
      Application.fetch_env!(:gen_rpc, :tcp_server_port)
    else
      Application.fetch_env!(:gen_rpc, :ssl_server_port)
    end
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
    {_, client_tcp_port} = :gen_rpc_helper.get_client_config_per_node(node) |> dbg()

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
