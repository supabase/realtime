defmodule RealtimeWeb.SocketDisconnectTest do
  use ExUnit.Case
  import ExUnit.CaptureLog
  import Generators

  alias Phoenix.PubSub
  alias RealtimeWeb.SocketDisconnect

  @aux_mod (quote do
              defmodule DisconnectTestAux do
                alias RealtimeWeb.SocketDisconnect

                def generate_tenant_processes(tenant_external_id) do
                  tenant_pids =
                    for _ <- 1..10 do
                      pid = spawn(fn -> Process.sleep(:infinity) end)
                      SocketDisconnect.add(tenant_external_id, %Phoenix.Socket{transport_pid: pid})
                      pid
                    end

                  other_tenant_pids =
                    for _ <- 1..10 do
                      pid = spawn(fn -> Process.sleep(:infinity) end)
                      SocketDisconnect.add(Generators.random_string(), %Phoenix.Socket{transport_pid: pid})
                      pid
                    end

                  %{tenant: tenant_pids, other: other_tenant_pids}
                end
              end
            end)

  Code.eval_quoted(@aux_mod)

  describe "add/2" do
    test "successfully registers a socket with the tenant's external_id" do
      tenant_external_id = random_string()
      pid = spawn(fn -> Process.sleep(:infinity) end)
      socket = %Phoenix.Socket{transport_pid: pid}

      assert :ok = SocketDisconnect.add(tenant_external_id, socket)
      # Verify that the socket is registered in the registry

      assert [{_, ^pid}] = Registry.lookup(RealtimeWeb.SocketDisconnect.Registry, tenant_external_id)
    end

    test "successfully registers multiple entries repeatedly without collision" do
      tenant_external_id = random_string()

      transport_pid = spawn(fn -> Process.sleep(:infinity) end)
      socket = %Phoenix.Socket{transport_pid: transport_pid}

      assert :ok = SocketDisconnect.add(tenant_external_id, socket)
      assert :ok = SocketDisconnect.add(tenant_external_id, socket)
      assert :ok = SocketDisconnect.add(tenant_external_id, socket)

      assert result = Registry.lookup(RealtimeWeb.SocketDisconnect.Registry, tenant_external_id)
      assert length(result) == 1
      assert [{_, ^transport_pid}] = result
      assert Process.alive?(transport_pid)
    end

    test "successfully registers multiple entries from different pids without collision" do
      tenant_external_id = random_string()

      for _ <- 1..10 do
        pid = spawn(fn -> Process.sleep(:infinity) end)
        socket = %Phoenix.Socket{transport_pid: pid}
        assert :ok = SocketDisconnect.add(tenant_external_id, socket)
        assert :ok = SocketDisconnect.add(tenant_external_id, socket)
        assert :ok = SocketDisconnect.add(tenant_external_id, socket)

        pid
      end

      # Verify that only one entry is registered
      result = Registry.lookup(RealtimeWeb.SocketDisconnect.Registry, tenant_external_id)
      assert length(result) == 10
      for {_, pid} <- result, do: assert(Process.alive?(pid))
    end
  end

  describe "disconnect/1" do
    test "successfully disconnects all sockets associated with a given tenant on the current node" do
      tenant_external_id = random_string()
      %{tenant: tenant_pids, other: other_pids} = DisconnectTestAux.generate_tenant_processes(tenant_external_id)

      # Ensure all processes are alive before disconnecting
      for pid <- tenant_pids, do: assert(Process.alive?(pid))
      for pid <- other_pids, do: assert(Process.alive?(pid))

      # Perform the disconnect
      assert :ok = SocketDisconnect.disconnect(tenant_external_id)

      # Verify that tenant processes are killed and other processes remain alive
      for pid <- tenant_pids, do: refute(Process.alive?(pid))
      for pid <- other_pids, do: assert(Process.alive?(pid))
    end

    test "after disconnect, pid is unregistered" do
      tenant_external_id = random_string()
      PubSub.subscribe(Realtime.PubSub, "realtime:operations:" <> tenant_external_id)
      %{tenant: tenant_pids, other: other_pids} = DisconnectTestAux.generate_tenant_processes(tenant_external_id)

      # Ensure all processes are alive before disconnecting
      for pid <- tenant_pids, do: assert(Process.alive?(pid))
      for pid <- other_pids, do: assert(Process.alive?(pid))

      # Perform the disconnect
      log =
        capture_log(fn ->
          assert :ok = SocketDisconnect.disconnect(tenant_external_id)
        end)

      assert_received :disconnect
      Process.sleep(200)
      assert [] = Registry.lookup(RealtimeWeb.SocketDisconnect.Registry, tenant_external_id)
      assert log =~ "Disconnecting all sockets for tenant #{tenant_external_id}"
    end
  end

  describe "distributed_disconnect/1" do
    setup do
      {:ok, node} = Clustered.start(@aux_mod)
      %{node: node}
    end

    test "successfully kills all processes associated with a given tenant and non others" do
      tenant_external_id = random_string()
      # Generate fake processes for the tenant and other tenants
      %{tenant: tenant_pids, other: other_pids} = DisconnectTestAux.generate_tenant_processes(tenant_external_id)

      %{tenant: remote_tenant_pids, other: remote_other_pids} =
        :erpc.call(Node.self(), DisconnectTestAux, :generate_tenant_processes, [tenant_external_id])

      # Ensure all processes are alive before disconnecting
      for pid <- tenant_pids ++ remote_tenant_pids, do: assert(Process.alive?(pid))
      for pid <- other_pids ++ remote_other_pids, do: assert(Process.alive?(pid))

      # Perform the distributed disconnect
      assert [:ok, :ok] = SocketDisconnect.distributed_disconnect(tenant_external_id)

      # Verify that tenant processes are killed and other processes remain alive
      for pid <- tenant_pids ++ remote_tenant_pids, do: refute(Process.alive?(pid))
      for pid <- other_pids ++ remote_other_pids, do: assert(Process.alive?(pid))
    end
  end

  test "on registered pid dead, Registry cleans up" do
    tenant_external_id = random_string()

    pid =
      spawn(fn ->
        pid = spawn(fn -> Process.sleep(:infinity) end)
        socket = %Phoenix.Socket{transport_pid: pid}
        assert :ok = SocketDisconnect.add(tenant_external_id, socket)

        assert [^pid] = Registry.lookup(RealtimeWeb.SocketDisconnect.Registry, tenant_external_id)
      end)

    Process.sleep(100)
    refute Process.alive?(pid)
    assert [] = Registry.lookup(RealtimeWeb.SocketDisconnect.Registry, tenant_external_id)
  end
end
