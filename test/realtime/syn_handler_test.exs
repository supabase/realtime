defmodule Realtime.SynHandlerTest do
  use Realtime.DataCase, async: false
  import ExUnit.CaptureLog
  alias Realtime.SynHandler
  alias Realtime.Tenants.Connect
  alias RealtimeWeb.Endpoint

  @mod SynHandler
  @name "test"
  @topic "syn_handler"

  @aux_mod (quote do
              defmodule FakeConnect do
                use GenServer

                def init([tenant_id, opts]) do
                  :syn.update_registry(Connect, tenant_id, fn _pid, meta -> %{meta | conn: "fake_conn"} end)

                  if opts[:trap_exit], do: Process.flag(:trap_exit, true)

                  {:ok, nil}
                end

                def handle_info(:shutdown_connect, state), do: {:stop, :normal, state}
                def handle_info(_, state), do: {:noreply, state}
              end
            end)

  Code.eval_quoted(@aux_mod)

  defp assert_process_down(pid, reason \\ nil, timeout \\ 100) do
    ref = Process.monitor(pid)

    if reason do
      assert_receive {:DOWN, ^ref, :process, ^pid, ^reason}, timeout
    else
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, timeout
    end
  end

  describe "integration test with a Connect conflict" do
    setup do
      ensure_connect_down("dev_tenant")
      {:ok, pid, node} = Clustered.start_disconnected(@aux_mod, extra_config: [{:realtime, :region, "ap-southeast-2"}])
      Endpoint.subscribe("connect:dev_tenant")
      %{peer_pid: pid, node: node}
    end

    test "local node started first", %{node: node, peer_pid: peer_pid} do
      external_id = "dev_tenant"
      # start connect locally first
      {:ok, db_conn} = Connect.lookup_or_start_connection(external_id)
      assert Connect.ready?(external_id)
      connect = Connect.whereis(external_id)
      assert node(connect) == node()

      # Now let's force the remote node to start the fake Connect process
      name = {Connect, external_id, %{conn: nil, region: "ap-southeast-2"}}
      opts = [name: {:via, :syn, name}]
      {:ok, remote_pid} = :peer.call(peer_pid, GenServer, :start_link, [FakeConnect, [external_id, []], opts])
      on_exit(fn -> Process.exit(remote_pid, :brutal_kill) end)

      log =
        capture_log(fn ->
          Endpoint.subscribe("connect:dev_tenant")
          # Connect to peer node to cause a conflict on syn
          true = Node.connect(node)
          # Give some time for the conflict resolution to happen on the other node
          Process.sleep(500)

          # Both nodes agree
          assert {^connect, %{region: "us-east-1", conn: ^db_conn}} = :syn.lookup(Connect, external_id)

          assert {^connect, %{region: "us-east-1", conn: ^db_conn}} =
                   :peer.call(peer_pid, :syn, :lookup, [Connect, external_id])

          refute :peer.call(peer_pid, Process, :alive?, [remote_pid])

          assert Process.alive?(connect)
        end)

      assert log =~ "remote process will be stopped: #{inspect(remote_pid)}"
    end

    test "remote node started first", %{node: node, peer_pid: peer_pid} do
      external_id = "dev_tenant"
      # Start remote process first
      name = {Connect, external_id, %{conn: nil, region: "ap-southeast-2"}}
      opts = [name: {:via, :syn, name}]
      {:ok, remote_pid} = :peer.call(peer_pid, GenServer, :start_link, [FakeConnect, [external_id, []], opts])
      on_exit(fn -> Process.exit(remote_pid, :kill) end)

      # start connect locally later
      {:ok, _db_conn} = Connect.lookup_or_start_connection(external_id)
      assert Connect.ready?(external_id)
      connect = Connect.whereis(external_id)
      assert node(connect) == node()

      log =
        capture_log(fn ->
          # Connect to peer node to cause a conflict on syn
          true = Node.connect(node)
          assert_process_down(connect)
          assert_receive %{event: "connect_down"}

          # Both nodes agree
          assert {^remote_pid, %{region: "ap-southeast-2", conn: "fake_conn"}} =
                   :peer.call(peer_pid, :syn, :lookup, [Connect, external_id])

          assert {^remote_pid, %{region: "ap-southeast-2", conn: "fake_conn"}} = :syn.lookup(Connect, external_id)

          assert :peer.call(peer_pid, Process, :alive?, [remote_pid])

          refute Process.alive?(connect)
        end)

      assert log =~ "stop local process: #{inspect(connect)}"
      assert log =~ "Successfully stopped #{inspect(connect)}"

      assert log =~
               "Elixir.Realtime.Tenants.Connect terminated due to syn conflict resolution: \"dev_tenant\" #{inspect(connect)}"
    end

    test "remote node started first but timed out stopping", %{node: node, peer_pid: peer_pid} do
      external_id = "dev_tenant"
      # Start remote process first
      name = {Connect, external_id, %{conn: nil, region: "ap-southeast-2"}}
      opts = [name: {:via, :syn, name}]
      {:ok, remote_pid} = :peer.call(peer_pid, GenServer, :start_link, [FakeConnect, [external_id, []], opts])
      on_exit(fn -> Process.exit(remote_pid, :brutal_kill) end)

      {:ok, local_pid} =
        start_supervised(%{
          id: self(),
          start: {GenServer, :start_link, [FakeConnect, [external_id, [trap_exit: true]], opts]}
        })

      log =
        capture_log(fn ->
          # Connect to peer node to cause a conflict on syn
          true = Node.connect(node)
          assert_process_down(local_pid, :killed, 6000)
          assert_receive %{event: "connect_down"}

          # Both nodes agree
          assert {^remote_pid, %{region: "ap-southeast-2", conn: "fake_conn"}} =
                   :peer.call(peer_pid, :syn, :lookup, [Connect, external_id])

          assert {^remote_pid, %{region: "ap-southeast-2", conn: "fake_conn"}} = :syn.lookup(Connect, external_id)

          assert :peer.call(peer_pid, Process, :alive?, [remote_pid])

          refute Process.alive?(local_pid)
        end)

      assert log =~ "stop local process: #{inspect(local_pid)}"
      assert log =~ "Timed out while waiting for process #{inspect(local_pid)} to stop. Sending kill exit signal"

      assert log =~
               "Elixir.Realtime.Tenants.Connect terminated due to syn conflict resolution: \"dev_tenant\" #{inspect(local_pid)}"
    end
  end

  describe "on_process_unregistered/5" do
    setup do
      RealtimeWeb.Endpoint.subscribe("#{@topic}:#{@name}")
    end

    test "it handles :syn_conflict_resolution reason" do
      reason = :syn_conflict_resolution
      pid = self()

      log =
        capture_log(fn ->
          assert SynHandler.on_process_unregistered(@mod, @name, pid, %{}, reason) == :ok
        end)

      topic = "#{@topic}:#{@name}"
      event = "#{@topic}_down"

      assert log =~ "#{@mod} terminated due to syn conflict resolution: #{inspect(@name)} #{inspect(self())}"
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: ^event, payload: %{reason: ^reason, pid: ^pid}}
    end

    test "it handles other reasons" do
      reason = :other_reason
      pid = self()

      log =
        capture_log(fn ->
          assert SynHandler.on_process_unregistered(@mod, @name, pid, %{}, reason) == :ok
        end)

      topic = "#{@topic}:#{@name}"
      event = "#{@topic}_down"

      refute log =~ "#{@mod} terminated: #{inspect(@name)} #{node()}"

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: ^topic,
                       event: ^event,
                       payload: %{reason: ^reason, pid: ^pid}
                     },
                     500
    end
  end
end
