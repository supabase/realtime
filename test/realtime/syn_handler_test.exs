defmodule Realtime.SynHandlerTest do
  use Realtime.DataCase, async: false
  import ExUnit.CaptureLog
  alias Realtime.SynHandler
  alias Realtime.Tenants.Connect

  @mod SynHandler
  @name "test"
  @topic "syn_handler"

  @aux_mod (quote do
              defmodule FakeConnect do
                use GenServer

                def init(tenant_id) do
                  :syn.update_registry(Connect, tenant_id, fn _pid, meta -> %{meta | conn: "fake_conn"} end)
                  {:ok, nil}
                end
              end
            end)

  Code.eval_quoted(@aux_mod)

  defp assert_process_down(pid, timeout \\ 100) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, timeout
  end

  describe "integration test with a Connect conflict" do
    setup do
      {:ok, pid, node} = Clustered.start_disconnected(@aux_mod, extra_config: [{:realtime, :region, "ap-southeast-2"}])
      %{peer_pid: pid, node: node}
    end

    test "it resolves a Connect conflict", %{node: node, peer_pid: peer_pid} do
      external_id = "dev_tenant"
      dbg(external_id)
      # start connect locally first
      {:ok, db_conn} = Connect.lookup_or_start_connection(external_id)
      assert Connect.ready?(external_id)
      current_metadata = :syn.lookup(Connect, external_id)
      connect = Connect.whereis(external_id)
      assert node(connect) == node()

      # Now let's force the remote node to start the fake Connect process

      # log =
      #   capture_log(fn ->
      name = {Connect, external_id, %{conn: nil, region: "ap-southeast-2"}}
      opts = [name: {:via, :syn, name}]
      {:ok, remote_pid} = :peer.call(peer_pid, GenServer, :start_link, [FakeConnect, external_id, opts])
      Node.connect(node)
      # Give some time for the conflict resolution to happen
      # assert_process_down(remote_pid, 500)
      # Let's wait for any logs from remote to arrive
      Process.sleep(500)
      # end)

      :syn.lookup(Connect, external_id) |> dbg()
      :peer.call(peer_pid, :syn, :lookup, [Connect, external_id]) |> dbg()

      :peer.call(peer_pid, Process, :alive?, [remote_pid]) |> dbg()
      Process.alive?(db_conn) |> dbg()

      :"syn_registry_by_name_Elixir.Realtime.Tenants.Connect"
      |> :ets.tab2list()
      |> dbg()

      # assert log =~ "Connect terminated"
    end
  end

  describe "on_process_unregistered/5" do
    setup do
      RealtimeWeb.Endpoint.subscribe("#{@topic}:#{@name}")
    end

    test "it handles :syn_conflict_resolution reason" do
      reason = :syn_conflict_resolution

      log =
        capture_log(fn ->
          assert SynHandler.on_process_unregistered(@mod, @name, self(), %{region: "us-east-1"}, reason) == :ok
        end)

      topic = "#{@topic}:#{@name}"
      event = "#{@topic}_down"

      assert log =~ "#{@mod} terminated: #{inspect(@name)} #{node()}"
      refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: ^event, payload: nil}
    end

    test "it handles :syn_conflict_resolution reason without region" do
      reason = :syn_conflict_resolution

      log =
        capture_log(fn ->
          assert SynHandler.on_process_unregistered(@mod, @name, self(), %{}, reason) == :ok
        end)

      topic = "#{@topic}:#{@name}"
      event = "#{@topic}_down"

      assert log =~ "#{@mod} terminated: #{inspect(@name)} #{node()}"
      refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: ^event, payload: nil}
    end

    test "it handles other reasons" do
      reason = :other_reason

      log =
        capture_log(fn ->
          assert SynHandler.on_process_unregistered(@mod, @name, self(), %{}, reason) == :ok
        end)

      topic = "#{@topic}:#{@name}"
      event = "#{@topic}_down"

      refute log =~ "#{@mod} terminated: #{inspect(@name)} #{node()}"
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: ^event, payload: nil}, 500
    end
  end

  describe "resolve_registry_conflict/4" do
    test "returns the correct pid to keep" do
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      time1 = System.monotonic_time()

      pid2 = spawn(fn -> Process.sleep(:infinity) end)
      time2 = System.monotonic_time()

      assert pid1 ==
               SynHandler.resolve_registry_conflict(
                 __MODULE__,
                 Generators.random_string(),
                 {pid1, %{}, time1},
                 {pid2, %{}, time2}
               )
    end
  end
end
