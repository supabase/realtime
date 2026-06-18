defmodule Forum.MusterDistributedTest do
  # Real multi-node tests: spin up `:peer` nodes, run Muster on each over the
  # default Erlang-distribution adapter, and exercise discovery + rebalance +
  # the cross-node convergence barrier end-to-end (real `:rebalance_marker`
  # announcements, not injected). The precise barrier *state machine* is covered
  # by the single-node tests in muster_test.exs; this file proves the wiring
  # works across real nodes and that every node converges all the way to
  # :ready (not left stuck in :rebalancing or :converging).
  use ExUnit.Case, async: false
  use Snabbkaffe

  alias ExHashRing.Ring
  alias Forum.Muster
  alias Forum.Muster.Scope

  @aux_mod (quote do
              defmodule MusterPeerAux do
                # Start Muster and keep it alive (the supervisor links to this
                # long-lived process, mirroring the Census peer pattern). Extra
                # opts are merged over the defaults so a test can, e.g., shrink
                # the view-heartbeat interval on this peer.
                def start(scope, opts \\ []) do
                  opts = Keyword.merge([vacant_flush_interval_ms: 100], opts)

                  spawn(fn ->
                    {:ok, _} = Forum.Muster.start_link(scope, opts)
                    Process.sleep(:infinity)
                  end)
                end

                def join(scope, group) do
                  pid = spawn(fn -> Process.sleep(:infinity) end)
                  Forum.Muster.join(scope, group, pid)
                end

                def status(scope) do
                  :persistent_term.get({Forum.Muster, scope, :status})
                end

                # Advance this VM's global monotonic counter by `n`. The
                # occupancy/announce seqs are :erlang.unique_integer([:monotonic]),
                # which starts from the SAME base on every fresh VM, so burning a
                # large amount here makes this incarnation's announce watermark
                # deterministically higher than a same-named restart will ever
                # reach — forcing the cross-incarnation seq regression.
                def burn(n) do
                  Enum.each(1..n, fn _ -> :erlang.unique_integer([:monotonic]) end)
                  :ok
                end

                # The VM's current monotonic counter value.
                def current_seq, do: :erlang.unique_integer([:monotonic])
              end
            end)

  defp spec(scope, opts) do
    %{id: scope, start: {Muster, :start_link, [scope, opts]}, type: :supervisor}
  end

  defp start_remote_muster(peer, scope), do: :peer.call(peer, MusterPeerAux, :start, [scope])

  # Start Muster on a peer with a fast view heartbeat, so the heartbeat backstop
  # gets many chances to heal during a test (used by the restart-regression test
  # to prove the heartbeat cannot heal the stuck node).
  defp start_remote_muster_fast_heartbeat(peer, scope) do
    :peer.call(peer, MusterPeerAux, :start, [scope, [view_heartbeat_interval_ms: 200]])
  end

  defp status(scope), do: :persistent_term.get({Forum.Muster, scope, :status})
  defp remote_status(peer, scope), do: :peer.call(peer, MusterPeerAux, :status, [scope])

  defp occupancy_on(n, scope, group) when n == node(), do: Scope.occupancy(scope, group)
  defp occupancy_on(n, scope, group), do: :erpc.call(n, Scope, :occupancy, [scope, group])

  defp group_state(scope, group),
    do: GenServer.call(Forum.Supervisor.name(scope), :status).group_states[group]

  defp trigger_flush(scope), do: Kernel.send(Forum.Supervisor.name(scope), :flush_vacant)

  # Find a group the LIVE local ring routes to `target` (cluster must be settled).
  defp group_routed_to(scope, target) do
    Enum.find(Stream.map(1..20_000, &:"dist_group_#{&1}"), fn g ->
      match?({:ok, ^target}, Muster.router(scope, g))
    end)
  end

  # Event-driven convergence sync: block until every node in `view` (or
  # `opts[:nodes]`, when only a subset is expected to converge) has emitted its
  # `opts[:nth]`-th (default 1st) :muster_status_change to :ready for `view`'s
  # hash. By the time a node announces :ready for a view its ring IS that view,
  # so this subsumes the old members/status polling. Already-collected events
  # count towards `nth`, which makes `nth: 2` the race-free way to wait for a
  # node to become ready for the same view AGAIN after churn. Requires every
  # waited-on node's trace to be forwarded to this node's collector.
  defp await_ready(view, opts \\ []) do
    nth = Keyword.get(opts, :nth, 1)
    timeout = Keyword.get(opts, :timeout, 15_000)
    view_hash = :erlang.phash2(Enum.sort(view))

    for n <- Keyword.get(opts, :nodes, view) do
      assert {:ok, _} =
               block_until(
                 %{
                   :"$kind" => :muster_status_change,
                   to: :ready,
                   node: ^n,
                   view_hash: ^view_hash
                 },
                 nth,
                 timeout,
                 :infinity
               )
    end

    :ok
  end

  # Plain state polling — the fallback for conditions with no usable trace
  # anchor (e.g. an event whose occurrence count is nondeterministic).
  defp wait_until(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition not met in time")

      true ->
        Process.sleep(20)
        do_wait_until(fun, deadline)
    end
  end

  describe "distributed convergence barrier" do
    setup do
      scope = :"muster_dist_#{System.unique_integer([:positive])}"
      start_supervised!(spec(scope, vacant_flush_interval_ms: 100))
      %{scope: scope}
    end

    test "rebalance re-announces held groups to the new router; all nodes converge",
         %{scope: scope} do
      group = :dist_g
      t_node = node()

      check_trace(
        fn ->
          # Form {A, P1}.
          {:ok, p1, n1} = Peer.start(aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(n1)
          start_remote_muster(p1, scope)
          await_ready([t_node, n1])

          # P1 holds `group`. join/3 only returns :ok once the router has been
          # told (the RPC-before-Partition.join invariant), so the occupancy
          # row is already in place.
          :ok = :peer.call(p1, MusterPeerAux, :join, [scope, group])
          {:ok, r1} = Muster.router(scope, group)
          assert n1 in occupancy_on(r1, scope, group)

          # Add P2 -> {A, P1, P2}. `group`'s router may move; the rebalance
          # must re-announce {group, n1} to the new router, and every node must
          # converge all the way to :ready.
          {:ok, p2, n2} = Peer.start(aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(n2)
          start_remote_muster(p2, scope)
          await_ready([t_node, n1, n2])

          # Whoever the current router is, it holds {group, n1} — this is the
          # core invariant the barrier protects: by the time the cluster is
          # :ready, the new router's occupancy is complete (no grace period).
          {:ok, r2} = Muster.router(scope, group)
          assert n1 in occupancy_on(r2, scope, group)
        end,
        fn _trace -> :ok end
      )
    end

    # Same convergence guarantee as the test above, but proven from the trace
    # instead of polling persistent_term: every node must emit a status
    # transition to :ready *for the final cluster view* after the second node
    # joins triggers a rebalance. snabbkaffe forwards the peers' trace points to
    # this (collector) node, so a single trace holds events from all three nodes.
    #
    # forward_trace/1 is attached to each peer *before* its Muster starts, so no
    # status transition is emitted before forwarding is wired up.
    test "every node converges to :ready again after a rebalance (traced)", %{scope: scope} do
      check_trace(
        fn ->
          # {A, P1}
          {:ok, p1, n1} = Peer.start(aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(n1)
          start_remote_muster(p1, scope)
          await_ready([node(), n1])

          # Add P2 -> {A, P1, P2}: every node rebalances and must re-converge.
          {:ok, p2, n2} = Peer.start(aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(n2)
          start_remote_muster(p2, scope)

          members = Enum.sort([node(), n1, n2])
          view_hash = :erlang.phash2(members)

          # Wait for each node to announce :ready for the final 3-node view. The
          # view_hash match is what makes this "ready *again*": an earlier 2-node
          # :ready (from {A, P1}) carries a different hash and is ignored.
          await_ready(members)

          %{members: members, view_hash: view_hash}
        end,
        fn result, trace ->
          # The trace independently confirms all three nodes reached :ready at
          # the final view, and that a rebalance into that view actually happened.
          ready_nodes =
            of_kind(:muster_status_change, trace)
            |> Enum.filter(&(&1.to == :ready and &1.view_hash == result.view_hash))
            |> Enum.map(& &1.node)
            |> Enum.uniq()
            |> Enum.sort()

          assert ready_nodes == result.members

          rebalanced_into_final =
            of_kind(:muster_rebalance_start, trace)
            |> Enum.any?(&(&1.view_hash == result.view_hash))

          assert rebalanced_into_final
        end
      )
    end
  end

  describe "snapshot vs. drop_stale_router_entries" do
    setup do
      scope = :"muster_race_#{System.unique_integer([:positive])}"
      start_supervised!(spec(scope, vacant_flush_interval_ms: 100))
      %{scope: scope}
    end

    # Both tests probe whether a node's drop_stale_router_entries can delete
    # occupancy rows another node snapshotted to it (via receive_node_state),
    # assuming full connectivity (every node eventually discovers every live
    # node) and varying only the ORDER in which nodes process events.

    # The "joiner still discovering peers" interleaving. T (this node, settled
    # with O) registers the joiner C first, rebalances to {C, O, T} and pushes
    # its snapshot to C; only then is C allowed to run its own rebalances,
    # whose first pass uses a partial 2-node view. The interleaving is forced
    # with snabbkaffe (no rebalance may start on C until T's snapshot has been
    # committed on C). This turns out to be SAFE, by consistent-hashing
    # monotonicity: a group that routes to C in the final view also routes to C
    # in every SUBSET view containing C, and a joiner's intermediate views are
    # always subsets of the final view — so the drop never judges a snapshotted
    # row as "not mine". The test asserts the row survives all the way to
    # :ready.
    test "a snapshotted row survives a joiner still discovering peers", %{scope: scope} do
      t_node = node()

      check_trace(
        fn ->
          # Settled 2-node cluster {T, O}.
          {:ok, p_o, o_node} = Peer.start(aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(o_node)
          start_remote_muster(p_o, scope)
          await_ready([t_node, o_node])

          c_name = ~c"muster_race_c_#{System.unique_integer([:positive])}"
          c_node = :"#{c_name}@127.0.0.1"
          final_members = Enum.sort([t_node, o_node, c_node])
          # The victim group must route to C in the final view {C, O, T}.
          group = pick_group([{final_members, c_node}])

          # T holds the group; the pre-join router knows it by the time join
          # returns (the RPC-before-Partition.join invariant).
          member = spawn(fn -> Process.sleep(:infinity) end)
          :ok = Muster.join(scope, group, member)
          {:ok, r1} = Muster.router(scope, group)
          assert t_node in occupancy_on(r1, scope, group)

          # No rebalance may start on C until T's snapshot has been committed
          # into C's occupancy table — the worst-case ordering for the join.
          force_ordering(
            %{:"$kind" => :muster_node_state_received, node: ^c_node, source: ^t_node},
            %{:"$kind" => :muster_rebalance_start, node: ^c_node}
          )

          {:ok, p_c, ^c_node} = Peer.start(name: c_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(c_node)
          start_remote_muster(p_c, scope)

          await_ready(final_members)

          # Monotonicity holds: C's intermediate rebalances did not touch the
          # snapshotted row.
          assert {:ok, ^c_node} = Muster.router(scope, group)
          assert t_node in occupancy_on(c_node, scope, group)

          %{
            group: group,
            c_node: c_node,
            t_node: t_node,
            occupancy: occupancy_on(c_node, scope, group)
          }
        end,
        fn result, trace ->
          # T snapshotted C exactly once: the join snapshot.
          snapshots =
            of_kind(:muster_node_state_received, trace)
            |> Enum.filter(&(&1.node == result.c_node and &1.source == result.t_node))

          assert length(snapshots) == 1

          # The forced, worst-case join must not delete T's row on C.
          drops =
            of_kind(:muster_drop_stale_entry, trace)
            |> Enum.filter(
              &(&1.node == result.c_node and &1.group == result.group and
                  &1.source == result.t_node)
            )

          assert drops == []

          # INVARIANT: once the cluster is :ready, the router's occupancy
          # table lists every source node that holds the group.
          assert result.t_node in result.occupancy
        end
      )
    end

    # An ephemeral node D joins (fully connected, everyone sees it) and dies
    # shortly after. Now ordering matters, because C transiently holds a view
    # {C, D, O, T} that is NOT a subset of the final view, and the only thing
    # that repopulates C afterwards is a one-shot heal:
    #
    #   * T registers D and hands the group to D (snapshot to D). On D's
    #     death T rebalances back to {C, O, T}; the group moves D -> C, so T
    #     re-snapshots C — the heal. T's membership is now final: this is the
    #     LAST time T ever contacts C about the group.
    #   * C lags: it processes its D registration only after the heal has
    #     landed (forced here via snabbkaffe). Its rebalance into the stale
    #     view {C, D, O, T} judges the group as D's — and an unguarded
    #     drop_stale_router_entries would delete the freshly healed row,
    #     permanently: T never rebalances again, the readiness barrier is
    #     already satisfied, and vacant flushes only ever delete.
    #
    # The source-agreement guard in drop_stale_router_entries protects the
    # row twice over: at C's stale rebalance T's announced view ({C, O, T})
    # disagrees with the stale ring, and even when T's intermediate
    # {C, D, O, T} marker was the last one processed, the healed row's seq is
    # above that announcement's watermark. Either way C must converge back to
    # :ready with the row intact.
    test "a snapshotted row survives an ephemeral node's churn", %{scope: scope} do
      t_node = node()

      check_trace(
        fn ->
          # Settled 2-node cluster {T, O}.
          {:ok, p_o, o_node} = Peer.start(aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(o_node)
          start_remote_muster(p_o, scope)
          await_ready([t_node, o_node])

          # C's and D's node names are chosen upfront so the victim group can
          # be picked from ring math before either boots: it must route to C
          # in the final view {C, O, T} and to D in {C, D, O, T}.
          c_name = ~c"muster_race_c_#{System.unique_integer([:positive])}"
          c_node = :"#{c_name}@127.0.0.1"
          d_name = ~c"muster_race_d_#{System.unique_integer([:positive])}"
          d_node = :"#{d_name}@127.0.0.1"
          final_members = Enum.sort([t_node, o_node, c_node])
          group = pick_victim_group(c_node, d_node, [t_node, o_node])

          # T holds the group; the pre-join router knows it by the time join
          # returns (the RPC-before-Partition.join invariant).
          member = spawn(fn -> Process.sleep(:infinity) end)
          :ok = Muster.join(scope, group, member)
          {:ok, r1} = Muster.router(scope, group)
          assert t_node in occupancy_on(r1, scope, group)

          # Settle C into the cluster: T snapshots the group to C as it
          # rebalances to {C, O, T}. (The forced join interleaving has its own
          # test above; here we only need C settled with the row.)
          {:ok, p_c, ^c_node} = Peer.start(name: c_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(c_node)
          start_remote_muster(p_c, scope)

          await_ready(final_members)
          assert {:ok, ^c_node} = Muster.router(scope, group)
          assert t_node in occupancy_on(c_node, scope, group)

          # --- ephemeral node, unlucky ordering ----------------------------
          stale_view = Enum.sort([d_node | final_members])

          # Hold C's rebalance into the D-containing view until a SECOND
          # snapshot from T lands on C: the first was phase 1's join
          # snapshot, the second is the post-D-death heal. C registers D
          # (and monitors it) before parking at this barrier, so it behaves
          # exactly like a node whose Scope is merely slow to process its
          # mailbox.
          force_ordering(
            %{:"$kind" => :muster_node_state_received, node: ^c_node, source: ^t_node},
            2,
            %{:"$kind" => :muster_rebalance_start, node: ^c_node, to: ^stale_view},
            true
          )

          {:ok, p_d, ^d_node} = Peer.start(name: d_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(d_node)
          start_remote_muster(p_d, scope)

          # Wait until C has registered D (its stale rebalance is now parked
          # at the barrier) and T has handed the group over to D — the
          # snapshot event fires after D commits it.
          assert {:ok, _} =
                   block_until(
                     %{:"$kind" => :muster_peer_registered, node: ^c_node, peer: ^d_node},
                     10_000
                   )

          assert {:ok, %{groups: handed_over}} =
                   block_until(
                     %{:"$kind" => :muster_node_state_received, node: ^d_node, source: ^t_node},
                     10_000
                   )

          assert group in handed_over

          # D dies. T processes the DOWN first: the group moves D -> C, so T
          # re-snapshots C (the heal) — which releases C's parked rebalance
          # into the stale view {C, D, O, T}. Its rebalance_start event is
          # only collected on release, so seeing it proves the heal landed
          # before C's drop_stale_router_entries ran — the dangerous order.
          :ok = stop_supervised({:peer, d_name})

          assert {:ok, _} =
                   block_until(
                     %{:"$kind" => :muster_rebalance_start, node: ^c_node, to: ^stale_view},
                     10_000
                   )

          # C processes D's DOWN and every node converges back to :ready on
          # {C, O, T} — its SECOND :ready for that view, hence nth: 2.
          # (Generous timeout: if a stale-view marker overtakes the final one,
          # the view heartbeat heals it within 10s.)
          await_ready(final_members, nth: 2, timeout: 20_000)

          assert {:ok, ^c_node} = Muster.router(scope, group)

          %{
            group: group,
            c_node: c_node,
            t_node: t_node,
            occupancy: occupancy_on(c_node, scope, group)
          }
        end,
        fn result, trace ->
          # T snapshotted C exactly twice: the join snapshot and the
          # post-D-death heal — proving the heal really fired and raced C's
          # stale rebalance.
          snapshots =
            of_kind(:muster_node_state_received, trace)
            |> Enum.filter(&(&1.node == result.c_node and &1.source == result.t_node))

          assert length(snapshots) == 2

          # No wrongful drops: the stale {C, D, O, T} rebalance must not
          # delete T's row on C.
          drops =
            of_kind(:muster_drop_stale_entry, trace)
            |> Enum.filter(
              &(&1.node == result.c_node and &1.group == result.group and
                  &1.source == result.t_node)
            )

          assert drops == []

          # INVARIANT: once the cluster is :ready, the router's occupancy
          # table lists every source node that holds the group.
          assert result.t_node in result.occupancy
        end
      )
    end
  end

  describe "vacant DELETE vs. re-claim — occupancy seq guard (forced ordering)" do
    setup do
      scope = :"muster_seq_#{System.unique_integer([:positive])}"
      start_supervised!(spec(scope, vacancy_cooldown_ms: 50, vacant_flush_interval_ms: 100))
      %{scope: scope}
    end

    # README "Vacant-time RPC failure": :erpc does not cancel remote execution,
    # so a vacant batch's DELETE can land on the router AFTER the source has
    # re-claimed the group with a fresh :occupied INSERT. The occupancy-row seq
    # versioning must make the stale, lower-seq DELETE a no-op. The single-node
    # tests prove the guard with hand-fed seqs; here the dangerous arrival
    # order is FORCED on a real router: the batch's RPC worker is parked at its
    # trace point until the re-claim's INSERT has been committed, then released
    # so the DELETE runs strictly after it.
    test "a late vacant DELETE cannot clobber a re-claimed group on a real router",
         %{scope: scope} do
      t_node = node()

      check_trace(
        fn ->
          {:ok, p_r, r_node} = Peer.start(aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(r_node)
          start_remote_muster(p_r, scope)
          await_ready([t_node, r_node])

          group = group_routed_to(scope, r_node)

          member = spawn(fn -> Process.sleep(:infinity) end)
          :ok = Muster.join(scope, group, member)
          assert t_node in occupancy_on(r_node, scope, group)

          # Park the batched DELETE on the router until a SECOND :occupied
          # INSERT for this group has been committed there — the first was the
          # join above, the second is the re-claim below. (Already-collected
          # events count towards n_events, hence 2.)
          force_ordering(
            %{:"$kind" => :muster_occupied, node: ^r_node, group: ^group, source: ^t_node},
            2,
            %{
              :"$kind" => :muster_vacant_batch,
              :"$span" => :start,
              node: ^r_node,
              source: ^t_node
            },
            true
          )

          # Vacate: cooldown (50ms) expires -> :vacant_queued -> the periodic
          # flush (100ms) dispatches the batch, whose RPC worker parks on the
          # router. The group stays :vacant_flushing while it is parked.
          :ok = Muster.leave(scope, group, member)

          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_group_state,
                       node: ^t_node,
                       group: ^group,
                       state: :vacant_flushing
                     },
                     5_000
                   )

          # Re-claim while the DELETE is in flight. handle_claim dispatches the
          # :occupied immediately (it does NOT wait for the batch), stamped
          # with a strictly higher seq.
          :ok = Muster.join(scope, group, spawn(fn -> Process.sleep(:infinity) end))

          # The INSERT released the parked batch; wait for the stale DELETE to
          # be applied...
          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_vacant_batch,
                       :"$span" => {:complete, _},
                       node: ^r_node,
                       source: ^t_node
                     },
                     5_000
                   )

          # ...and the row must have survived it.
          assert t_node in occupancy_on(r_node, scope, group)
          assert group_state(scope, group) == :occupied

          %{group: group, r_node: r_node}
        end,
        fn result, trace ->
          # Exactly two INSERTs reached the router: the join and the re-claim,
          # in dispatch order (seqs are per-source monotonic).
          assert [%{seq: first_seq}, %{seq: reclaim_seq}] =
                   of_kind(:muster_occupied, trace)
                   |> Enum.filter(&(&1.node == result.r_node and &1.group == result.group))

          assert first_seq < reclaim_seq

          # The batch the router applied was genuinely stale: stamped at
          # dispatch BEFORE the re-claim (lower seq), applied AFTER its INSERT
          # (later in the trace — the forced ordering).
          batches =
            of_kind(:muster_vacant_batch, trace)
            |> Enum.filter(&(&1[:"$span"] == :start and result.group in &1.groups))

          assert [%{seq: batch_seq}] = batches
          assert batch_seq < reclaim_seq

          # Both events are pinned to their exact seqs, so this is a single
          # forced pair: the stale batch was applied AFTER the re-claim that
          # superseded it.
          assert causality(
                   %{:"$kind" => :muster_occupied, seq: ^reclaim_seq},
                   %{:"$kind" => :muster_vacant_batch, :"$span" => :start, seq: ^batch_seq},
                   trace
                 )
        end
      )
    end
  end

  describe "router-readiness barrier across real nodes (forced ordering)" do
    setup do
      scope = :"muster_barrier_#{System.unique_integer([:positive])}"
      start_supervised!(spec(scope, vacant_flush_interval_ms: 100))
      %{scope: scope}
    end

    # README "Router-readiness barrier" — the exact three-node ordering the
    # barrier exists for: T and the fresh router C agree on the final view and
    # C even holds T's snapshot, but B has not announced that view (its
    # rebalance is parked) — so a membership-agreement check alone would let C
    # decide from an occupancy table that is, in general, incomplete. Until
    # EVERY member announces the view, all nodes must sit in :converging with
    # can_decide? == false (routers flood — over-deliver, never miss), and the
    # moment the lagging node is released, everyone must converge to :ready.
    test "no node trusts its occupancy until every member announces the view",
         %{scope: scope} do
      t_node = node()

      check_trace(
        fn ->
          # Settled 2-node cluster {B, T}.
          {:ok, p_b, b_node} = Peer.start(aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(b_node)
          start_remote_muster(p_b, scope)
          await_ready([t_node, b_node])

          # C's name is chosen upfront so the group can be picked from ring
          # math: T holds a group whose router lands on the FRESH node C in
          # the final view — the worst case, since C is the node whose table
          # nobody has agreed on yet.
          c_name = ~c"muster_barrier_c_#{System.unique_integer([:positive])}"
          c_node = :"#{c_name}@127.0.0.1"
          view3 = Enum.sort([t_node, b_node, c_node])
          hash3 = :erlang.phash2(view3)
          group = pick_group([{view3, c_node}])

          member = spawn(fn -> Process.sleep(:infinity) end)
          :ok = Muster.join(scope, group, member)
          {:ok, r0} = Muster.router(scope, group)
          assert t_node in occupancy_on(r0, scope, group)

          # Park B's rebalance into the 3-node view until the test emits the
          # release event: B is the "still mid-rebalance" third node of the
          # README scenario. (Its discovery ack — carrying its OLD view — is
          # sent before the parked rebalance, so C does learn about B.)
          force_ordering(
            %{:"$kind" => :test_release_b},
            %{:"$kind" => :muster_rebalance_start, node: ^b_node, to: ^view3}
          )

          {:ok, p_c, ^c_node} = Peer.start(name: c_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(c_node)
          start_remote_muster(p_c, scope)

          # T and C adopt the 3-node view — with B parked neither can go past
          # :converging, so their rebalances into it must end exactly there...
          for n <- [t_node, c_node] do
            assert {:ok, _} =
                     block_until(
                       %{
                         :"$kind" => :muster_status_change,
                         to: :converging,
                         node: ^n,
                         view_hash: ^hash3
                       },
                       10_000
                     )
          end

          # ...and T's rebalance has snapshotted the group to the new router C
          # (the event fires after the snapshot is committed) — the data is in
          # place...
          assert {:ok, %{groups: snapshotted}} =
                   block_until(
                     %{:"$kind" => :muster_node_state_received, node: ^c_node, source: ^t_node},
                     10_000
                   )

          assert group in snapshotted
          assert t_node in occupancy_on(c_node, scope, group)

          # ...but B's announcement of the view is missing, so neither T nor C
          # may trust an occupancy table: both are stuck in :converging (only a
          # marker from B could advance them, and B is parked) and report
          # can_decide? == false (the flooding fallback).
          assert status(scope) == :converging
          assert remote_status(p_c, scope) == :converging
          refute Muster.can_decide?(scope, hash3)
          refute :erpc.call(c_node, Muster, :can_decide?, [scope, hash3])

          # Routing itself still works while :converging — it targets the ring
          # node; only the router-side table trust is withheld.
          assert {:ok, ^c_node} = Muster.router(scope, group)

          # Release B. It rebalances, announces the view, and every node must
          # now converge all the way to :ready.
          tp(:test_release_b, %{})
          await_ready(view3)

          assert Muster.can_decide?(scope, hash3)
          assert :erpc.call(c_node, Muster, :can_decide?, [scope, hash3])

          %{view3: view3, hash3: hash3}
        end,
        fn result, trace ->
          # The barrier held the WHOLE cluster down while one announcement was
          # missing: no node emitted :ready for the final view before the
          # release event.
          release_at = Enum.find_index(trace, &(&1[:"$kind"] == :test_release_b))
          assert release_at

          ready3 =
            trace
            |> Enum.with_index()
            |> Enum.filter(fn {e, _} ->
              e[:"$kind"] == :muster_status_change and e[:to] == :ready and
                e[:view_hash] == result.hash3
            end)

          ready_nodes = ready3 |> Enum.map(fn {e, _} -> e.node end) |> Enum.uniq() |> Enum.sort()
          assert ready_nodes == result.view3
          assert Enum.all?(ready3, fn {_, idx} -> idx > release_at end)
        end
      )
    end
  end

  describe "queued vacancy across a rebalance" do
    setup do
      scope = :"muster_vac_#{System.unique_integer([:positive])}"
      # Long flush interval: the test triggers the flush deterministically
      # AFTER the rebalance, so the queued vacancy must be routed by the ring
      # of the NEW view.
      start_supervised!(spec(scope, vacancy_cooldown_ms: 50, vacant_flush_interval_ms: 60_000))
      %{scope: scope}
    end

    # README rebalance step 3 + "Stale router entries": a group sitting in
    # :vacant_queued when membership changes is NOT re-announced (we don't hold
    # it), the old router's now-stale row is GC'd by its own sweep once the
    # source demonstrably agrees on the view (this is the positive counterpart
    # of the no-wrongful-drops test above), and the eventual flush routes the
    # vacancy to the group's CURRENT router — not the one it was queued under.
    test "not announced, stale row swept on the old router, flush targets the new router",
         %{scope: scope} do
      t_node = node()

      check_trace(
        fn ->
          # Settled 2-node cluster {O, T}.
          {:ok, p_o, o_node} = Peer.start(aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(o_node)
          start_remote_muster(p_o, scope)
          await_ready([t_node, o_node])

          # Routed to O before C joins, to C afterwards.
          c_name = ~c"muster_vac_c_#{System.unique_integer([:positive])}"
          c_node = :"#{c_name}@127.0.0.1"
          view3 = Enum.sort([t_node, o_node, c_node])
          group = pick_group([{[t_node, o_node], o_node}, {view3, c_node}])

          member = spawn(fn -> Process.sleep(:infinity) end)
          :ok = Muster.join(scope, group, member)
          assert t_node in occupancy_on(o_node, scope, group)

          # Vacate. The cooldown (50ms) expires and the vacancy is queued, but
          # never flushed (interval 60s) — O still believes we hold the group.
          :ok = Muster.leave(scope, group, member)

          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_group_state,
                       node: ^t_node,
                       group: ^group,
                       state: :vacant_queued
                     },
                     5_000
                   )

          # C joins: the group's router moves O -> C while the vacancy is
          # still queued.
          {:ok, p_c, ^c_node} = Peer.start(name: c_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(c_node)
          start_remote_muster(p_c, scope)

          await_ready(view3)

          # The new router was never told about the group (we don't hold it)...
          assert occupancy_on(c_node, scope, group) == []

          # ...and the old router sweeps its stale row — at the latest on its
          # :converging -> :ready transition, which re-judges every row under
          # the now-agreed view. The drop event fires after the delete, so the
          # row is gone once it is collected.
          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_drop_stale_entry,
                       node: ^o_node,
                       group: ^group,
                       source: ^t_node
                     },
                     10_000
                   )

          assert occupancy_on(o_node, scope, group) == []

          # Flush now: the vacancy must be sent to the CURRENT router, C.
          trigger_flush(scope)

          assert {:ok, batch} =
                   block_until(
                     %{:"$kind" => :muster_vacant_batch, :"$span" => :start, source: ^t_node},
                     5_000
                   )

          assert batch.node == c_node
          assert group in batch.groups

          # Batch acknowledged: the group is forgotten on the source
          # (state: nil is the delete_group_state transition).
          assert {:ok, _} =
                   block_until(
                     %{:"$kind" => :muster_group_state, node: ^t_node, group: ^group, state: nil},
                     5_000
                   )

          %{group: group, t_node: t_node, o_node: o_node, c_node: c_node}
        end,
        fn result, trace ->
          # The rebalance never announced the queued group to anyone.
          assert [] =
                   of_kind(:muster_node_state_received, trace)
                   |> Enum.filter(&(result.group in &1.groups))

          # Exactly one rightful drop: the old router clearing its stale row.
          drops =
            of_kind(:muster_drop_stale_entry, trace)
            |> Enum.filter(&(&1.group == result.group and &1.source == result.t_node))

          assert Enum.map(drops, & &1.node) == [result.o_node]

          # And no vacant batch for the group ever targeted the OLD router.
          refute of_kind(:muster_vacant_batch, trace)
                 |> Enum.any?(
                   &(&1[:"$span"] == :start and &1.node == result.o_node and
                       result.group in &1.groups)
                 )
        end
      )
    end
  end

  describe "rebalance RPC failure (injected crash)" do
    setup do
      scope = :"muster_inject_#{System.unique_integer([:positive])}"
      start_supervised!(spec(scope, vacant_flush_interval_ms: 100))
      %{scope: scope}
    end

    # README "Rebalance RPC failure": if any :receive_node_state call raises
    # or returns {:error, _}, do_rebalance re-raises and Scope CRASHES; the
    # supervisor restarts it, init/1 resets it to a single-node view, rebuilds
    # group_states from the surviving Partition tables, and re-discovers — and
    # the next rebalance re-announces everything it holds.
    #
    # The failure is injected at the worst possible moment: the very FIRST
    # snapshot T sends to the fresh router C, i.e. exactly when the group's
    # routing moved onto a node that knows nothing about it. inject_crash
    # kills the receiver-side RPC worker at the :muster_node_state_received
    # trace point (recover_after(1): only the first attempt dies), so T's
    # snapshot RPC fails, T's Scope crashes mid-rebalance, and the entire
    # documented recovery pipeline has to run for the cluster to converge.
    test "the source Scope crashes when its snapshot RPC fails, restarts, and re-announces",
         %{scope: scope} do
      t_node = node()

      check_trace(
        fn ->
          # Settled 2-node cluster {R, T}.
          {:ok, p_r, r_node} = Peer.start(aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(r_node)
          start_remote_muster(p_r, scope)
          await_ready([t_node, r_node])

          # Routed to R before C joins, to C afterwards — so T's rebalance
          # into the 3-node view MUST snapshot C.
          c_name = ~c"muster_inject_c_#{System.unique_integer([:positive])}"
          c_node = :"#{c_name}@127.0.0.1"
          view3 = Enum.sort([t_node, r_node, c_node])
          hash3 = :erlang.phash2(view3)
          group = pick_group([{[t_node, r_node], r_node}, {view3, c_node}])

          member = spawn(fn -> Process.sleep(:infinity) end)
          :ok = Muster.join(scope, group, member)
          assert t_node in occupancy_on(r_node, scope, group)

          inject_crash(
            %{:"$kind" => :muster_node_state_received, node: ^c_node, source: ^t_node},
            :snabbkaffe_nemesis.recover_after(1)
          )

          {:ok, p_c, ^c_node} = Peer.start(name: c_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(c_node)
          start_remote_muster(p_c, scope)

          # The injected crash fires on C's RPC worker (nemesis records it as
          # a :snabbkaffe_crash event carrying the original event's fields)...
          assert {:ok, _} =
                   block_until(
                     %{:"$kind" => :snabbkaffe_crash, node: ^c_node, source: ^t_node},
                     10_000
                   )

          # ...failing T's rebalance and crashing T's Scope. Reaching :ready
          # for the 3-node view is only possible after the full recovery —
          # the crashed rebalance died before announcing anything to anyone.
          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_status_change,
                       to: :ready,
                       node: ^t_node,
                       view_hash: ^hash3
                     },
                     15_000
                   )

          # R can likewise only reach :ready for the 3-node view after the
          # recovery (the crashed rebalance died before announcing it).
          await_ready(view3, nodes: [r_node])

          # The post-restart rebalance re-announced the group to its router:
          # the retried snapshot is the only one C ever collects (the crashed
          # attempt died at its trace point, before collection), and the event
          # fires after the rows are committed. C wiped T's rows when it saw
          # T's Scope die, so the row can only come from this retry.
          assert {:ok, %{groups: healed}} =
                   block_until(
                     %{:"$kind" => :muster_node_state_received, node: ^c_node, source: ^t_node},
                     15_000
                   )

          assert group in healed

          # C's :ready count for the 3-node view is nondeterministic — the
          # crashed snapshot already delivered T's marker, so C may or may not
          # have converged once BEFORE it saw T's Scope die — so an Nth-event
          # block_until has no sound N here: poll its CURRENT state instead.
          wait_until(fn ->
            :erpc.call(c_node, Muster, :members, [scope]) == view3 and
              remote_status(p_c, scope) == :ready
          end)

          # The local membership survived the crash — Partition tables are
          # owned by the Supervisor, not Scope.
          assert {:ok, ^c_node} = Muster.router(scope, group)
          assert t_node in occupancy_on(c_node, scope, group)
          assert Muster.local_member_count(scope, group) == 1

          # And the recovered Scope is fully functional.
          assert :ok = Muster.join(scope, group, spawn(fn -> Process.sleep(:infinity) end))

          %{group: group, t_node: t_node, c_node: c_node, hash3: hash3}
        end,
        fn result, trace ->
          # The crash fired exactly once: at the first snapshot to C.
          assert of_kind(:snabbkaffe_crash, trace)
                 |> Enum.count(&(&1[:node] == result.c_node and &1[:source] == result.t_node)) ==
                   1

          # Exactly one snapshot from T was applied-and-collected on C — the
          # post-restart retry (the crashed attempt dies at its trace point,
          # which is never collected) — and it carried the group.
          assert [%{groups: groups}] =
                   of_kind(:muster_node_state_received, trace)
                   |> Enum.filter(&(&1.node == result.c_node and &1.source == result.t_node))

          assert result.group in groups

          # T entered a rebalance into the 3-node view at least twice: the
          # crashed attempt and the successful post-restart one.
          t_rebalances =
            of_kind(:muster_rebalance_start, trace)
            |> Enum.count(&(&1.node == result.t_node and &1.view_hash == result.hash3))

          assert t_rebalances >= 2
        end
      )
    end
  end

  describe "router Scope crash recovery" do
    setup do
      scope = :"muster_crash_#{System.unique_integer([:positive])}"
      start_supervised!(spec(scope, vacant_flush_interval_ms: 100))
      %{scope: scope}
    end

    # README "Scope crash for other reasons" / "Rebalance RPC failure": a
    # router Scope that dies takes its occupancy table with it (only the
    # Partition tables survive, on the Supervisor). Peers see the monitor DOWN
    # and rebalance away; the restarted Scope rediscovers the cluster, and the
    # sources' rebalances back into the rejoined view re-snapshot it — healing
    # the router's occupancy with no manual intervention, after which every
    # node converges to :ready again.
    test "a crashed router Scope is restarted and re-learns occupancy from source snapshots",
         %{scope: scope} do
      t_node = node()

      check_trace(
        fn ->
          {:ok, p_r, r_node} = Peer.start(aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(r_node)
          start_remote_muster(p_r, scope)

          view2 = Enum.sort([t_node, r_node])
          await_ready(view2)

          group = group_routed_to(scope, r_node)
          member = spawn(fn -> Process.sleep(:infinity) end)
          :ok = Muster.join(scope, group, member)
          assert t_node in occupancy_on(r_node, scope, group)

          # Kill the router's Scope. Its occupancy table dies with it.
          scope_pid = :erpc.call(r_node, Process, :whereis, [Forum.Supervisor.name(scope)])
          Process.monitor(scope_pid)
          true = :erpc.call(r_node, Process, :exit, [scope_pid, :kill])
          assert_receive {:DOWN, _, _, ^scope_pid, _}

          # T sees the monitor DOWN and rebalances down to itself (this `to`
          # matches no other rebalance in the test)...
          assert {:ok, _} =
                   block_until(
                     %{:"$kind" => :muster_rebalance_start, node: ^t_node, to: [^t_node]},
                     10_000
                   )

          # ...then the restarted Scope re-pairs, and T's rebalance back into
          # the 2-node view re-snapshots the router — the heal. This is the
          # only :receive_node_state of the whole test (the original join
          # travelled as :occupied), so seeing it proves the heal really fired.
          assert {:ok, %{groups: healed}} =
                   block_until(
                     %{:"$kind" => :muster_node_state_received, node: ^r_node, source: ^t_node},
                     10_000
                   )

          assert group in healed

          # Both nodes re-converge to :ready for the 2-node view — their
          # SECOND time there (the first was the original formation), hence
          # nth: 2.
          await_ready(view2, nth: 2)

          # The healed router knows T holds the group again, and the member is
          # still registered locally (Partition tables survive Scope's death).
          assert t_node in occupancy_on(r_node, scope, group)
          assert Muster.local_member_count(scope, group) == 1

          %{group: group, r_node: r_node, t_node: t_node}
        end,
        fn result, trace ->
          # Exactly one snapshot from T landed on the router — the post-crash
          # heal — and it carried the group.
          assert [%{groups: groups}] =
                   of_kind(:muster_node_state_received, trace)
                   |> Enum.filter(&(&1.node == result.r_node and &1.source == result.t_node))

          assert result.group in groups
        end
      )
    end
  end

  describe "cascading joins — a second node joins before the first rebalance converges" do
    setup do
      scope = :"muster_cascade_#{System.unique_integer([:positive])}"
      start_supervised!(spec(scope, vacant_flush_interval_ms: 100))
      %{scope: scope}
    end

    # The rolling-deploy shape: C joins, and D joins while the cluster is
    # still :converging on the C view — the holder must re-hand its group to
    # the FINAL router, and the cluster must converge on the final view only.
    #
    # The overlap is forced deterministically: R's rebalance into the 3-node
    # view is parked, D is started, and only then is R released. T therefore
    # runs its second rebalance straight out of :converging, never having
    # been :ready, and must re-hand its group from the intermediate router C
    # to the final router D. The victim group is picked from ring math:
    # routed to C in {T, R, C} and to D in {T, R, C, D}, so the router moves
    # on BOTH joins.
    #
    # Note the barrier's exact (and intended) semantics here: the HOLDER, T,
    # must never go :ready for the intermediate view (R's announcement of it
    # cannot exist before T has already adopted the 4-node view). The parked
    # laggard R, however, MAY transiently go :ready for the stale view after
    # release — its queued hash3 markers from T and C are mutually consistent,
    # and the data for that view was committed before they were sent — until
    # the higher-seq hash4 markers supersede them (newest-seq-wins). That
    # stale agreement is safe: any sender already on the final view carries a
    # mismatching hash, so R floods for it. What the barrier guarantees is
    # that every node's LAST word is :ready for the final view.
    test "the held group lands on the final router and the intermediate view is never trusted",
         %{scope: scope} do
      t_node = node()

      check_trace(
        fn ->
          # Settled 2-node cluster {T, R}.
          {:ok, p_r, r_node} = Peer.start(aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(r_node)
          start_remote_muster(p_r, scope)
          await_ready([t_node, r_node])

          c_name = ~c"muster_cascade_c_#{System.unique_integer([:positive])}"
          c_node = :"#{c_name}@127.0.0.1"
          d_name = ~c"muster_cascade_d_#{System.unique_integer([:positive])}"
          d_node = :"#{d_name}@127.0.0.1"
          view3 = Enum.sort([t_node, r_node, c_node])
          view4 = Enum.sort([t_node, r_node, c_node, d_node])
          hash3 = :erlang.phash2(view3)
          hash4 = :erlang.phash2(view4)

          # The group's router moves on EVERY membership change: R -> C -> D.
          # Pinning the initial router to R (not T) keeps T a pure source, so
          # the only rows ever swept for the group are the two superseded
          # routers' (R's and C's).
          group =
            pick_group([{[t_node, r_node], r_node}, {view3, c_node}, {view4, d_node}])

          :ok = Muster.join(scope, group, spawn(fn -> Process.sleep(:infinity) end))
          assert {:ok, ^r_node} = Muster.router(scope, group)
          assert t_node in occupancy_on(r_node, scope, group)

          # Park R's rebalance into the 3-node view until the test emits the
          # release event: with R never announcing that view, no node can
          # reach :ready for it, so D's join below is guaranteed to land
          # mid-convergence.
          force_ordering(
            %{:"$kind" => :test_release_r},
            %{:"$kind" => :muster_rebalance_start, node: ^r_node, to: ^view3}
          )

          {:ok, p_c, ^c_node} = Peer.start(name: c_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(c_node)
          start_remote_muster(p_c, scope)

          # R has registered C (so its parked rebalance is the view3 one), and
          # T's first rebalance handed the group to the intermediate router C.
          assert {:ok, _} =
                   block_until(
                     %{:"$kind" => :muster_peer_registered, node: ^r_node, peer: ^c_node},
                     10_000
                   )

          assert {:ok, %{groups: snap_c}} =
                   block_until(
                     %{:"$kind" => :muster_node_state_received, node: ^c_node, source: ^t_node},
                     10_000
                   )

          assert group in snap_c

          # SECOND join, while everyone is still :converging on the C view.
          {:ok, p_d, ^d_node} = Peer.start(name: d_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(d_node)
          start_remote_muster(p_d, scope)

          # T rebalances again — straight out of :converging — and re-hands
          # the group to the final router D.
          assert {:ok, %{groups: snap_d}} =
                   block_until(
                     %{:"$kind" => :muster_node_state_received, node: ^d_node, source: ^t_node},
                     15_000
                   )

          assert group in snap_d

          # The overlap state: T has already adopted the 4-node view but
          # cannot be :ready (R, still parked, has announced neither view).
          # Polling, not block_until: D's snapshot event fires while T is
          # still inside do_rebalance (:rebalancing), and the :converging it
          # then lands on is carried over from the first rebalance, so no new
          # status event is emitted.
          wait_until(fn ->
            Muster.view_hash(scope) == hash4 and status(scope) == :converging
          end)

          refute Muster.can_decide?(scope, hash4)

          # Release R: it finishes the stale view3 rebalance, then processes
          # the queued discovery from D and rebalances into view4 — and the
          # whole cluster converges on the FINAL view only.
          tp(:test_release_r, %{})
          await_ready(view4)

          assert {:ok, ^d_node} = Muster.router(scope, group)
          assert t_node in occupancy_on(d_node, scope, group)
          assert Muster.can_decide?(scope, hash4)

          # Both superseded routers' rows are judged stale once their source
          # demonstrably agrees on the view, and swept (the drop events fire
          # after the deletes).
          for n <- [r_node, c_node] do
            assert {:ok, _} =
                     block_until(
                       %{
                         :"$kind" => :muster_drop_stale_entry,
                         node: ^n,
                         group: ^group,
                         source: ^t_node
                       },
                       10_000
                     )

            assert occupancy_on(n, scope, group) == []
          end

          %{
            group: group,
            t_node: t_node,
            r_node: r_node,
            c_node: c_node,
            d_node: d_node,
            hash3: hash3,
            hash4: hash4,
            view4: view4
          }
        end,
        fn result, trace ->
          status_changes = of_kind(:muster_status_change, trace)

          # The holder NEVER trusted the intermediate 3-node view: T did not
          # emit :ready for its hash (only the released laggard R may, see the
          # note above the test).
          assert Enum.count(
                   status_changes,
                   &(&1.node == result.t_node and &1.to == :ready and &1.view_hash == result.hash3)
                 ) == 0

          # Every node reached :ready for the final view, and that is every
          # node's LAST status word — a transient stale :ready (R's) must have
          # been superseded, never the other way around.
          last_status =
            status_changes
            |> Enum.group_by(& &1.node)
            |> Map.new(fn {n, events} -> {n, List.last(events)} end)

          assert Enum.sort(Map.keys(last_status)) == result.view4

          for {_n, e} <- last_status do
            assert e.to == :ready
            assert e.view_hash == result.hash4
          end

          # The group was snapshotted exactly twice — to the intermediate
          # router C, then to the final router D, in that order.
          assert [%{node: c}, %{node: d}] =
                   of_kind(:muster_node_state_received, trace)
                   |> Enum.filter(&(&1.source == result.t_node and result.group in &1.groups))

          assert c == result.c_node
          assert d == result.d_node

          # Both superseded routers — R (pre-join) and C (intermediate) —
          # swept their stale row exactly once; the final router D never
          # dropped it.
          drops =
            of_kind(:muster_drop_stale_entry, trace)
            |> Enum.filter(&(&1.group == result.group and &1.source == result.t_node))

          assert Enum.sort(Enum.map(drops, & &1.node)) ==
                   Enum.sort([result.r_node, result.c_node])
        end
      )
    end
  end

  describe "node death — groups rebalance onto the remaining nodes" do
    setup do
      scope = :"muster_death_#{System.unique_integer([:positive])}"
      start_supervised!(spec(scope, vacant_flush_interval_ms: 100))
      %{scope: scope}
    end

    # README "Trigger" + "Vacant-time RPC failure" cleanup: when a node leaves
    # the cluster, every survivor sees its Scope's monitor DOWN, wipes the
    # occupancy rows keyed by the dead node, recomputes the ring over the
    # remaining members, re-announces its held groups to their new routers,
    # and converges back to :ready. The three victim groups are picked from
    # ring math so each documents one facet:
    #   g_t    held by T, routed to D before / S after — T must re-tell S
    #   g_s    held by S, routed to D before / T after — S must re-tell T
    #   g_dead held by D alone, routed to T throughout — T's :DOWN wipe must
    #          clear the {g_dead, D} row (nothing else ever cleans a dead
    #          source's rows; D can't flush a vacancy, it's gone)
    test "a dead node's routed groups move to survivors and its source rows are wiped",
         %{scope: scope} do
      t_node = node()

      check_trace(
        fn ->
          # Settled 2-node cluster {T, S} (S = the surviving peer).
          {:ok, p_s, s_node} = Peer.start(aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(s_node)
          start_remote_muster(p_s, scope)
          view2 = Enum.sort([t_node, s_node])
          await_ready(view2)

          # D's name is fixed upfront so the victim groups can be picked
          # before it boots.
          d_name = ~c"muster_death_d_#{System.unique_integer([:positive])}"
          d_node = :"#{d_name}@127.0.0.1"
          view3 = Enum.sort([t_node, s_node, d_node])
          g_t = pick_group([{view3, d_node}, {view2, s_node}])
          g_s = pick_group([{view3, d_node}, {view2, t_node}])
          g_dead = pick_group([{view3, t_node}, {view2, t_node}])

          {:ok, p_d, ^d_node} = Peer.start(name: d_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(d_node)
          start_remote_muster(p_d, scope)
          await_ready(view3)

          :ok = Muster.join(scope, g_t, spawn(fn -> Process.sleep(:infinity) end))
          :ok = :peer.call(p_s, MusterPeerAux, :join, [scope, g_s])
          :ok = :peer.call(p_d, MusterPeerAux, :join, [scope, g_dead])

          # Every router knows its group (join/3 only returns :ok once the
          # router has been told).
          assert t_node in occupancy_on(d_node, scope, g_t)
          assert s_node in occupancy_on(d_node, scope, g_s)
          assert d_node in occupancy_on(t_node, scope, g_dead)

          # Kill the node. Both survivors must detect the DOWN, rebalance to
          # {T, S} and re-converge — their SECOND :ready at view2, hence nth: 2.
          :ok = stop_supervised({:peer, d_name})
          await_ready(view2, nth: 2)

          # The survivors agree the cluster is just {T, S}...
          assert Muster.members(scope) == view2
          assert :erpc.call(s_node, Muster, :members, [scope]) == view2

          # ...the groups whose router died moved onto survivors, and the new
          # routers were re-told by the holders...
          assert {:ok, ^s_node} = Muster.router(scope, g_t)
          assert t_node in occupancy_on(s_node, scope, g_t)
          assert {:ok, ^t_node} = Muster.router(scope, g_s)
          assert s_node in occupancy_on(t_node, scope, g_s)

          # ...and the dead node survives nowhere as a source: the group only
          # it held is gone, and no occupancy row on any survivor lists it.
          assert occupancy_on(t_node, scope, g_dead) == []
          assert occupancy_on(s_node, scope, g_dead) == []

          dumps = [
            {t_node, GenServer.call(Forum.Supervisor.name(scope), :dump)},
            {s_node, :erpc.call(s_node, GenServer, :call, [Forum.Supervisor.name(scope), :dump])}
          ]

          for {n, dump} <- dumps, {group, sources} <- dump.occupancy do
            refute d_node in sources,
                   "#{inspect(n)} still lists the dead node as a source of #{inspect(group)}"
          end

          # The cluster is fully functional: a fresh join for the group the
          # dead node used to hold succeeds against its current router.
          assert :ok = Muster.join(scope, g_dead, spawn(fn -> Process.sleep(:infinity) end))

          %{
            g_t: g_t,
            g_s: g_s,
            t_node: t_node,
            s_node: s_node,
            view2: view2,
            view3: view3
          }
        end,
        fn result, trace ->
          # Each survivor rebalanced view3 -> view2 exactly once (the `from`
          # match excludes the original 1 -> 2 node formation rebalances).
          for n <- [result.t_node, result.s_node] do
            assert of_kind(:muster_rebalance_start, trace)
                   |> Enum.count(
                     &(&1.node == n and &1.from == result.view3 and &1.to == result.view2)
                   ) == 1
          end

          # The post-death snapshots really carried the moved groups: T
          # re-told S about g_t, and S re-told T about g_s.
          assert of_kind(:muster_node_state_received, trace)
                 |> Enum.any?(
                   &(&1.node == result.s_node and &1.source == result.t_node and
                       result.g_t in &1.groups)
                 )

          assert of_kind(:muster_node_state_received, trace)
                 |> Enum.any?(
                   &(&1.node == result.t_node and &1.source == result.s_node and
                       result.g_s in &1.groups)
                 )
        end
      )
    end
  end

  describe "network partition — split rebalances independently, heal re-merges" do
    setup do
      scope = :"muster_split_#{System.unique_integer([:positive])}"
      start_supervised!(spec(scope, vacant_flush_interval_ms: 100))
      %{scope: scope}
    end

    # README "Network partition": nodes that lose sight of each other detect
    # the peer DOWN, rebalance independently, and route to whoever they can
    # see; on heal, discovery -> rebalance merges the sub-clusters. Here the
    # split is between the two PEERS while T stays connected to both — the
    # asymmetric case, harsher than a clean split: each peer's view {T, self}
    # and T's view {T, A, B} disagree, so the readiness barrier must keep
    # EVERY node in :converging (routers flood, never trust occupancy) until
    # the heal, and the stale-entry sweeps run during the split must not
    # delete T's snapshotted rows (T never agreed to the split views).
    test "peers that lose sight of each other rebalance apart and re-converge on heal",
         %{scope: scope} do
      t_node = node()

      check_trace(
        fn ->
          # Both peers run with -connect_all false: their globals neither
          # auto-mesh (the test wires the A<->B connection explicitly) nor
          # report the deliberate disconnect to T's global, whose
          # prevent_overlapping_partitions logic would otherwise tear down
          # T's own links to "fix" the partial connectivity.
          args = [~c"-connect_all", ~c"false"]

          {:ok, p_a, a_node} = Peer.start(aux_mod: @aux_mod, args: args)
          :ok = :snabbkaffe.forward_trace(a_node)
          start_remote_muster(p_a, scope)
          await_ready([t_node, a_node])

          {:ok, p_b, b_node} = Peer.start(aux_mod: @aux_mod, args: args)
          true = :erpc.call(b_node, Node, :connect, [a_node])
          :ok = :snabbkaffe.forward_trace(b_node)
          start_remote_muster(p_b, scope)

          view3 = Enum.sort([t_node, a_node, b_node])
          hash3 = :erlang.phash2(view3)
          await_ready(view3)

          # T holds one group routed to each peer.
          g_a = group_routed_to(scope, a_node)
          g_b = group_routed_to(scope, b_node)
          :ok = Muster.join(scope, g_a, spawn(fn -> Process.sleep(:infinity) end))
          :ok = Muster.join(scope, g_b, spawn(fn -> Process.sleep(:infinity) end))
          assert t_node in occupancy_on(a_node, scope, g_a)
          assert t_node in occupancy_on(b_node, scope, g_b)

          # Split A <-/-> B. Each peer sees the other's Scope DOWN and
          # rebalances down to {T, self}; T keeps the 3-node view nobody
          # agrees with any more. (Polling, not block_until: whether a peer's
          # earlier formation passed through the same {T, self} view — and so
          # how many matching trace events exist — is timing-dependent.)
          true = :erpc.call(a_node, Node, :disconnect, [b_node])

          wait_until(fn ->
            :erpc.call(a_node, Muster, :members, [scope]) == Enum.sort([t_node, a_node]) and
              :erpc.call(b_node, Muster, :members, [scope]) == Enum.sort([t_node, b_node]) and
              :erpc.call(a_node, MusterPeerAux, :status, [scope]) == :converging and
              :erpc.call(b_node, MusterPeerAux, :status, [scope]) == :converging and
              status(scope) == :converging
          end)

          # Nobody trusts an occupancy table while views disagree — routers
          # flood (over-deliver, never miss)...
          refute Muster.can_decide?(scope, hash3)
          refute :erpc.call(a_node, Muster, :can_decide?, [scope, hash3])
          refute :erpc.call(b_node, Muster, :can_decide?, [scope, hash3])

          # ...but senders still route against their own settled ring.
          assert {:ok, ^a_node} = Muster.router(scope, g_a)

          # Heal. nodeup fires on both peers, discovery re-pairs them, every
          # node rebalances back into the 3-node view and re-converges — the
          # SECOND :ready at view3, hence nth: 2.
          true = :erpc.call(a_node, Node, :connect, [b_node])
          await_ready(view3, nth: 2, timeout: 20_000)

          # The snapshotted rows survived the whole split/heal cycle, and the
          # merged cluster trusts its tables again.
          assert t_node in occupancy_on(a_node, scope, g_a)
          assert t_node in occupancy_on(b_node, scope, g_b)
          assert Muster.can_decide?(scope, hash3)
          assert :erpc.call(a_node, Muster, :members, [scope]) == view3
          assert :erpc.call(b_node, Muster, :members, [scope]) == view3

          %{g_a: g_a, g_b: g_b, t_node: t_node}
        end,
        fn result, trace ->
          # The sweeps run during the split never judged T's rows under a view
          # T hadn't agreed to: neither group was dropped anywhere.
          drops =
            of_kind(:muster_drop_stale_entry, trace)
            |> Enum.filter(&(&1.source == result.t_node and &1.group in [result.g_a, result.g_b]))

          assert drops == []
        end
      )
    end
  end

  describe "node restart with the same name — announce-watermark seq regression" do
    setup do
      scope = :"muster_restart_#{System.unique_integer([:positive])}"
      # Small heartbeat so the "stuck despite the heartbeat backstop" proof is
      # quick: if anything could heal the stuck node, a 200ms heartbeat would.
      start_supervised!(
        spec(scope, vacant_flush_interval_ms: 100, view_heartbeat_interval_ms: 200)
      )

      %{scope: scope}
    end

    test "a same-named restart with a lower seq still re-converges (member_views cleared on :DOWN)",
         %{scope: scope} do
      t_node = node()

      check_trace(
        fn ->
          s_name = ~c"muster_restart_s_#{System.unique_integer([:positive])}"
          s_node = :"#{s_name}@127.0.0.1"

          # --- {T, S} forms and converges (S incarnation #1) ---------------
          {:ok, p_s, ^s_node} = Peer.start(name: s_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(s_node)
          start_remote_muster_fast_heartbeat(p_s, scope)
          await_ready([t_node, s_node])

          # Burn the global monotonic counter on S so its NEXT rebalance stamps
          # an announce watermark ~100M above the fresh-VM base. A same-named
          # restart starts from that base and never climbs anywhere near it
          # before re-announcing, so its seq is guaranteed lower.
          :ok = :peer.call(p_s, MusterPeerAux, :burn, [100_000_000])

          # --- Z joins -> {T, S, Z}: S re-announces with the HIGH watermark --
          z_name = ~c"muster_restart_z_#{System.unique_integer([:positive])}"
          {:ok, p_z, z_node} = Peer.start(name: z_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(z_node)
          start_remote_muster_fast_heartbeat(p_z, scope)

          view_tsz = Enum.sort([t_node, s_node, z_node])
          hash_tsz = :erlang.phash2(view_tsz)
          await_ready(view_tsz)

          # T now holds S's HIGH watermark for the {T,S,Z} view. Capture it.
          dump_tsz = GenServer.call(Forum.Supervisor.name(scope), :dump)
          {^hash_tsz, stale_seq} = dump_tsz.member_views[s_node]

          # --- Kill S (incarnation #1) then Z, so the final view is {T,S} ----
          # which differs from the stale {T,S,Z} view, exposing the regression
          # if T were to keep S's stale watermark.
          :ok = stop_supervised({:peer, s_name})
          wait_until(fn -> Muster.members(scope) == Enum.sort([t_node, z_node]) end)

          :ok = stop_supervised({:peer, z_name})
          wait_until(fn -> Muster.members(scope) == [t_node] end)

          # The fix: T dropped S's member_views entry when S left, so there is
          # no stale high-seq watermark left to strand the restart. (Against the
          # unfixed code this entry is still {hash_tsz, stale_seq}.)
          dump_alone = GenServer.call(Forum.Supervisor.name(scope), :dump)
          refute Map.has_key?(dump_alone.member_views, s_node)

          # --- S restarts under the SAME name (incarnation #2, fresh VM) -----
          tp(:test_s_rejoined, %{})
          {:ok, p_s2, ^s_node} = Peer.start(name: s_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(s_node)
          start_remote_muster_fast_heartbeat(p_s2, scope)

          view_ts = Enum.sort([t_node, s_node])
          hash_ts = :erlang.phash2(view_ts)

          # S (fresh) converges to :ready for {T,S}: it has no stale entry for T,
          # so it accepts T's announcements. Wait via the trace so we don't race
          # S's ring/Scope startup with an :erpc into it. nth: 2 because S's
          # incarnation #1 (same node name -> same hash) already emitted :ready
          # for {T,S} at the original formation; we want the post-restart one.
          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_status_change,
                       to: :ready,
                       node: ^s_node,
                       view_hash: ^hash_ts
                     },
                     2,
                     15_000,
                     :infinity
                   )

          assert :erpc.call(s_node, Muster, :members, [scope]) == view_ts

          # T learns S is a member again (rebalances {T} -> {T,S})...
          wait_until(fn -> Muster.members(scope) == view_ts end)

          # The dangerous condition is genuinely present: S's fresh announce seq
          # is LOWER than the watermark T held from the dead incarnation (proven
          # with real values, no hard-coded base). The fix must make T
          # re-converge ANYWAY — it cannot lean on seqs to tell incarnations
          # apart.
          s2_seq = :peer.call(p_s2, MusterPeerAux, :current_seq, [])
          assert s2_seq < stale_seq

          # RECOVERY: T must reach :ready for the live {T,S} view despite the
          # regressed seq — its SECOND :ready for that view (the first was
          # incarnation #1's formation), hence nth: 2. With the fix, T cleared
          # member_views[S] when S left, so S's fresh announcement is accepted
          # rather than rejected by newest-seq-wins.
          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_status_change,
                       to: :ready,
                       node: ^t_node,
                       view_hash: ^hash_ts
                     },
                     2,
                     15_000,
                     :infinity
                   )

          assert status(scope) == :ready
          assert Muster.can_decide?(scope, hash_ts)

          # T's member_views[S] now reflects S's FRESH announcement for the live
          # {T,S} view — and carries the lower, post-restart seq, proving the
          # stale high-seq {T,S,Z} watermark was discarded, not merely matched.
          dump_final = GenServer.call(Forum.Supervisor.name(scope), :dump)
          assert {^hash_ts, healed_seq} = dump_final.member_views[s_node]
          assert healed_seq < stale_seq

          %{
            t_node: t_node,
            s_node: s_node,
            hash_ts: hash_ts,
            stale_seq: stale_seq,
            s2_seq: s2_seq
          }
        end,
        fn result, trace ->
          rejoin_at = Enum.find_index(trace, &(&1[:"$kind"] == :test_s_rejoined))
          assert rejoin_at

          status_changes = of_kind(:muster_status_change, trace)

          # The restarted S DID announce + converge to :ready for the final
          # {T,S} view (so the cluster genuinely converged — except T).
          assert Enum.any?(
                   status_changes,
                   &(&1.node == result.s_node and &1.to == :ready and
                       &1.view_hash == result.hash_ts)
                 )

          # And T reached :ready for the live {T,S} view AFTER the rejoin — it
          # recovered rather than stranding in :converging. (T's earlier :ready
          # for {T,S} was incarnation #1's formation, before the rejoin marker;
          # this asserts a fresh one after it.)
          t_ready_after_rejoin =
            trace
            |> Enum.with_index()
            |> Enum.any?(fn {e, idx} ->
              e[:"$kind"] == :muster_status_change and e[:node] == result.t_node and
                e[:to] == :ready and e[:view_hash] == result.hash_ts and idx > rejoin_at
            end)

          assert t_ready_after_rejoin,
                 "T never reached :ready for the live view after the same-named restart — a stale member_views watermark stranded it"

          # The mechanism really fired: the restart's seq regressed below the
          # stale watermark, yet T recovered anyway.
          assert result.s2_seq < result.stale_seq
        end
      )
    end
  end

  # Find a group that routes to `joiner` in the final cluster view but to
  # `phantom` once the phantom node is added to the ring.
  defp pick_victim_group(joiner, phantom, others) do
    final = [joiner | others]
    pick_group([{final, joiner}, {[phantom | final], phantom}])
  end

  # Find a group whose ring router is `dest` under every `{view, dest}`
  # condition simultaneously. Probes throwaway rings configured like Scope's
  # (replicas: 128). Lets a test choose its victim group from ring math before
  # the involved nodes even boot.
  defp pick_group(conditions) do
    rings = Enum.map(conditions, fn {view, dest} -> {probe_ring(Enum.sort(view)), dest} end)

    group =
      Enum.find(Stream.map(1..20_000, &:"race_group_#{&1}"), fn g ->
        Enum.all?(rings, fn {ring, dest} -> match?({:ok, ^dest}, Ring.find_node(ring, g)) end)
      end)

    Enum.each(rings, fn {ring, _} -> GenServer.stop(ring) end)
    assert group, "no group satisfying all router conditions found in 20k candidates"
    group
  end

  defp probe_ring(view) do
    name = :"muster_probe_#{System.unique_integer([:positive])}"
    {:ok, _} = Ring.start_link(name: name, replicas: 128)
    {:ok, _} = Ring.set_nodes(name, view)
    name
  end
end
