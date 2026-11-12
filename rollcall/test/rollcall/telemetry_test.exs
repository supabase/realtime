defmodule Rollcall.TelemetryTest do
  use Rollcall.Case, async: true

  import Rollcall.TrackerHelpers
  import Rollcall.TraceHelpers, only: [expire_grace: 1]
  import Rollcall.Tracker.Messages, only: [snapshot: 3, stamp: 2, wire_entry: 4]

  # The tracker emits the events of `Rollcall.Tracker`. A test listens for the events of its own
  # scope, so the tests can run at the same time.
  #
  # The tracker uses `Rollcall.Transport.PassThrough`. A test delivers a message with
  # `send(tracker, {:deliver, scope, message})`, and sends each `:tick` itself.

  @start Rollcall.Metrics.tracker_start()
  @stop Rollcall.Metrics.tracker_stop()
  @purge Rollcall.Metrics.tracker_peer_purge()
  @peers Rollcall.Metrics.tracker_peers()

  # A transport that raises on a heartbeat. The tracker sends a heartbeat only for the goodbye, because
  # the tests turn the heartbeat timer off.
  defmodule GoodbyeFailsTransport do
    @moduledoc false
    @behaviour Rollcall.Transport

    @impl true
    def init(scope, _opts), do: {:ok, scope}

    @impl true
    def heartbeat(_scope, _message), do: raise("the transport cannot send")

    @impl true
    def publish(_scope, _partition, _diff), do: :ok

    @impl true
    def unwrap(_scope, _raw), do: :ignore
  end

  @node_a :a@host
  @node_b :b@host
  @threshold 3

  setup %{scope: scope} do
    id = {__MODULE__, make_ref()}

    :telemetry.attach_many(id, [@start, @stop, @purge, @peers], &__MODULE__.handle_event/4, %{pid: self(), scope: scope})

    on_exit(fn -> :telemetry.detach(id) end)
  end

  def handle_event(event, measurements, %{scope: scope} = metadata, %{pid: pid, scope: scope}) do
    send(pid, {:telemetry, event, measurements, metadata})
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  describe "start" do
    test "is emitted when a tracker starts", %{scope: scope, rollcall: rollcall} do
      start_tracker(rollcall, scope, @threshold)

      assert_receive {:telemetry, @start, %{}, %{scope: ^scope}}
    end
  end

  describe "stop" do
    test "is emitted with the reason :normal when the grace period ends", %{scope: scope, rollcall: rollcall} do
      tracker = start_tracker(rollcall, scope, @threshold)
      monitor = Process.monitor(tracker)

      expire_grace(tracker)

      assert_receive {:DOWN, ^monitor, :process, ^tracker, :normal}
      assert_receive {:telemetry, @stop, %{}, %{scope: ^scope, reason: :normal}}
    end

    @tag :capture_log
    test "is emitted with the raw reason when the tracker stops with an error", %{scope: scope, rollcall: rollcall} do
      tracker = start_tracker(rollcall, scope, @threshold)

      GenServer.stop(tracker, :boom)

      assert_receive {:telemetry, @stop, %{}, %{scope: ^scope, reason: :boom}}
    end

    @tag :capture_log
    test "is emitted when the transport fails to send the goodbye", %{scope: scope, rollcall: rollcall} do
      tracker =
        start_supervised!(
          {Rollcall.Tracker,
           {scope, name: rollcall, heartbeat_period_in_ms: :manual, transport: {GoodbyeFailsTransport, []}}}
        )

      catch_exit(GenServer.stop(tracker, :boom))

      assert_receive {:telemetry, @stop, %{}, %{scope: ^scope, reason: :boom}}
    end
  end

  describe "peer purge" do
    test "is emitted as stale when a peer that holds entries is purged", %{scope: scope, rollcall: rollcall} do
      tracker = start_tracker(rollcall, scope, @threshold)
      deliver(tracker, scope, snapshot(remote_pid(@node_a, 1), stamp(1, 3), entries(["a", "b"])))

      tick(tracker, @threshold - 1)
      refute_received {:telemetry, @purge, _, _}

      tick(tracker, 1)

      assert_receive {:telemetry, @purge, %{entries: 2}, %{scope: ^scope, node: @node_a, stale: true}}
    end

    test "is emitted as not stale when a peer that said goodbye is purged", %{scope: scope, rollcall: rollcall} do
      origin = remote_pid(@node_a, 1)
      tracker = start_tracker(rollcall, scope, @threshold)
      deliver(tracker, scope, snapshot(origin, stamp(1, 3), entries(["a", "b"])))
      deliver(tracker, scope, snapshot(origin, stamp(1, 4), []))

      tick(tracker, @threshold)

      assert_receive {:telemetry, @purge, %{entries: 0}, %{scope: ^scope, node: @node_a, stale: false}}
    end
  end

  # A peer that sends a heartbeat in each period has `silent_ticks` 1 at each tick: the tick counts one
  # quiet period, and the next message resets the count. A count above 1 is a missed heartbeat.
  describe "peers" do
    test "reports the number of peers, the overdue peers and the most silent peer", %{
      scope: scope,
      rollcall: rollcall
    } do
      tracker = start_tracker(rollcall, scope, 5)
      deliver(tracker, scope, snapshot(remote_pid(@node_a, 1), stamp(1, 1), entries(["a"])))
      deliver(tracker, scope, snapshot(remote_pid(@node_b, 1), stamp(1, 1), entries(["b"])))

      tick(tracker, 1)

      assert_receive {:telemetry, @peers, %{count: 2, overdue_count: 0, max_silent_ticks: 1}, %{scope: ^scope}}

      # A message from node B resets its count. Node A misses the second period.
      deliver(tracker, scope, snapshot(remote_pid(@node_b, 1), stamp(1, 2), entries(["b"])))
      tick(tracker, 1)

      assert_receive {:telemetry, @peers, %{count: 2, overdue_count: 1, max_silent_ticks: 2}, %{scope: ^scope}}
    end

    test "does not count a peer that holds no entries as overdue", %{scope: scope, rollcall: rollcall} do
      origin_b = remote_pid(@node_b, 1)
      tracker = start_tracker(rollcall, scope, 5)
      deliver(tracker, scope, snapshot(remote_pid(@node_a, 1), stamp(1, 1), entries(["a"])))
      deliver(tracker, scope, snapshot(origin_b, stamp(1, 1), entries(["b"])))
      # Node B says goodbye. It sends nothing after that, so its record is silent until the purge.
      deliver(tracker, scope, snapshot(origin_b, stamp(1, 2), []))

      tick(tracker, 1)
      # A message from node A resets its count. Node B is silent for the second tick.
      deliver(tracker, scope, snapshot(remote_pid(@node_a, 1), stamp(1, 2), entries(["a"])))
      tick(tracker, 1)

      assert_receive {:telemetry, @peers, %{count: 2, overdue_count: 0, max_silent_ticks: 1}, %{scope: ^scope}}
      assert_receive {:telemetry, @peers, %{count: 2, overdue_count: 0, max_silent_ticks: 1}, %{scope: ^scope}}
    end

    test "reports no silence when no peer holds entries", %{scope: scope, rollcall: rollcall} do
      origin = remote_pid(@node_a, 1)
      tracker = start_tracker(rollcall, scope, @threshold)
      deliver(tracker, scope, snapshot(origin, stamp(1, 1), entries(["a"])))
      deliver(tracker, scope, snapshot(origin, stamp(1, 2), []))

      tick(tracker, 1)

      assert_receive {:telemetry, @peers, %{count: 1, overdue_count: 0, max_silent_ticks: 0}, %{scope: ^scope}}
    end

    test "reports no silence for a tracker with no peers", %{scope: scope, rollcall: rollcall} do
      tracker = start_tracker(rollcall, scope, @threshold)

      tick(tracker, 1)

      assert_receive {:telemetry, @peers, %{count: 0, overdue_count: 0, max_silent_ticks: 0}, %{scope: ^scope}}
    end
  end

  defp entries(refs), do: Enum.map(refs, &wire_entry("partition", "key", &1, %{}))

  defp deliver(tracker, scope, message) do
    send(tracker, {:deliver, scope, message})
    sync(tracker)
  end

  defp tick(tracker, times) do
    for _ <- 1..times, do: send(tracker, :tick)
    sync(tracker)
  end

  # A call returns after the tracker handled every earlier message.
  defp sync(tracker) do
    :sys.get_state(tracker)
    :ok
  end
end
