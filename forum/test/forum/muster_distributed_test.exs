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
                # long-lived process, mirroring the Census peer pattern).
                def start(scope) do
                  spawn(fn ->
                    {:ok, _} = Forum.Muster.start_link(scope, vacant_flush_interval_ms: 100)
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
              end
            end)

  defp spec(scope, opts) do
    %{id: scope, start: {Muster, :start_link, [scope, opts]}, type: :supervisor}
  end

  defp start_remote_muster(peer, scope), do: :peer.call(peer, MusterPeerAux, :start, [scope])

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

    # Probes whether a node's drop_stale_router_entries can delete occupancy
    # rows another node snapshotted to it (via receive_node_state), assuming
    # full connectivity (every node eventually discovers every live node) and
    # varying only the ORDER in which nodes process events. Two phases:
    #
    # Phase 1 — the "joiner still discovering peers" interleaving. T (this
    # node, settled with O) registers the joiner C first, rebalances to
    # {C, O, T} and pushes its snapshot to C; only then is C allowed to run
    # its own rebalances, whose first pass uses a partial 2-node view. The
    # interleaving is forced with snabbkaffe (no rebalance may start on C
    # until T's snapshot has been committed on C). This turns out to be SAFE,
    # by consistent-hashing monotonicity: a group that routes to C in the
    # final view also routes to C in every SUBSET view containing C, and a
    # joiner's intermediate views are always subsets of the final view — so
    # the drop never judges a snapshotted row as "not mine". The phase
    # asserts the row survives all the way to :ready.
    #
    # Phase 2 — an ephemeral node D joins (fully connected, everyone sees it)
    # and dies shortly after. Now ordering matters, because C transiently
    # holds a view {C, D, O, T} that is NOT a subset of the final view, and
    # the only thing that repopulates C afterwards is a one-shot heal:
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
    test "rows snapshotted to the router survive joins and an ephemeral node's churn",
         %{scope: scope} do
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

          # --- Phase 1: forced join interleaving --------------------------
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

          # --- Phase 2: ephemeral node, unlucky ordering -------------------
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
          # T snapshotted C exactly twice: the join snapshot (phase 1) and the
          # post-D-death heal (phase 2) — proving the heal really fired and
          # raced C's stale rebalance.
          snapshots =
            of_kind(:muster_node_state_received, trace)
            |> Enum.filter(&(&1.node == result.c_node and &1.source == result.t_node))

          assert length(snapshots) == 2

          # No wrongful drops: neither the (forced, worst-case) join in
          # phase 1 nor the stale {C, D, O, T} rebalance in phase 2 may
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

          reclaim_at =
            Enum.find_index(
              trace,
              &(&1[:"$kind"] == :muster_occupied and &1[:seq] == reclaim_seq)
            )

          batch_at =
            Enum.find_index(
              trace,
              &(&1[:"$kind"] == :muster_vacant_batch and &1[:"$span"] == :start and
                  &1[:seq] == batch_seq)
            )

          assert batch_at > reclaim_at
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
          assert [_] =
                   of_kind(:snabbkaffe_crash, trace)
                   |> Enum.filter(&(&1[:node] == result.c_node and &1[:source] == result.t_node))

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
            |> Enum.filter(&(&1.node == result.t_node and &1.view_hash == result.hash3))

          assert length(t_rebalances) >= 2
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
          true = :erpc.call(r_node, Process, :exit, [scope_pid, :kill])

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
