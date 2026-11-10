defmodule Rollcall.TrackerInterestTest do
  use Rollcall.Case, async: true

  import Rollcall.NetworkHelpers, only: [start_client: 0]
  import Rollcall.Tracker.Messages, only: [snapshot: 3, stamp: 2, wire_entry: 4]
  import Rollcall.TraceHelpers, only: [empty_timer: 1, expire_grace: 1]
  import Rollcall.TrackerHelpers, only: [remote_pid: 2]

  alias Rollcall.Tracker
  alias Rollcall.Transport.Interest

  # A tracker that holds no local entry stops at the end of the grace period.
  # It stays while the transport has interest, so that a node with listeners
  # and no local entry keeps the state of its peers.

  setup do
    interest = start_supervised!({Agent, fn -> true end})
    rollcall = unique_name()

    start_supervised!(
      {Rollcall, name: rollcall, heartbeat_period_in_ms: :manual, transport: {Interest, interest: interest}}
    )

    {:ok, interest: interest, rollcall: rollcall}
  end

  describe "the end of the grace period" do
    # `expire_grace/1` sends the timeout message with the ref in the state of the tracker. A
    # tracker that kept the ref of the expired timer would accept a second message. In production
    # no timer would be left to send it. A new ref shows that the tracker started a timer.
    test "starts the timer again while the transport has interest", %{scope: scope, rollcall: rollcall} do
      tracker = start_empty_tracker(rollcall, scope)
      expired = empty_timer(tracker)

      expire_grace_and_sync(tracker)

      refute empty_timer(tracker) == expired
    end

    test "stops the tracker at a later end once the transport has no interest", ctx do
      %{scope: scope, rollcall: rollcall, interest: interest} = ctx
      tracker = start_empty_tracker(rollcall, scope)
      expire_grace_and_sync(tracker)

      set_interest(interest, false)

      assert_stops(tracker, fn -> expire_grace(tracker) end)
    end

    test "stops the tracker when the transport has no interest", ctx do
      %{scope: scope, rollcall: rollcall, interest: interest} = ctx
      set_interest(interest, false)
      tracker = start_empty_tracker(rollcall, scope)

      assert_stops(tracker, fn -> expire_grace(tracker) end)
    end

    test "keeps the entries of a peer after the last local entry leaves", %{scope: scope, rollcall: rollcall} do
      client = start_client()
      {:ok, _ref} = Rollcall.track(rollcall, client, scope, "partition", "local_key", %{})
      tracker = Tracker.whereis(rollcall, scope)
      deliver_peer_snapshot(tracker, scope, [wire_entry("partition", "peer_key", "peer-ref", %{n: 1})])
      :ok = Rollcall.untrack(rollcall, client, scope, "partition", "local_key")

      expire_grace_and_sync(tracker)

      assert [{"peer-ref", "peer_key", %{n: 1}}] = Rollcall.state(rollcall, scope, "partition")
    end
  end

  # Tracks and untracks an entry, so the tracker holds no entry and has its grace timer.
  defp start_empty_tracker(rollcall, scope) do
    client = start_client()
    {:ok, _ref} = Rollcall.track(rollcall, client, scope, "partition", "key", %{})
    :ok = Rollcall.untrack(rollcall, client, scope, "partition", "key")

    Tracker.whereis(rollcall, scope)
  end

  defp deliver_peer_snapshot(tracker, scope, entries) do
    send(tracker, {:deliver, scope, snapshot(remote_pid(:peer@host, 1), stamp(1, 1), entries)})
    _ = :sys.get_state(tracker)
    :ok
  end

  # The state call is behind the timeout message in the mailbox of the tracker.
  # A tracker that stopped exits the state call.
  defp expire_grace_and_sync(tracker) do
    expire_grace(tracker)

    alive? =
      try do
        _ = :sys.get_state(tracker)
        true
      catch
        :exit, _ -> false
      end

    assert alive?, "the tracker stopped at the end of the grace period"
  end

  defp set_interest(interest, value), do: Agent.update(interest, fn _ -> value end)

  defp assert_stops(tracker, fun) do
    monitor = Process.monitor(tracker)
    fun.()
    assert_receive {:DOWN, ^monitor, :process, ^tracker, :normal}
  end
end
