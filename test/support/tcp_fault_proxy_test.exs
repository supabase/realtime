defmodule TcpFaultProxyTest do
  use ExUnit.Case, async: true

  test "forwards bytes, closes existing clients, and accepts a replacement connection" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    server =
      Task.async(fn ->
        for _ <- 1..2 do
          {:ok, socket} = :gen_tcp.accept(listener)
          {:ok, bytes} = :gen_tcp.recv(socket, 0, 5_000)
          :ok = :gen_tcp.send(socket, bytes)
          assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5_000)
        end
      end)

    proxy = start_supervised!({TcpFaultProxy, {"127.0.0.1", port}})

    for payload <- ["first", "replacement"] do
      {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, TcpFaultProxy.port(proxy), [:binary, active: false])
      :ok = :gen_tcp.send(client, payload)
      assert {:ok, ^payload} = :gen_tcp.recv(client, 0, 5_000)
      assert :ok = TcpFaultProxy.disconnect(proxy)
      assert {:error, :closed} = :gen_tcp.recv(client, 0, 5_000)
    end

    Task.await(server)
  end
end
