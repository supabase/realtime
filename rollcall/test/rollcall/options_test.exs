defmodule Rollcall.OptionsTest do
  # The library has fixed process names, so one instance runs in the VM. The
  # test helper starts the default instance under `Rollcall.TestSupervisor`.
  # A test that needs options replaces that instance. These tests cannot run
  # concurrently with other tests.
  use Rollcall.Case, async: false

  import Rollcall.NetworkHelpers
  import Rollcall.Tracker.Messages, only: [snapshot: 3, stamp: 2]

  alias Rollcall.Tracker
  alias Rollcall.Transport.InMemory

  @probe :probe@host

  describe "transport" do
    test "gives the transport to a tracker that track/5 starts", %{scope: scope} do
      network = start_network()
      start_library(transport: in_memory(network))
      probe = join_probe(network, scope, @probe)

      {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key", %{})
      tracker = Tracker.whereis(scope)
      # The goodbye is the first message that a stopped tracker sends.
      :ok = GenServer.stop(tracker)

      assert {:snapshot, _origin, _stamp, []} = receive_message(probe)
    end
  end

  describe "heartbeat_period_in_ms" do
    test "gives the period to a tracker that track/5 starts", %{scope: scope} do
      network = start_network()
      start_library(transport: in_memory(network), heartbeat_period_in_ms: 20)
      probe = join_probe(network, scope, @probe)

      {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key", %{})

      # The default period is 1500 ms. A tick inside 500 ms shows that the option is in use.
      assert {:snapshot, _origin, _stamp, _entries} = receive_message(probe, 500)
    end
  end

  describe "silence_threshold" do
    test "gives the threshold to a tracker that track/5 starts", %{scope: scope} do
      network = start_network()
      start_library(transport: in_memory(network), heartbeat_period_in_ms: :manual, silence_threshold: 2)
      probe = join_probe(network, scope, @probe)

      {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key", %{})
      tracker = Tracker.whereis(scope)
      send_from_probe(probe, snapshot(self(), stamp(1, 1), []))
      sync(tracker)

      # The default threshold is 10 ticks. A purge after 2 ticks shows that the option is in use.
      tick(tracker)
      assert peer(tracker, @probe)

      tick(tracker)
      refute peer(tracker, @probe)
    end
  end

  describe "empty_grace_in_ms" do
    test "gives the grace period to a tracker that track/5 starts", %{scope: scope} do
      start_library(empty_grace_in_ms: 1_234)

      {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key", %{})
      tracker = Tracker.whereis(scope)
      :ok = Rollcall.untrack(self(), scope, "partition", "key")

      assert_timer_within(tracker, 1_234)
    end
  end

  describe "Tracker.start_link/1" do
    test "sets the grace period with the option :empty_grace_in_ms", %{scope: scope} do
      tracker = start_supervised!({Tracker, {scope, empty_grace_in_ms: 1_234}})

      {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key", %{})
      :ok = Rollcall.untrack(self(), scope, "partition", "key")

      assert_timer_within(tracker, 1_234)
    end
  end

  # Replaces the default library instance with one that has `opts`. The test
  # supervisor stops the new instance when the test ends, and the callback
  # restores the default instance. Start the network before the library. The
  # trackers send their goodbye through the network when they stop.
  defp start_library(opts) do
    :ok = Supervisor.terminate_child(Rollcall.TestSupervisor, Rollcall)
    on_exit(fn -> {:ok, _pid} = Supervisor.restart_child(Rollcall.TestSupervisor, Rollcall) end)

    start_supervised!({Rollcall, opts})
  end

  defp in_memory(network), do: {InMemory, network: network, node: :a@host}

  # The tracker starts the timer when its last entry leaves. The default length
  # is 5000 ms, so a value up to `length` shows that the option is in use.
  defp assert_timer_within(tracker, length) do
    remaining = :erlang.read_timer(:sys.get_state(tracker).empty_timer)

    assert is_integer(remaining)
    assert remaining > 0
    assert remaining <= length
  end
end
