defmodule Rollcall.TrackerTargetedSnapshotTest do
  # The trace collector is global. Tests that use it cannot run concurrently.
  use Rollcall.Case, async: false
  use Rollcall.TraceHelpers

  import Rollcall.NetworkHelpers
  import Rollcall.Tracker.Messages, only: [request: 1]

  # A peer applies a diff only when the `from` version of the diff is its mark.
  # A reply is a snapshot, so it moves the mark of the requester to the version
  # of the reply. When a change follows the reply, the next diff still starts at
  # the last heartbeat, before the mark of the requester. The requester cannot
  # apply that diff. The tick then also sends the requester a snapshot at the
  # current version, and the requester is back in step.
  #
  # The test process is a peer on the fake node `@probe`, and it is the requester.
  # The tracker has the timer off. The test sends each tick.
  #
  # Each test lists the versions of the tracker as a timeline:
  #
  #   v1  the first tick sends a snapshot. This is the last heartbeat.
  #   vN  a change raises the version to N.
  #   reply@vN  the probe asks and the tracker replies at version N.
  #   tick  the tracker sends the heartbeat.
  #
  # The tracker sends the diff and the targeted snapshot in no defined order. A
  # test that reads both reads them sorted by kind: the diff, then the snapshot.

  @node_a :a@host
  @probe :probe@host
  @reply_sent :rollcall_tracker_reply_sent

  setup %{scope: scope} do
    network = start_network()
    probe = join_probe(network, scope, @probe)
    tracker = start_node(scope, network, @node_a)

    {:ok, network: network, probe: probe, tracker: tracker, client: start_client()}
  end

  describe "a tick that sends a diff" do
    test "also sends the requester a snapshot when a change follows its reply", ctx do
      # v1, v2, reply@v2, v3, tick: the diff starts at v1, but the requester is at v2.
      first_tick(ctx)
      change(ctx)
      reply(ctx)
      change(ctx)

      tick(ctx.tracker)

      assert read_by_kind(ctx.probe, 2) == [
               %{kind: :diff, from: 1, version: 3, joins: 2, leaves: 0},
               %{kind: :snapshot, version: 3, entries: 3}
             ]
    end

    test "sends the diff only to a peer that did not ask", %{scope: scope, network: network} = ctx do
      check_trace(
        fn ->
          other = start_node(scope, network, :b@host)
          first_tick(ctx)
          change(ctx)
          reply(ctx)
          change(ctx)

          tick(ctx.tracker)

          read_by_kind(ctx.probe, 2)
          sync(other)
        end,
        fn _, trace ->
          # The tracker sent one targeted snapshot, and it went to the probe.
          assert [%{node: @probe, tick: true}] = tick_replies(trace, scope)
        end
      )
    end

    test "sends the diff only when no change follows the reply", ctx do
      # v1, v2, reply@v2, tick: the diff starts at v1 and ends at v2, so it applies at v2.
      first_tick(ctx)
      change(ctx)
      reply(ctx)

      tick(ctx.tracker)

      assert read_by_kind(ctx.probe, 1) == [%{kind: :diff, from: 1, version: 2, joins: 1, leaves: 0}]
      assert_nothing_more_sent()
    end

    test "sends the diff only when the reply is at the version of the last heartbeat", ctx do
      # v1, reply@v1, v2, tick: the requester is at v1, and the diff starts at v1.
      first_tick(ctx)
      reply(ctx)
      change(ctx)

      tick(ctx.tracker)

      assert read_by_kind(ctx.probe, 1) == [%{kind: :diff, from: 1, version: 2, joins: 1, leaves: 0}]
      assert_nothing_more_sent()
    end

    test "sends no snapshot in the next tick", ctx do
      first_tick(ctx)
      change(ctx)
      reply(ctx)
      change(ctx)
      tick(ctx.tracker)
      read_by_kind(ctx.probe, 2)

      # The tick after the targeted snapshot sends an empty diff and nothing else.
      tick(ctx.tracker)

      assert read_by_kind(ctx.probe, 1) == [%{kind: :diff, from: 3, version: 3, joins: 0, leaves: 0}]
      assert_nothing_more_sent()
    end
  end

  describe "the first tick" do
    test "sends one snapshot, and no targeted snapshot, when a change follows a reply", ctx do
      # v1, reply@v1, v2, first tick: the tick sends a snapshot, which every peer can apply.
      change(ctx)
      reply(ctx)
      change(ctx)

      tick(ctx.tracker)

      assert read_by_kind(ctx.probe, 1) == [%{kind: :snapshot, version: 2, entries: 2}]
      assert_nothing_more_sent()
    end
  end

  # Tracks a new entry. The tracker raises its version by one.
  defp change(%{tracker: tracker, client: client}) do
    track(tracker, client, "partition", "key_#{System.unique_integer([:positive])}")
  end

  # Starts the diff mode: the tracker has one entry (v1) and sends the first snapshot.
  defp first_tick(%{tracker: tracker, probe: probe} = ctx) do
    change(ctx)
    tick(tracker)

    assert [%{kind: :snapshot, version: 1}] = read_by_kind(probe, 1)
  end

  # The probe asks for a snapshot, and the test reads the reply.
  defp reply(%{tracker: tracker, probe: probe}) do
    send_from_probe(probe, request(self()))
    sync(tracker)

    assert [%{kind: :snapshot}] = read_by_kind(probe, 1)
  end

  # Reads `count` messages that the tracker sent to the probe. Each message is a
  # map with the kind, the version and the sizes, sorted by kind.
  defp read_by_kind(probe, count) do
    probe |> receive_messages_by_kind(count) |> Enum.map(&summary/1)
  end

  defp summary({:snapshot, _origin, {:stamp, _incarnation, version}, entries}) do
    %{kind: :snapshot, version: version, entries: length(entries)}
  end

  defp summary({:diff, _origin, {:stamp, _incarnation, version}, from, joins, leaves}) do
    %{kind: :diff, from: from, version: version, joins: length(joins), leaves: length(leaves)}
  end

  defp assert_nothing_more_sent do
    refute_receive {:in_memory, _scope, _node, _message}, 50
  end

  defp tick_replies(trace, scope) do
    trace |> events(@reply_sent, scope) |> Enum.filter(& &1.tick)
  end
end
