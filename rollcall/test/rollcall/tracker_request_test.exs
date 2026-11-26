defmodule Rollcall.TrackerRequestTest do
  # The trace collector is global. Tests that use it cannot run concurrently.
  use Rollcall.Case, async: false
  use Rollcall.TraceHelpers

  import Rollcall.NetworkHelpers
  import Rollcall.Tracker.Messages, only: [diff: 5, kind: 1, request: 1, snapshot: 3, stamp: 2, wire_entry: 4]

  alias Rollcall.Transport.InMemory.Network

  # The test process is a peer on the fake node `@probe`. It receives what the
  # tracker sends. The tracker has the timer off, and the test sends each tick.
  #
  # A diff as the first message from a node puts the record of that node behind.
  # The record has no mark, so the diff cannot apply.

  @node_a :a@host
  @probe :probe@host

  @request_sent :rollcall_tracker_request_sent
  @reply_sent :rollcall_tracker_reply_sent
  @peer_message :rollcall_tracker_peer_message

  setup %{scope: scope} do
    network = start_network()
    probe = join_probe(network, scope, @probe)
    {:ok, network: network, probe: probe}
  end

  describe "tick" do
    test "sends a request to the node of a peer that is behind", %{scope: scope, network: network, probe: probe} do
      check_trace(
        fn ->
          tracker = start_node(scope, network, @node_a)
          make_behind(tracker, probe)

          tick(tracker)

          # A tick sends the heartbeat and the request.
          receive_messages(probe, 2)
        end,
        fn messages, trace ->
          assert [{:request, origin}] = Enum.filter(messages, &(kind(&1) == :request))
          assert node(origin) == @node_a

          assert [%{node: @probe}] = expect_events(trace, @request_sent, scope, 1)
        end
      )
    end

    test "sends the request again when the request was lost", %{scope: scope, network: network, probe: probe} do
      tracker = start_node(scope, network, @node_a)
      make_behind(tracker, probe)

      # The first tick sends two messages, the heartbeat and the request. The network drops both.
      :ok = Network.drop_next(network, 2)
      tick(tracker)
      refute_receive {:in_memory, _scope, _node, _message}, 50

      tick(tracker)

      assert :request in kinds(receive_messages(probe, 2))
    end

    test "sends no request to a peer that the tick purges", %{scope: scope, network: network, probe: probe} do
      tracker = start_node(scope, network, @node_a, silence_threshold: 2)
      make_behind(tracker, probe)

      # The first tick keeps the peer, so it sends the heartbeat and the request.
      tick(tracker)
      assert :request in kinds(receive_messages(probe, 2))

      # The second tick purges the peer, so it sends the heartbeat only.
      tick(tracker)

      assert kind(receive_message(probe)) in [:snapshot, :diff]
      refute_receive {:in_memory, _scope, _node, _message}, 50
    end

    test "sends no request after a snapshot of the peer cleared behind", %{
      scope: scope,
      network: network,
      probe: probe
    } do
      check_trace(
        fn ->
          tracker = start_node(scope, network, @node_a)
          make_behind(tracker, probe)
          tick(tracker)
          receive_messages(probe, 2)

          send_from_probe(probe, snapshot(self(), stamp(1, 5), [wire_entry("partition", "ref", "key", %{})]))
          sync(tracker)
          tick(tracker)

          receive_message(probe)
        end,
        fn heartbeat, trace ->
          assert kind(heartbeat) in [:snapshot, :diff]
          refute_receive {:in_memory, _scope, _node, _message}, 50

          assert [%{behind: true}, %{behind: false}] = expect_events(trace, @peer_message, scope, 2)
        end
      )
    end
  end

  describe "a request" do
    test "gets a snapshot of the local entries at the current stamp", %{
      scope: scope,
      network: network,
      probe: probe
    } do
      check_trace(
        fn ->
          tracker = start_node(scope, network, @node_a)
          ref = track(tracker, start_client(), "partition", "key", %{a: 1})

          # The view holds an entry of the peer. The reply must not hold it.
          send_from_probe(
            probe,
            snapshot(self(), stamp(1, 1), [wire_entry("partition", "peer-ref", "peer-key", %{b: 2})])
          )

          send_from_probe(probe, request(self()))
          sync(tracker)

          # The tracker replies at once. The test sends no tick.
          {tracker, ref, receive_message(probe)}
        end,
        fn {tracker, ref, reply}, trace ->
          assert {:snapshot, origin, stamp, entries} = reply
          assert node(origin) == @node_a
          assert stamp == {:stamp, tracker_state(tracker).incarnation, 1}
          assert entries == [wire_entry("partition", ref, "key", %{a: 1})]

          assert [%{node: @probe, version: 1, refs: [^ref]}] = expect_events(trace, @reply_sent, scope, 1)
        end
      )
    end

    test "from a node with no record gets a snapshot and creates no record", %{
      scope: scope,
      network: network,
      probe: probe
    } do
      tracker = start_node(scope, network, @node_a)
      ref = track(tracker, start_client(), "partition", "key", %{a: 1})

      send_from_probe(probe, request(self()))

      assert {:snapshot, _origin, _stamp, entries} = receive_message(probe)
      assert entries == [wire_entry("partition", ref, "key", %{a: 1})]
      assert tracker_state(tracker).peers == %{}
    end
  end

  describe "a request from the local node" do
    # The transport never delivers a message to its own node, but the tracker guards against it. A reply
    # to the local node would only come back as a message that the tracker drops.
    test "gets no reply", %{scope: scope, rollcall: rollcall} do
      tracker =
        start_supervised!(
          {Rollcall.Tracker,
           {scope,
            name: rollcall, heartbeat_period_in_ms: :manual, transport: {Rollcall.Transport.Recording, to: self()}}}
        )

      # A request from a remote node gets a reply. This shows that the transport reports its messages.
      send(tracker, {:deliver, scope, request(Rollcall.TrackerHelpers.remote_pid(@probe, 1))})
      assert_receive {:sent_to, @probe, {:snapshot, _origin, _stamp, []}}

      send(tracker, {:deliver, scope, request(self())})
      sync(tracker)

      refute_receive {:sent_to, _node, _message}, 50
    end
  end

  describe "telemetry" do
    setup %{scope: scope} do
      id = {__MODULE__, make_ref()}

      events = [Rollcall.Metrics.tracker_request_send(), Rollcall.Metrics.tracker_reply_send()]
      :telemetry.attach_many(id, events, &__MODULE__.handle_event/4, %{pid: self(), scope: scope})

      on_exit(fn -> :telemetry.detach(id) end)
    end

    test "a tick emits one request event for each request", %{scope: scope, network: network, probe: probe} do
      request_send = Rollcall.Metrics.tracker_request_send()
      tracker = start_node(scope, network, @node_a)
      make_behind(tracker, probe)

      tick(tracker)

      assert_receive {:telemetry, ^request_send, %{}, %{scope: ^scope, node: @probe}}
      refute_receive {:telemetry, ^request_send, _measurements, _metadata}, 50
    end

    test "a reply emits an event with the number of entries and the time to build it", %{
      scope: scope,
      network: network,
      probe: probe
    } do
      reply_send = Rollcall.Metrics.tracker_reply_send()
      tracker = start_node(scope, network, @node_a)
      client = start_client()
      track(tracker, client, "partition", "key_1")
      track(tracker, client, "partition", "key_2")

      send_from_probe(probe, request(self()))
      sync(tracker)

      assert_receive {:telemetry, ^reply_send, %{entries: 2, duration: duration}, %{scope: ^scope, node: @probe}}
      assert is_integer(duration) and duration >= 0
    end
  end

  def handle_event(event, measurements, %{scope: scope} = metadata, %{pid: pid, scope: scope}) do
    send(pid, {:telemetry, event, measurements, metadata})
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  # The first message from the probe is a diff, so the tracker holds a record for the probe that is behind.
  defp make_behind(tracker, probe) do
    send_from_probe(probe, diff(self(), stamp(1, 5), 4, [], []))
    sync(tracker)
  end

  defp receive_messages(probe, count), do: for(_ <- 1..count, do: receive_message(probe))

  defp kinds(messages), do: Enum.map(messages, &kind/1)
end
