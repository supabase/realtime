defmodule Rollcall.TelemetryTimingTest do
  use Rollcall.Case, async: true

  import Rollcall.NetworkHelpers, only: [start_client: 0, track: 4, untrack: 4, tick: 1, tick: 2]
  import Rollcall.TrackerHelpers
  import Rollcall.Tracker.Messages, only: [diff: 5, request: 1, snapshot: 3, stamp: 2, wire_entry: 4]

  # The tracker emits an event for the time it spends on a heartbeat and on publishing changes.
  # A test listens for the events of its own scope, so the tests can run at the same time.
  #
  # The events carry `duration` in native time units. A test reads it with `ms/1`.

  @send Rollcall.Metrics.tracker_heartbeat_send()
  @apply_event Rollcall.Metrics.tracker_heartbeat_apply()
  @publish Rollcall.Metrics.tracker_publish()

  @node_a :a@host
  @node_b :b@host
  @threshold 3

  # A transport that waits in `heartbeat/2` and in `publish/3`, so a test can tell which of them an
  # event measures. It takes a message in the same way as `Rollcall.Transport.PassThrough`.
  defmodule SlowTransport do
    @moduledoc false
    @behaviour Rollcall.Transport

    @impl true
    def init(scope, opts) do
      {:ok,
       %{scope: scope, heartbeat_ms: Keyword.get(opts, :heartbeat_ms, 0), publish_ms: Keyword.get(opts, :publish_ms, 0)}}
    end

    @impl true
    def heartbeat(%{heartbeat_ms: ms}, _message) do
      Process.sleep(ms)
      :ok
    end

    @impl true
    def publish(%{publish_ms: ms}, _partition, _diff) do
      Process.sleep(ms)
      :ok
    end

    @impl true
    def unwrap(_state, {:deliver, scope, message}), do: {:ok, scope, message}
    def unwrap(_state, _raw), do: :ignore
  end

  setup %{scope: scope} do
    id = {__MODULE__, make_ref()}

    :telemetry.attach_many(id, [@send, @apply_event, @publish], &__MODULE__.handle_event/4, %{pid: self(), scope: scope})

    on_exit(fn -> :telemetry.detach(id) end)
  end

  def handle_event(event, measurements, %{scope: scope} = metadata, %{pid: pid, scope: scope}) do
    send(pid, {:telemetry, event, measurements, metadata})
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  describe "heartbeat send" do
    test "is emitted at each tick with the kind and the number of local entries", %{scope: scope, rollcall: rollcall} do
      tracker = start_tracker(rollcall, scope, @threshold)
      client = start_client()
      track(tracker, client, "partition", "key_1")
      track(tracker, client, "partition", "key_2")

      tick(tracker)

      assert_receive {:telemetry, @send, %{duration: duration, entries: 2}, %{scope: ^scope, kind: :snapshot}}
      assert is_integer(duration) and duration >= 0
    end

    test "measures the call to the transport", %{scope: scope, rollcall: rollcall} do
      tracker = start_tracker_with(rollcall, scope, {SlowTransport, heartbeat_ms: 30})

      tick(tracker)

      assert_receive {:telemetry, @send, %{duration: duration}, %{scope: ^scope}}
      assert ms(duration) >= 30
    end
  end

  describe "heartbeat apply" do
    test "is emitted for a snapshot, a request and a diff, with the node and the kind", %{
      scope: scope,
      rollcall: rollcall
    } do
      tracker = start_tracker(rollcall, scope, @threshold)
      origin_a = remote_pid(@node_a, 1)

      deliver(tracker, scope, snapshot(origin_a, stamp(1, 1), entries(["a"])))
      deliver(tracker, scope, request(origin_a))
      deliver(tracker, scope, diff(remote_pid(@node_b, 1), stamp(1, 4), 3, entries(["b"]), []))

      assert_receive {:telemetry, @apply_event, %{duration: duration}, %{scope: ^scope, node: @node_a, kind: :snapshot}}
      assert is_integer(duration) and duration >= 0
      assert_receive {:telemetry, @apply_event, %{}, %{scope: ^scope, node: @node_a, kind: :request}}
      assert_receive {:telemetry, @apply_event, %{}, %{scope: ^scope, node: @node_b, kind: :diff}}
    end

    test "has the duration in native time units", %{scope: scope, rollcall: rollcall} do
      tracker = start_tracker(rollcall, scope, @threshold)

      deliver(tracker, scope, snapshot(remote_pid(@node_a, 1), stamp(1, 1), entries(["a"])))

      # The tracker takes more than a microsecond to apply a snapshot. A value in microseconds reads
      # as a few nanoseconds in the native unit, and converts to 0.
      assert_receive {:telemetry, @apply_event, %{duration: duration}, %{scope: ^scope}}
      assert System.convert_time_unit(duration, :native, :microsecond) >= 1
    end

    test "is not emitted for a message that the tracker drops", %{scope: scope, rollcall: rollcall} do
      tracker = start_tracker(rollcall, scope, @threshold)

      deliver(tracker, "another-scope", snapshot(remote_pid(@node_a, 1), stamp(1, 1), entries(["a"])))

      refute_receive {:telemetry, @apply_event, _, _}, 50
    end

    test "does not include the publish", %{scope: scope, rollcall: rollcall} do
      tracker = start_tracker_with(rollcall, scope, {SlowTransport, publish_ms: 50})

      deliver(tracker, scope, snapshot(remote_pid(@node_a, 1), stamp(1, 1), entries(["a"])))

      assert_receive {:telemetry, @apply_event, %{duration: apply_duration}, %{scope: ^scope}}
      assert_receive {:telemetry, @publish, %{duration: publish_duration}, %{scope: ^scope, source: :peer}}
      assert ms(apply_duration) < 50
      assert ms(publish_duration) >= 50
    end
  end

  describe "publish" do
    test "is emitted with the source :local and the entries for a track", %{
      scope: scope,
      rollcall: rollcall
    } do
      tracker = start_tracker(rollcall, scope, @threshold)

      track(tracker, start_client(), "partition", "key")

      assert_receive {:telemetry, @publish, %{duration: duration, entries: 1}, %{scope: ^scope, source: :local}}

      assert is_integer(duration) and duration >= 0
    end

    test "has the source :local for an untrack and for a process that exits", %{scope: scope, rollcall: rollcall} do
      tracker = start_tracker(rollcall, scope, @threshold)
      client = start_client()
      track(tracker, client, "partition", "key_1")
      assert_receive {:telemetry, @publish, _, %{source: :local}}

      untrack(tracker, client, "partition", "key_1")
      assert_receive {:telemetry, @publish, %{entries: 1}, %{source: :local}}

      track(tracker, client, "partition", "key_2")
      assert_receive {:telemetry, @publish, %{entries: 1}, %{source: :local}}

      Process.exit(client, :kill)
      assert_receive {:telemetry, @publish, %{entries: 1}, %{source: :local}}
    end

    test "has the source :peer for a message that adds entries", %{scope: scope, rollcall: rollcall} do
      tracker = start_tracker(rollcall, scope, @threshold)

      deliver(tracker, scope, snapshot(remote_pid(@node_a, 1), stamp(1, 1), entries(["a", "b"])))

      assert_receive {:telemetry, @publish, %{entries: 2}, %{scope: ^scope, source: :peer}}
    end

    test "is emitted for each partition that changed", %{scope: scope, rollcall: rollcall} do
      tracker = start_tracker(rollcall, scope, @threshold)

      entries = [wire_entry("partition_1", "key", "a", %{}), wire_entry("partition_2", "key", "b", %{})]
      deliver(tracker, scope, snapshot(remote_pid(@node_a, 1), stamp(1, 1), entries))

      assert_receive {:telemetry, @publish, %{entries: 1}, %{scope: ^scope, source: :peer}}
      assert_receive {:telemetry, @publish, %{entries: 1}, %{scope: ^scope, source: :peer}}
      refute_receive {:telemetry, @publish, _, _}, 50
    end

    test "has the source :purge when a peer is purged", %{scope: scope, rollcall: rollcall} do
      tracker = start_tracker(rollcall, scope, @threshold)
      deliver(tracker, scope, snapshot(remote_pid(@node_a, 1), stamp(1, 1), entries(["a", "b"])))
      assert_receive {:telemetry, @publish, _, %{source: :peer}}

      tick(tracker, @threshold)

      assert_receive {:telemetry, @publish, %{entries: 2}, %{scope: ^scope, source: :purge}}
    end

    test "is not emitted for a message that changes nothing", %{scope: scope, rollcall: rollcall} do
      tracker = start_tracker(rollcall, scope, @threshold)
      origin = remote_pid(@node_a, 1)
      deliver(tracker, scope, snapshot(origin, stamp(1, 1), entries(["a"])))
      assert_receive {:telemetry, @publish, _, %{source: :peer}}

      deliver(tracker, scope, snapshot(origin, stamp(1, 2), entries(["a"])))

      assert_receive {:telemetry, @apply_event, _, _}
      assert_receive {:telemetry, @apply_event, _, _}
      refute_receive {:telemetry, @publish, _, _}, 50
    end
  end

  defp start_tracker_with(rollcall, scope, transport) do
    start_supervised!(
      {Rollcall.Tracker, {scope, name: rollcall, heartbeat_period_in_ms: :manual, transport: transport}}
    )
  end

  defp entries(refs), do: Enum.map(refs, &wire_entry("partition", "key", &1, %{}))

  defp deliver(tracker, scope, message) do
    send(tracker, {:deliver, scope, message})
    :sys.get_state(tracker)
    :ok
  end

  defp ms(native), do: System.convert_time_unit(native, :native, :millisecond)
end
