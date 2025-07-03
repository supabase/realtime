defmodule Realtime.SynHandlerTest do
  use Realtime.DataCase, async: false
  import ExUnit.CaptureLog
  alias Realtime.SynHandler
  alias Realtime.Tenants.Connect

  @mod SynHandler
  @name "test"
  @topic "syn_handler"

  describe "integration test with a Connect conflict" do
    setup do
      {:ok, pid, node} = Clustered.start_disconnected()
      %{peer_pid: pid, node: node}
    end

    test "it resolves a Connect conflict", %{node: node, peer_pid: peer_pid} do
      external_id = "dev_tenant"
      # start connect locally first
      {:ok, db_conn} = Connect.connect(external_id)
      assert Connect.ready?(external_id)
      current_metadata = :syn.lookup(Connect, external_id)
      connect = Connect.whereis(external_id)
      assert node(connect) == node()

      # Now let's force the remote node to start the same Connect process

      log =
        capture_log(fn ->
          {:ok, remote_db_conn} = :peer.call(peer_pid, Connect, :connect, [external_id])
          assert :peer.call(peer_pid, Connect, :ready?, [external_id]) == true
          # assert remote_db_conn != db_conn
          Node.connect(node)
          # Give some time for the conflict resolution to happen
          Process.sleep(2000)
        end)

      assert ^current_metadata = :syn.lookup(Connect, external_id)

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
