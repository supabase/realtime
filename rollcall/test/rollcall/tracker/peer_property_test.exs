defmodule Rollcall.Tracker.PeerPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Rollcall.PeerHelpers
  import Rollcall.Tracker.Messages, only: [diff: 5, request: 1, snapshot: 3, stamp: 2, wire_entry: 4]

  alias Rollcall.Tracker.Peer

  # The sender model is a tracker that tracks, untracks, sends heartbeats and
  # restarts. It records every message that it sends, and the set of refs it
  # held at every stamp. The peer then receives the messages in any order, any
  # number of times, and not all of them. This is a transport that reorders,
  # duplicates and loses messages.
  #
  # A stamp fixes the set of the sender: each local change increments the
  # version, and a restart starts a new incarnation.

  property "the replica is the set of the sender at the mark after any delivery" do
    check all(
            ops <- operations(),
            sender = simulate(ops ++ [:snapshot]),
            schedule <- schedule(sender)
          ) do
      Enum.reduce(schedule, nil, fn message, peer ->
        peer = deliver(peer, message.message)

        case mark_tuple(peer) do
          nil -> assert refs(peer) == []
          mark -> assert refs(peer) == Map.fetch!(sender.truth, mark)
        end

        peer
      end)
    end
  end

  property "a message that is not newer than the mark changes nothing" do
    check all(
            ops <- operations(),
            sender = simulate(ops ++ [:snapshot]),
            schedule <- schedule(sender)
          ) do
      Enum.reduce(schedule, nil, fn message, peer ->
        after_delivery = deliver(peer, message.message)

        if peer != nil and message.stamp <= mark_tuple(peer) do
          assert observe(after_delivery) == observe(peer)
        end

        after_delivery
      end)
    end
  end

  # The first message of the highest incarnation that the peer has received is
  # always accepted: a snapshot of a newer incarnation is newer than the mark,
  # and a diff of a newer incarnation never applies and is newer than the mark.
  # Later messages of older incarnations never move the origin back.
  property "the origin is the origin of the highest incarnation delivered so far" do
    check all(
            ops <- operations(),
            sender = simulate(ops ++ [:snapshot]),
            schedule <- schedule(sender)
          ) do
      Enum.reduce(schedule, {nil, nil}, fn message, {peer, newest} ->
        after_delivery = deliver(peer, message.message)
        {incarnation, _version} = message.stamp

        newest =
          case newest do
            {highest, _origin} when highest >= incarnation -> newest
            _ -> {incarnation, message.origin}
          end

        {_incarnation, expected_origin} = newest
        assert Peer.origin(after_delivery) == expected_origin

        {after_delivery, newest}
      end)
    end
  end

  property "a snapshot of the current state restores the replica after any delivery" do
    check all(
            ops <- operations(),
            sender = simulate(ops ++ [:snapshot]),
            schedule <- schedule(sender)
          ) do
      peer = Enum.reduce(schedule, nil, fn message, peer -> deliver(peer, message.message) end)

      current =
        snapshot(
          sender.origin,
          stamp(sender.incarnation, sender.version),
          entries(Enum.sort(sender.local))
        )

      assert refs(deliver(peer, current)) == Enum.sort(sender.local)
    end
  end

  property "a peer is purged after exactly the threshold of quiet ticks" do
    check all(
            threshold <- integer(1..6),
            events <- list_of(member_of([:tick, :stale, :request]), max_length: 30)
          ) do
      origin = new_pid()
      {peer, _changes} = Peer.new(snapshot(origin, stamp(2, 5), entries(["a"])))

      Enum.reduce_while(events, {peer, 0}, fn event, {peer, quiet} ->
        case event do
          :tick ->
            case Peer.tick(peer, threshold) do
              {:keep, peer} ->
                assert quiet + 1 < threshold
                {:cont, {peer, quiet + 1}}

              {:purge, _changes} ->
                assert quiet + 1 == threshold
                {:halt, :purged}
            end

          :stale ->
            {peer, _changes} = Peer.deliver(peer, snapshot(origin, stamp(1, 0), []))
            {:cont, {peer, 0}}

          :request ->
            {peer, _changes} = Peer.deliver(peer, request(origin))
            {:cont, {peer, 0}}
        end
      end)
    end
  end

  defp entries(refs) do
    Enum.map(refs, &wire_entry("partition", "key", &1, %{}))
  end

  defp deliver(nil, message) do
    {peer, _changes} = Peer.new(message)
    peer
  end

  defp deliver(peer, message) do
    {peer, _changes} = Peer.deliver(peer, message)
    peer
  end

  defp observe(peer) do
    %{
      refs: refs(peer),
      behind: Peer.behind?(peer),
      mark: mark_tuple(peer),
      origin: Peer.origin(peer)
    }
  end

  defp operations do
    list_of(
      frequency([
        {4, constant(:track)},
        {3, tuple({constant(:untrack), integer(0..9)})},
        {3, constant(:snapshot)},
        {5, constant(:diff)},
        {1, tuple({constant(:restart), boolean()})}
      ]),
      max_length: 30
    )
  end

  # Any messages, in any order, with repeats. A message that does not appear
  # was lost.
  defp schedule(sender) do
    list_of(member_of(sender.messages), max_length: 40)
  end

  defp simulate(ops) do
    origin = new_pid()

    initial = %{
      incarnation: 1,
      version: 0,
      local: MapSet.new(),
      sent: {MapSet.new(), 0},
      next: 0,
      origin: origin,
      messages: [],
      truth: %{{1, 0} => []}
    }

    sender = Enum.reduce(ops, initial, &apply_op/2)
    %{sender | messages: Enum.reverse(sender.messages)}
  end

  defp apply_op(:track, sender) do
    ref = "ref-#{sender.next}"
    change(%{sender | next: sender.next + 1}, MapSet.put(sender.local, ref))
  end

  defp apply_op({:untrack, index}, sender) do
    case Enum.sort(sender.local) do
      [] ->
        sender

      refs ->
        ref = Enum.at(refs, rem(index, length(refs)))
        change(sender, MapSet.delete(sender.local, ref))
    end
  end

  defp apply_op(:snapshot, sender) do
    stamp = {sender.incarnation, sender.version}
    message = snapshot(sender.origin, stamp(sender.incarnation, sender.version), entries(sorted(sender.local)))

    sender
    |> record(message, stamp)
    |> sent()
  end

  defp apply_op(:diff, sender) do
    stamp = {sender.incarnation, sender.version}
    {sent_local, sent_version} = sender.sent
    joins = MapSet.difference(sender.local, sent_local)
    leaves = MapSet.difference(sent_local, sender.local)

    message =
      diff(
        sender.origin,
        stamp(sender.incarnation, sender.version),
        sent_version,
        entries(sorted(joins)),
        sorted(leaves)
      )

    sender
    |> record(message, stamp)
    |> sent()
  end

  # A graceful stop untracks every entry and sends an empty snapshot. A crash
  # sends nothing. Both start a new incarnation with a new origin.
  defp apply_op({:restart, goodbye?}, sender) do
    sender = if goodbye?, do: goodbye(sender), else: sender
    incarnation = sender.incarnation + 1

    %{
      sender
      | incarnation: incarnation,
        version: 0,
        local: MapSet.new(),
        sent: {MapSet.new(), 0},
        origin: new_pid(),
        truth: Map.put(sender.truth, {incarnation, 0}, [])
    }
  end

  defp goodbye(sender) do
    sender =
      Enum.reduce(sorted(sender.local), sender, fn ref, sender ->
        change(sender, MapSet.delete(sender.local, ref))
      end)

    stamp = {sender.incarnation, sender.version}
    record(sender, snapshot(sender.origin, stamp(sender.incarnation, sender.version), []), stamp)
  end

  defp change(sender, local) do
    version = sender.version + 1

    %{
      sender
      | local: local,
        version: version,
        truth: Map.put(sender.truth, {sender.incarnation, version}, sorted(local))
    }
  end

  defp record(sender, message, stamp) do
    entry = %{message: message, stamp: stamp, origin: sender.origin}
    %{sender | messages: [entry | sender.messages]}
  end

  defp sent(sender), do: %{sender | sent: {sender.local, sender.version}}

  defp sorted(set), do: Enum.sort(set)
end
