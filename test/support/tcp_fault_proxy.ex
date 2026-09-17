defmodule TcpFaultProxy do
  @moduledoc """
  Test-owned TCP forwarding endpoint. Disconnects client sockets without relying
  on physical Postgres backend PIDs, which a database pooler can hide or replace.
  """
  use GenServer

  def start_link(target), do: GenServer.start_link(__MODULE__, target)
  def port(proxy), do: GenServer.call(proxy, :port)
  def disconnect(proxy), do: GenServer.call(proxy, :disconnect, 10_000)

  def init({host, port}) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, {_, local_port}} = :inet.sockname(listener)
    owner = self()
    acceptor = spawn_link(fn -> accept(listener, owner, host, port) end)
    {:ok, %{listener: listener, port: local_port, acceptor: acceptor, relays: MapSet.new()}}
  end

  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call(:disconnect, _from, state) do
    Enum.each(state.relays, &send(&1, :disconnect))

    Enum.each(state.relays, fn pid ->
      receive do
        {:DOWN, _, :process, ^pid, _} -> :ok
      after
        5_000 -> raise "TCP relay did not disconnect"
      end
    end)

    {:reply, :ok, %{state | relays: MapSet.new()}}
  end

  def handle_info({:relay, pid}, state) do
    Process.monitor(pid)
    {:noreply, %{state | relays: MapSet.put(state.relays, pid)}}
  end

  def handle_info({:DOWN, _, :process, pid, _}, state),
    do: {:noreply, %{state | relays: MapSet.delete(state.relays, pid)}}

  def terminate(_, state) do
    :gen_tcp.close(state.listener)
    Enum.each(state.relays, &send(&1, :disconnect))
    Process.exit(state.acceptor, :shutdown)
  end

  defp accept(listener, owner, host, port) do
    case :gen_tcp.accept(listener) do
      {:ok, client} ->
        relay =
          spawn(fn ->
            Process.monitor(owner)

            receive do
              :start -> forward(client, host, port)
            end
          end)

        :ok = :gen_tcp.controlling_process(client, relay)
        send(owner, {:relay, relay})
        send(relay, :start)
        accept(listener, owner, host, port)

      {:error, :closed} ->
        :ok
    end
  end

  defp forward(client, host, port) do
    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 5_000) do
      {:ok, server} ->
        :inet.setopts(client, active: :once)
        :inet.setopts(server, active: :once)

        try do
          relay(client, server)
        after
          :gen_tcp.close(client)
          :gen_tcp.close(server)
        end

      {:error, _} ->
        :gen_tcp.close(client)
    end
  end

  defp relay(client, server) do
    receive do
      {:tcp, ^client, bytes} ->
        case :gen_tcp.send(server, bytes) do
          :ok ->
            :inet.setopts(client, active: :once)
            relay(client, server)

          _ ->
            :ok
        end

      {:tcp, ^server, bytes} ->
        case :gen_tcp.send(client, bytes) do
          :ok ->
            :inet.setopts(server, active: :once)
            relay(client, server)

          _ ->
            :ok
        end

      {:tcp_closed, _} ->
        :ok

      {:tcp_error, _, _} ->
        :ok

      :disconnect ->
        :ok

      {:DOWN, _, :process, _, _} ->
        :ok
    end
  end
end
