defmodule Rollcall.ConvergenceTest do
  use Rollcall.Case, async: false
  use ExUnitProperties

  import Rollcall.NetworkHelpers
  import Rollcall.PeerHelpers, only: [refs: 1]

  alias Rollcall.Tracker.Local
  alias Rollcall.Transport.InMemory.Network

  # The test starts two or three trackers for one scope on the in-memory network.
  # The timers are off. The test makes a random list of operations: track,
  # untrack, a client exit, a tick, a dropped delivery, a stop, a kill and a
  # restart. It runs the operations. Then it stops the drops and counts rounds.
  #
  # A round ticks each live tracker once. Then it lets the network deliver every
  # message, including the replies that the delivery causes. A round is one
  # heartbeat period with no delivery delay.
  #
  # The test does not know which message kinds the trackers send. It checks the
  # result only: each live tracker holds exactly the local entries of each live
  # peer, and no entry of a dead tracker.

  @nodes [:a@host, :b@host, :c@host]
  @threshold 3

  # The number of rounds that a live replica needs to become correct, after the
  # last drop and the last change. A snapshot heartbeat repairs a replica in one
  # round, in any order of the ticks.
  @rounds 1

  property "live trackers hold the entries of live peers after #{@rounds} round, and no entry of a dead peer after the threshold" do
    check all(
            node_count <- integer(2..3),
            ops <- list_of(operation(node_count), max_length: 40),
            max_runs: 1000
          ) do
      cluster = start_cluster(node_count)

      cluster = Enum.reduce(ops, cluster, &apply_op/2)

      assert_converged(cluster)
    end
  end

  defp operation(node_count) do
    node = integer(0..(node_count - 1))
    client = integer(1..2)
    key = member_of(["key_1", "key_2", "key_3"])

    frequency([
      {6, tuple({constant(:track), node, client, key})},
      {3, tuple({constant(:untrack), node, client, key})},
      {2, tuple({constant(:client_exit), node, client})},
      {8, constant(:round)},
      {4, tuple({constant(:tick_one), node})},
      {4, tuple({constant(:drop), integer(1..3)})},
      {1, tuple({constant(:stop), node})},
      {1, tuple({constant(:kill), node})},
      {2, tuple({constant(:start), node})}
    ])
  end

  # The cluster holds the scope, the network and one record for each node. A
  # record holds the tracker pid, the id of the tracker child, and the clients.
  # A dead node has `tracker: nil`.
  defp start_cluster(node_count) do
    scope = unique_scope()
    network = start_supervised!(Supervisor.child_spec(Network, id: {:network, scope}))

    nodes =
      @nodes
      |> Enum.take(node_count)
      |> Map.new(fn node -> {node, start_tracker(scope, network, node)} end)

    %{scope: scope, network: network, nodes: nodes}
  end

  defp start_tracker(scope, network, node) do
    id = {scope, node, System.unique_integer([:positive])}

    tracker =
      start_node(scope, network, node,
        id: id,
        silence_threshold: @threshold,
        empty_grace_in_ms: :timer.hours(1)
      )

    %{tracker: tracker, id: id, clients: %{}}
  end

  defp apply_op({:track, index, client_id, key}, cluster) do
    with_live_node(cluster, index, fn _node, record ->
      {client, record} = client(record, client_id)
      track(record.tracker, client, "partition", key)
      record
    end)
  end

  defp apply_op({:untrack, index, client_id, key}, cluster) do
    with_live_node(cluster, index, fn _node, record ->
      case Map.fetch(record.clients, client_id) do
        {:ok, client} -> untrack(record.tracker, client, "partition", key)
        :error -> :ok
      end

      record
    end)
  end

  defp apply_op({:client_exit, index, client_id}, cluster) do
    with_live_node(cluster, index, fn _node, record ->
      case Map.pop(record.clients, client_id) do
        {nil, _clients} ->
          record

        {client, clients} ->
          ref = Process.monitor(client)
          Process.exit(client, :kill)
          assert_receive {:DOWN, ^ref, :process, ^client, :killed}
          await_untracked(record.tracker, client)
          %{record | clients: clients}
      end
    end)
  end

  defp apply_op(:round, cluster), do: run_round(cluster)

  defp apply_op({:tick_one, index}, cluster) do
    with_live_node(cluster, index, fn _node, record ->
      tick(record.tracker)
      record
    end)
  end

  defp apply_op({:drop, count}, cluster) do
    :ok = Network.drop_next(cluster.network, count)
    cluster
  end

  defp apply_op({:stop, index}, cluster) do
    with_live_node(cluster, index, fn _node, record ->
      stop_node(record.id)
      dead(record)
    end)
  end

  defp apply_op({:kill, index}, cluster) do
    with_live_node(cluster, index, fn _node, record ->
      kill_node(record.tracker)
      dead(record)
    end)
  end

  defp apply_op({:start, index}, cluster) do
    node = Enum.at(@nodes, index)

    case cluster.nodes do
      %{^node => %{tracker: nil}} ->
        put_in(cluster.nodes[node], start_tracker(cluster.scope, cluster.network, node))

      _ ->
        cluster
    end
  end

  # An operation on a node that does not exist or is dead does nothing.
  defp with_live_node(cluster, index, fun) do
    node = Enum.at(@nodes, index)

    case cluster.nodes do
      %{^node => %{tracker: tracker} = record} when tracker != nil ->
        put_in(cluster.nodes[node], fun.(node, record))

      _ ->
        cluster
    end
  end

  defp dead(record), do: %{record | tracker: nil, clients: %{}}

  # The tracker gets the `:DOWN` message of a client at an unknown time. A `sync`
  # does not wait for a message that is still on its way, so the test polls.
  defp await_untracked(tracker, client, attempts \\ 1000) do
    local = tracker |> tracker_state() |> Map.fetch!(:local)

    cond do
      not Local.tracks?(local, client) ->
        :ok

      attempts == 0 ->
        flunk("The tracker still holds entries of the client that exited")

      true ->
        Process.sleep(1)
        await_untracked(tracker, client, attempts - 1)
    end
  end

  defp client(record, client_id) do
    case record.clients do
      %{^client_id => client} ->
        {client, record}

      _ ->
        client = start_client()
        {client, %{record | clients: Map.put(record.clients, client_id, client)}}
    end
  end

  defp live(cluster) do
    for {node, %{tracker: tracker}} <- cluster.nodes, tracker != nil, do: {node, tracker}
  end

  defp dead_nodes(cluster) do
    for {node, %{tracker: nil}} <- cluster.nodes, do: node
  end

  defp run_round(cluster) do
    for {_node, tracker} <- live(cluster), do: tick(tracker)
    settle(cluster)
    cluster
  end

  # Three passes. A request, its reply and the application of the reply each
  # need one pass.
  defp settle(cluster) do
    for _pass <- 1..3, {_node, tracker} <- live(cluster), do: sync(tracker)
    :ok
  end

  defp assert_converged(cluster) do
    Network.clear_drops(cluster.network)
    settle(cluster)

    for _ <- 1..@rounds, do: run_round(cluster)
    assert_live_replicas(cluster)

    for _ <- 1..@threshold, do: run_round(cluster)
    assert_live_replicas(cluster)
    assert_dead_replicas(cluster)
  end

  defp assert_live_replicas(cluster) do
    for {node, tracker} <- live(cluster),
        {peer_node, peer_tracker} <- live(cluster),
        node != peer_node do
      assert replica(tracker, peer_node) == local_refs(peer_tracker),
             "the replica of #{peer_node} on #{node} is not the local entries of #{peer_node}"
    end
  end

  defp assert_dead_replicas(cluster) do
    for {node, tracker} <- live(cluster), dead_node <- dead_nodes(cluster) do
      assert replica(tracker, dead_node) == [],
             "#{node} holds entries of #{dead_node}, which is not running"
    end
  end

  defp replica(tracker, node) do
    case peer(tracker, node) do
      nil -> []
      peer -> refs(peer)
    end
  end

  defp local_refs(tracker) do
    tracker
    |> tracker_state()
    |> Map.fetch!(:local)
    |> Local.ids()
    |> Enum.map(fn {_partition, ref} -> ref end)
    |> Enum.sort()
  end
end
