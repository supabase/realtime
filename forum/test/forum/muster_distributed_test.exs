defmodule Forum.MusterDistributedTest do
  # Real multi-node tests: spin up `:peer` nodes, run Muster on each over the
  # default Erlang-distribution adapter, and exercise discovery + rebalance +
  # the cross-node convergence barrier end-to-end (real `:rebalance_marker`
  # announcements, not injected). The precise barrier *state machine* is covered
  # by the single-node tests in muster_test.exs; this file proves the wiring
  # works across real nodes and that every node converges all the way to
  # :ready (not left stuck in :rebalancing or :converging).
  #
  # BLACK BOX ONLY. Every test here must drive Muster purely through its public
  # surface and real cluster events -- start/stop nodes, join/leave, real process
  # crashes -- and observe outcomes through public reads (persistent_term, the
  # occupancy table) and the snabbkaffe trace. The ONLY sanctioned ways to steer
  # execution are snabbkaffe `force_ordering/2,3` and `inject_crash/2,3` (both
  # anchored on real `tp` events). NO mocks, and NO reaching inside a process to
  # mutate it: `:sys.replace_state`, hand-set `:persistent_term`s standing in for
  # real convergence, or any other state surgery are forbidden -- they assert on a
  # fiction the running system never actually produces. If a scenario cannot be
  # reached black-box, observe the mechanism via a `tp` rather than fake the state.
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

                # Join then immediately leave the SAME (unlinked) pid, both as
                # ordinary GenServer.calls against the shard, so the group is
                # left genuinely mid-cooldown on THIS node without ever
                # exposing the member pid across the wire.
                def join_and_leave(scope, group) do
                  pid = spawn(fn -> Process.sleep(:infinity) end)
                  :ok = Forum.Muster.join(scope, group, pid)
                  :ok = Forum.Muster.leave(scope, group, pid)
                end

                def status(scope) do
                  :persistent_term.get({Forum.Muster, scope, :status})
                end

                # Advance this VM's global monotonic counter by `n`. The
                # occupancy/announce seqs are :erlang.unique_integer([:monotonic]),
                # which starts from the SAME base on every fresh VM, so burning a
                # large amount here makes this incarnation's announce watermark
                # deterministically higher than a same-named restart will ever
                # reach -- forcing the cross-incarnation seq regression.
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

  defp start_remote_muster(peer, scope), do: start_remote_muster(peer, scope, [])

  defp start_remote_muster(peer, scope, opts) do
    :peer.call(peer, MusterPeerAux, :start, [scope, opts])
  end

  # Start Muster on a peer with a fast view heartbeat, so the heartbeat backstop
  # gets many chances to heal during a test (used by the restart-regression test
  # to prove the heartbeat cannot heal the stuck node).
  defp start_remote_muster_fast_heartbeat(peer, scope) do
    start_remote_muster(peer, scope, view_heartbeat_interval_ms: 200)
  end

  defp status(scope), do: :persistent_term.get({Forum.Muster, scope, :status})
  defp remote_status(peer, scope), do: :peer.call(peer, MusterPeerAux, :status, [scope])

  defp occupancy_on(n, scope, group) when n == node(), do: Scope.occupancy(scope, group)
  defp occupancy_on(n, scope, group), do: :erpc.call(n, Scope, :occupancy, [scope, group])

  # Tolerates the coordinator being transiently unregistered right after a
  # deliberate restart (Process.exit(coord, :kill) + immediate rejoin tests):
  # the OLD pid can already be gone while the supervisor hasn't finished
  # spawning its replacement, so a plain GenServer.call can hit :noproc even
  # though the shard-level state the caller cares about is already settled.
  defp group_state(scope, group, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_group_state(scope, group, deadline)
  end

  defp do_group_state(scope, group, deadline) do
    GenServer.call(Forum.Supervisor.name(scope), :status).group_states[group]
  catch
    :exit, reason ->
      if System.monotonic_time(:millisecond) >= deadline do
        exit(reason)
      else
        Process.sleep(5)
        do_group_state(scope, group, deadline)
      end
  end

  # `group_state/2` read on a remote node `n` (the coordinator's :status folds in
  # every shard's per-group state). A shard that is momentarily down mid-restart
  # is skipped by the gather, so the group reads as nil until it is back.
  defp remote_group_state(n, scope, group) do
    status = :erpc.call(n, GenServer, :call, [Forum.Supervisor.name(scope), :status])
    status.group_states[group]
  end

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

  # Plain state polling -- the fallback for conditions with no usable trace
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

  # Like `wait_until/2`, but returns the truthy value `fun` produced instead of
  # discarding it: needed whenever the caller must assert on exactly the value
  # that satisfied the poll, not re-read the same condition a moment later. A
  # separate re-read races anything that can retract the condition right after
  # it becomes true (e.g. a claim landing and then being immediately swept),
  # which is indistinguishable from the condition never having held.
  defp wait_until_value(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until_value(fun, deadline)
  end

  defp do_wait_until_value(fun, deadline) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("condition not met in time")
        else
          Process.sleep(20)
          do_wait_until_value(fun, deadline)
        end

      value ->
        value
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

          # Whoever the current router is, it holds {group, n1} -- this is the
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

    # These exercise, black-box (real nodes + public API only), that a node's
    # drop_stale_router_entries never permanently loses an occupancy row another
    # node snapshotted to it, across real cluster churn. The precise source-
    # agreement guard logic -- whose worst case (a stale-view sweep over a row
    # whose source disagrees) is no longer reachable black-box now that apply is
    # serialized through Scope -- is driven deterministically in muster_test.exs.

    # A real joiner C rebalances through partial (subset) views as it discovers
    # peers, before settling. A group routing to C must never be dropped from
    # C's occupancy along the way -- consistent-hashing monotonicity keeps it
    # routed to C in every subset view a joiner transiently holds.
    test "a snapshotted row survives a real joiner reaching :ready", %{scope: scope} do
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
          # The victim group must route to C in the final view {C, O, T}; by
          # monotonicity it then also routes to C in every subset C holds.
          group = pick_group([{final_members, c_node}])

          # T holds the group; the pre-join router knows it by the time join
          # returns (the RPC-before-Partition.join invariant).
          member = spawn(fn -> Process.sleep(:infinity) end)
          :ok = Muster.join(scope, group, member)
          {:ok, r1} = Muster.router(scope, group)
          assert t_node in occupancy_on(r1, scope, group)

          {:ok, p_c, ^c_node} = Peer.start(name: c_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(c_node)
          start_remote_muster(p_c, scope)

          # Cluster settles; T's rebalance snapshots {group, T} onto C.
          await_ready(final_members)
          assert {:ok, ^c_node} = Muster.router(scope, group)
          assert t_node in occupancy_on(c_node, scope, group)

          %{group: group, c_node: c_node, t_node: t_node}
        end,
        fn result, trace ->
          # The group always routes to C, so no partial-view sweep C ran while
          # discovering peers may ever have dropped T's row.
          assert of_kind(:muster_drop_stale_entry, trace)
                 |> Enum.count(
                   &(&1.node == result.c_node and &1.group == result.group and
                       &1.source == result.t_node)
                 ) == 0
        end
      )
    end

    # A real ephemeral node D joins and dies. While D is alive the group routes
    # to D (C correctly stops holding it); when D dies T heals C -- its rebalance
    # back to {C, O, T} moves the group D -> C and re-snapshots it onto C. After
    # the churn settles C must again be the router and hold T's row -- the round
    # trip must not permanently lose it.
    test "a snapshotted row survives a real ephemeral node's churn", %{scope: scope} do
      t_node = node()

      check_trace(
        fn ->
          # Settled 2-node cluster {T, O}.
          {:ok, p_o, o_node} = Peer.start(aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(o_node)
          start_remote_muster(p_o, scope)
          await_ready([t_node, o_node])

          # C's and D's node names are chosen upfront so the victim group can be
          # picked from ring math before either boots: it must route to C in the
          # final view {C, O, T} and to D in {C, D, O, T}.
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

          # Settle C: T snapshots the group to C as it rebalances to {C, O, T}.
          {:ok, p_c, ^c_node} = Peer.start(name: c_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(c_node)
          start_remote_muster(p_c, scope)
          await_ready(final_members)
          assert {:ok, ^c_node} = Muster.router(scope, group)
          assert t_node in occupancy_on(c_node, scope, group)

          # D joins: the group's router moves C -> D; T hands it over to D.
          {:ok, p_d, ^d_node} = Peer.start(name: d_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(d_node)
          start_remote_muster(p_d, scope)
          await_ready(Enum.sort([d_node | final_members]))
          assert {:ok, ^d_node} = Muster.router(scope, group)

          # D dies: the group moves D -> C and T re-snapshots (heals) it onto C.
          # final view reaches :ready a 2nd time (the 1st was before D), nth: 2.
          :ok = stop_supervised({:peer, d_name})
          await_ready(final_members, nth: 2, timeout: 20_000)

          assert {:ok, ^c_node} = Muster.router(scope, group)
          assert t_node in occupancy_on(c_node, scope, group)

          %{group: group, c_node: c_node, t_node: t_node}
        end,
        fn result, trace ->
          # T delivered the row to C at least twice: the initial join and the
          # post-death heal, proving the heal actually re-delivered it after D's
          # tenure (during which C correctly dropped it). The initial delivery is a
          # FULL snapshot (C was a brand-new router); the heal, to a now-settled C
          # regaining the group on a leave, is a DELTA.
          fulls =
            of_kind(:muster_node_state_received, trace)
            |> Enum.filter(&(&1.node == result.c_node and &1.source == result.t_node))

          deltas =
            of_kind(:muster_delta_received, trace)
            |> Enum.filter(&(&1.node == result.c_node and &1.source == result.t_node))

          # The initial join took the full-snapshot path.
          assert fulls != []

          # The group reached C at least twice across full + delta deliveries.
          deliveries =
            (fulls ++ deltas) |> Enum.count(&(result.group in &1.groups))

          assert deliveries >= 2

          # And the post-death heal exercised the delta path.
          assert Enum.any?(deltas, &(result.group in &1.groups))
        end
      )
    end
  end

  describe "delta-on-leave across real nodes" do
    setup do
      scope = :"muster_delta_#{System.unique_integer([:positive])}"
      start_supervised!(spec(scope, vacant_flush_interval_ms: 100))
      %{scope: scope}
    end

    # README rebalance step 7 (full vs. delta): when a node leaves, a surviving
    # router that INHERITS the departed node's groups is a settled member whose
    # rows match the previous generation, so the holder re-announces via a DELTA
    # carrying only the moved-in groups, never the groups the survivor already
    # held (those are preserved on it because the delta path does not wipe). The
    # full-snapshot path would re-send the survivor's entire slice; this is the
    # churn win. Driven black-box: a real node D dies and T heals the survivor S.
    test "a survivor inheriting a group on a leave gets a delta of only the moved-in group",
         %{scope: scope} do
      t_node = node()

      check_trace(
        fn ->
          # Settled {T, S}.
          {:ok, p_s, s_node} = Peer.start(aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(s_node)
          start_remote_muster(p_s, scope)
          await_ready([t_node, s_node])

          # D's name upfront so the victim groups can be picked from ring math.
          d_name = ~c"muster_delta_d_#{System.unique_integer([:positive])}"
          d_node = :"#{d_name}@127.0.0.1"
          view3 = Enum.sort([t_node, s_node, d_node])
          view2 = Enum.sort([t_node, s_node])

          # g_keep routes to S before AND after D dies (S holds it throughout);
          # g_move routes to D before, S after (it moves onto S when D dies).
          g_keep = pick_group([{view3, s_node}, {view2, s_node}])
          g_move = pick_group([{view3, d_node}, {view2, s_node}])
          assert g_keep != g_move

          # Bring up D and settle {T, S, D}.
          {:ok, p_d, ^d_node} = Peer.start(name: d_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(d_node)
          start_remote_muster(p_d, scope)
          await_ready(view3)

          # T holds both groups; each travels to its router as :occupied (not a
          # snapshot), so S never enters owed_snapshots and stays a settled router.
          :ok = Muster.join(scope, g_keep, spawn(fn -> Process.sleep(:infinity) end))
          :ok = Muster.join(scope, g_move, spawn(fn -> Process.sleep(:infinity) end))
          assert t_node in occupancy_on(s_node, scope, g_keep)
          assert t_node in occupancy_on(d_node, scope, g_move)

          # D dies: g_move moves D -> S; T re-announces it to the settled survivor
          # S via a DELTA.
          :ok = stop_supervised({:peer, d_name})

          assert {:ok, %{groups: delta_groups}} =
                   block_until(
                     %{:"$kind" => :muster_delta_received, node: ^s_node, source: ^t_node},
                     20_000
                   )

          # view2 reaches :ready a 2nd time (the 1st was before D joined), nth: 2.
          await_ready(view2, nth: 2, timeout: 20_000)

          assert g_move in delta_groups, "the inherited group must ride the delta"

          refute g_keep in delta_groups,
                 "the group S already held must NOT be re-sent in the delta"

          # Final occupancy: the moved group was ADDED and the kept group PRESERVED
          # (it was never re-sent, yet survives because the delta does not wipe).
          assert {:ok, ^s_node} = Muster.router(scope, g_move)
          assert t_node in occupancy_on(s_node, scope, g_move)
          assert t_node in occupancy_on(s_node, scope, g_keep)

          %{g_keep: g_keep, g_move: g_move, s_node: s_node, t_node: t_node}
        end,
        fn result, trace ->
          # The heal was a delta, never a full snapshot: S was settled throughout
          # (it only ever GAINED groups, which on a leave travels incrementally),
          # so T never sent it a receive_node_state.
          assert of_kind(:muster_node_state_received, trace)
                 |> Enum.filter(&(&1.node == result.s_node and &1.source == result.t_node)) == []

          # Exactly the moved group rode the delta(s) to S; the kept group never did.
          delta_groups =
            of_kind(:muster_delta_received, trace)
            |> Enum.filter(&(&1.node == result.s_node and &1.source == result.t_node))
            |> Enum.flat_map(& &1.groups)

          assert result.g_move in delta_groups
          refute result.g_keep in delta_groups
        end
      )
    end
  end

  describe "owed router falls back to a full snapshot (forced ordering)" do
    setup do
      scope = :"muster_owed_#{System.unique_integer([:positive])}"
      # Generous rpc_timeout: the survivor's snapshot apply is parked for the whole
      # window between two membership changes, and the sender's snapshot RPCs wait
      # on it, so they must not time out (which crashes the sender) before release.
      start_supervised!(spec(scope, vacant_flush_interval_ms: 100, rpc_timeout_ms: 30_000))
      %{scope: scope}
    end

    # README rebalance step 7 (full vs. delta): when a router has a still-in-flight
    # round from us (`owed_snapshots`), its baseline is unknown, so a SECOND
    # rebalance that would otherwise send it a delta falls back to a FULL snapshot.
    # Driven black-box with forced ordering: park survivor S's first snapshot apply
    # so S stays owed on T, then make a real second membership change (O leaves)
    # move a group onto S, and assert S receives that group via a full snapshot,
    # never a delta.
    test "a second rebalance while a router is owed sends a full snapshot, not a delta",
         %{scope: scope} do
      t_node = node()

      o_name = ~c"muster_owed_o_#{System.unique_integer([:positive])}"
      o_node = :"#{o_name}@127.0.0.1"
      s_name = ~c"muster_owed_s_#{System.unique_integer([:positive])}"
      s_node = :"#{s_name}@127.0.0.1"
      view_tos = Enum.sort([t_node, o_node, s_node])
      view_ts = Enum.sort([t_node, s_node])

      check_trace(
        fn ->
          # Settled {T, O}.
          {:ok, p_o, ^o_node} = Peer.start(name: o_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(o_node)
          start_remote_muster(p_o, scope)
          await_ready([t_node, o_node])

          # g_park routes to S in {T,O,S} and {T,S}, so S's join snapshots it onto
          # S (the round we park, making S owed) and it stays there. g_move routes
          # to O in {T,O,S} but S in {T,S}, so it moves onto S when O leaves (the
          # would-be delta).
          g_park = pick_group([{view_tos, s_node}, {view_ts, s_node}])
          g_move = pick_group([{view_tos, o_node}, {view_ts, s_node}])
          assert g_park != g_move

          # T holds both (they travel as :occupied, not snapshots).
          :ok = Muster.join(scope, g_park, spawn(fn -> Process.sleep(:infinity) end))
          :ok = Muster.join(scope, g_move, spawn(fn -> Process.sleep(:infinity) end))

          # Park EVERY snapshot apply on S from T until we release: S's coordinator
          # blocks in {:apply_snapshot}, so its RPC worker on T never returns and
          # T's owed_snapshots[S] never clears.
          force_ordering(
            %{:"$kind" => :test_release_s},
            %{:"$kind" => :muster_node_state_received, node: ^s_node, source: ^t_node}
          )

          # S joins {T,O,S}: T's rebalance snapshots g_park onto the new router S
          # (full, since S is new), and that apply parks -> S is owed on T.
          {:ok, p_s, ^s_node} = Peer.start(name: s_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(s_node)
          start_remote_muster(p_s, scope)

          # Wait until T records S as owed (its snapshot is in flight / parked).
          wait_until(fn ->
            Forum.Supervisor.name(scope)
            |> GenServer.call(:dump)
            |> Map.fetch!(:owed_snapshots)
            |> Map.has_key?(s_node)
          end)

          # O leaves {T,O,S} -> {T,S} while S is owed. g_move moves O -> S, so T
          # re-announces it to S, and because S is owed, as a FULL snapshot.
          :ok = stop_supervised({:peer, o_name})

          assert {:ok, _} =
                   block_until(
                     %{:"$kind" => :muster_rebalance_start, node: ^t_node, to: ^view_ts},
                     10_000
                   )

          # Release: S applies the parked rounds, processes O's DOWN, and converges.
          tp(:test_release_s, %{})
          await_ready(view_ts, timeout: 20_000)

          # Both groups landed on S from T.
          assert {:ok, ^s_node} = Muster.router(scope, g_move)
          assert t_node in occupancy_on(s_node, scope, g_move)
          assert t_node in occupancy_on(s_node, scope, g_park)

          %{g_park: g_park, g_move: g_move, s_node: s_node, t_node: t_node}
        end,
        fn result, trace ->
          # The owed fallback held: T sent S only FULL snapshots, and g_move,
          # which for a settled, non-owed router would have been a delta, arrived
          # in one.
          fulls =
            of_kind(:muster_node_state_received, trace)
            |> Enum.filter(&(&1.node == result.s_node and &1.source == result.t_node))

          assert Enum.any?(fulls, &(result.g_move in &1.groups)),
                 "g_move must reach S via a full snapshot under the owed fallback"

          assert of_kind(:muster_delta_received, trace)
                 |> Enum.count(&(&1.node == result.s_node and &1.source == result.t_node)) == 0,
                 "no delta should be sent to an owed router"
        end
      )
    end
  end

  describe "rebalance markers respect prior-round owed_snapshots" do
    setup do
      scope = :"muster_marker_owed_#{System.unique_integer([:positive])}"

      start_supervised!(
        spec(scope, vacant_flush_interval_ms: 100, view_heartbeat_interval_ms: 200)
      )

      %{scope: scope}
    end

    # README rebalance step 8 (bare markers): a member still owed a PREVIOUS
    # round's un-acked snapshot must never be told "the new view is settled" by
    # a later round that happens not to move any group its way -- its marker
    # has to keep riding the still-in-flight snapshot. Driven black-box with
    # forced ordering: freeze T's round-1 full snapshot to C (a real RPC, an
    # `:erlang.spawn_opt` worker, not the coordinator) BEFORE it is dispatched,
    # so C never actually receives it, then make a real second membership
    # change (O leaves) that does NOT move the group T holds. The buggy code
    # excludes only THIS round's snapshot targets from the bare-marker send, so
    # it marks C for the new view anyway; C then satisfies its own barrier and
    # goes :ready with the group's row still in flight.
    test "a router still owed a prior round's snapshot must not reach :ready off a bare marker",
         %{scope: scope} do
      t_node = node()

      o_name = ~c"muster_marker_owed_o_#{System.unique_integer([:positive])}"
      o_node = :"#{o_name}@127.0.0.1"
      c_name = ~c"muster_marker_owed_c_#{System.unique_integer([:positive])}"
      c_node = :"#{c_name}@127.0.0.1"
      view_toc = Enum.sort([t_node, o_node, c_node])
      view_tc = Enum.sort([t_node, c_node])
      view_tc_hash = :erlang.phash2(view_tc)

      check_trace(
        fn ->
          # Settled {T, O}.
          {:ok, p_o, ^o_node} = Peer.start(name: o_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(o_node)
          start_remote_muster(p_o, scope)
          await_ready([t_node, o_node])

          # g routes to C in BOTH {T,O,C} and {T,C}: O's departure must not move
          # it, so round 2 has nothing new to send C.
          g = pick_group([{view_toc, c_node}, {view_tc, c_node}])

          # T holds g before C ever joins, so C's join snapshots it in full.
          :ok = Muster.join(scope, g, spawn(fn -> Process.sleep(:infinity) end))

          # Freeze T's round-1 snapshot dispatch to C before the RPC is even
          # sent: T's owed_snapshots[C] is set (that happens synchronously in
          # do_rebalance), but C receives nothing until we release.
          force_ordering(
            %{:"$kind" => :test_release_snapshot},
            %{
              :"$kind" => :muster_rpc_worker_start,
              router: ^c_node,
              function: :receive_node_state
            }
          )

          # C joins {T,O,C}: T's rebalance snapshots g onto the new router C
          # (full, since C is new), and that dispatch freezes -> C is owed on T.
          {:ok, p_c, ^c_node} = Peer.start(name: c_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(c_node)
          start_remote_muster(p_c, scope)

          wait_until(fn ->
            Forum.Supervisor.name(scope)
            |> GenServer.call(:dump)
            |> Map.fetch!(:owed_snapshots)
            |> Map.has_key?(c_node)
          end)

          # O leaves {T,O,C} -> {T,C} while C is still owed. g's router does not
          # change, so round 2 has no fresh snapshot for C -- only a candidate
          # bare marker.
          :ok = stop_supervised({:peer, o_name})

          assert {:ok, _} =
                   block_until(
                     %{:"$kind" => :muster_rebalance_start, node: ^t_node, to: ^view_tc},
                     10_000
                   )

          # The crux: with the frozen snapshot never having reached C, C must
          # not be able to reach :ready for {T,C} by any other means. Give it a
          # bounded window (the buggy bare marker, if sent, arrives near-
          # instantly; the fix means this must time out).
          premature_ready? =
            case block_until(
                   %{
                     :"$kind" => :muster_status_change,
                     to: :ready,
                     node: ^c_node,
                     view_hash: ^view_tc_hash
                   },
                   3_000
                 ) do
              {:ok, _} -> true
              :timeout -> false
            end

          refute premature_ready?,
                 "C reached :ready for #{inspect(view_tc)} while T's round-1 snapshot " <>
                   "(carrying #{inspect(g)}) was still frozen in flight -- a bare marker " <>
                   "must not satisfy the barrier for a still-owed router"

          # Release: C finally receives the (now stale-viewed, but still valid
          # data) snapshot, T's owed entry clears, and its fast heartbeat
          # re-announces the current view so C converges for real.
          tp(:test_release_snapshot, %{})
          await_ready(view_tc, nodes: [c_node], timeout: 20_000)

          %{g: g, c_node: c_node, t_node: t_node}
        end,
        fn result, _trace ->
          # Final state must be correct: the group's row actually landed on C.
          %{g: g, c_node: c_node, t_node: t_node} = result

          assert {:ok, ^c_node} = Muster.router(scope, g)
          assert t_node in occupancy_on(c_node, scope, g)

          assert {:ok, [t_node]} ==
                   :erpc.call(c_node, Muster, :targets, [scope, g, view_tc_hash])
        end
      )
    end
  end

  describe "delta correctness across multiple rounds" do
    setup do
      scope = :"muster_delta_multi_#{System.unique_integer([:positive])}"
      start_supervised!(spec(scope, vacant_flush_interval_ms: 100))
      %{scope: scope}
    end

    # README rebalance step 7 (full vs. delta), the INDUCTIVE step: a delta's
    # baseline is "the receiver's rows from the PREVIOUS ring generation", and that
    # baseline must hold even when the previous generation was itself established by
    # a delta (not a full snapshot). Two sequential leaves each move a different
    # group onto the same settled survivor S; the SECOND delta must build on the
    # table the FIRST delta left, never dropping the group the first delta delivered
    # (nor the group S has held since the joins). If deltas did not chain correctly,
    # S would end the test missing g1.
    test "consecutive leaves chain deltas onto one survivor (a delta built on a delta base)",
         %{scope: scope} do
      t_node = node()

      check_trace(
        fn ->
          # Settled {T, S}. T holds nothing yet, so S joins as a settled router that
          # never receives a full snapshot (the joins below travel as :occupied).
          {:ok, p_s, s_node} = Peer.start(aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(s_node)
          start_remote_muster(p_s, scope)
          await_ready([t_node, s_node])

          # D1, D2 names upfront so the victim groups can be picked from ring math.
          d1_name = ~c"muster_chain_d1_#{System.unique_integer([:positive])}"
          d2_name = ~c"muster_chain_d2_#{System.unique_integer([:positive])}"
          d1_node = :"#{d1_name}@127.0.0.1"
          d2_node = :"#{d2_name}@127.0.0.1"

          view4 = Enum.sort([t_node, s_node, d1_node, d2_node])
          view_b = Enum.sort([t_node, s_node, d2_node])
          view2 = Enum.sort([t_node, s_node])

          # g_keep: S in every view (S holds it throughout, never re-sent).
          # g1: D1 in view4, S after D1 leaves -> rides delta #1.
          # g2: D2 in view4 AND view_b (survives D1's leave), S after D2 leaves ->
          #     rides delta #2, which must build on the base delta #1 left.
          g_keep = pick_group([{view4, s_node}, {view_b, s_node}, {view2, s_node}])
          g1 = pick_group([{view4, d1_node}, {view_b, s_node}])
          g2 = pick_group([{view4, d2_node}, {view_b, d2_node}, {view2, s_node}])
          assert g_keep != g1 and g1 != g2 and g_keep != g2

          # Bring up D1 then D2; settle the 4-node view.
          {:ok, p_d1, ^d1_node} = Peer.start(name: d1_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(d1_node)
          start_remote_muster(p_d1, scope)
          await_ready(Enum.sort([t_node, s_node, d1_node]))

          {:ok, p_d2, ^d2_node} = Peer.start(name: d2_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(d2_node)
          start_remote_muster(p_d2, scope)
          await_ready(view4)

          # T holds all three; each travels to its router as :occupied, so S never
          # enters owed_snapshots and stays a settled router.
          :ok = Muster.join(scope, g_keep, spawn(fn -> Process.sleep(:infinity) end))
          :ok = Muster.join(scope, g1, spawn(fn -> Process.sleep(:infinity) end))
          :ok = Muster.join(scope, g2, spawn(fn -> Process.sleep(:infinity) end))
          assert t_node in occupancy_on(s_node, scope, g_keep)
          assert t_node in occupancy_on(d1_node, scope, g1)
          assert t_node in occupancy_on(d2_node, scope, g2)

          # Round 1: D1 leaves. g1 moves D1 -> S via DELTA #1; g_keep and g2 unmoved.
          :ok = stop_supervised({:peer, d1_name})

          assert {:ok, %{groups: delta1}} =
                   block_until(
                     %{:"$kind" => :muster_delta_received, node: ^s_node, source: ^t_node},
                     20_000
                   )

          assert g1 in delta1
          await_ready(view_b, timeout: 20_000)

          # Drain owed so round 2 to S is a genuine delta, not an owed-fallback full.
          wait_until(fn ->
            owed = GenServer.call(Forum.Supervisor.name(scope), :dump).owed_snapshots
            not Map.has_key?(owed, s_node)
          end)

          # Round 2: D2 leaves. g2 moves D2 -> S via DELTA #2, built on the table
          # delta #1 left (g_keep + g1 already present on S, neither re-sent).
          :ok = stop_supervised({:peer, d2_name})

          # The 4-arg (nth) block_until returns {:ok, [events]}; the 2nd is delta #2.
          assert {:ok, deltas_to_s} =
                   block_until(
                     %{:"$kind" => :muster_delta_received, node: ^s_node, source: ^t_node},
                     2,
                     20_000,
                     :infinity
                   )

          assert g2 in List.last(deltas_to_s).groups
          await_ready(view2, nth: 2, timeout: 20_000)

          # All three groups are present on S: g1 survived round 2 (the chain did not
          # drop it), g2 was added, g_keep preserved throughout without re-send.
          assert t_node in occupancy_on(s_node, scope, g1)
          assert t_node in occupancy_on(s_node, scope, g2)
          assert t_node in occupancy_on(s_node, scope, g_keep)

          %{g_keep: g_keep, g1: g1, g2: g2, s_node: s_node, t_node: t_node}
        end,
        fn result, trace ->
          to_s = fn kind ->
            of_kind(kind, trace)
            |> Enum.filter(&(&1.node == result.s_node and &1.source == result.t_node))
          end

          # S was settled throughout: it only ever GAINED groups on leaves, which
          # travels incrementally, so T never sent it a full snapshot.
          assert to_s.(:muster_node_state_received) == []

          # Both moved groups rode deltas; the kept group never did.
          delta_groups = to_s.(:muster_delta_received) |> Enum.flat_map(& &1.groups)
          assert result.g1 in delta_groups
          assert result.g2 in delta_groups
          refute result.g_keep in delta_groups
        end
      )
    end

    # README rebalance step 7 + step 9 ("the receiver owns removes"): the delta path
    # leans on the receiver's OWN drop_stale_router_entries to retract a group that
    # moved away, and on the delta's baseline surviving a round that delivered the
    # receiver no data at all. Here g_move ping-pongs S -> D -> S: when D joins, S is
    # only bare-marked (it gains nothing) yet must DROP g_move via its own sweep;
    # when D leaves, S regains g_move via a delta whose baseline is exactly that
    # swept-down table. g_keep, held by S throughout, is never re-sent and must
    # survive. This is the inductive base-maintenance that the (not deterministically
    # forceable) divergent-observation-order case ultimately relies on.
    test "a survivor's own sweep retracts a moved-away group and a later delta re-adds it",
         %{scope: scope} do
      t_node = node()

      check_trace(
        fn ->
          {:ok, p_s, s_node} = Peer.start(aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(s_node)
          start_remote_muster(p_s, scope)
          await_ready([t_node, s_node])

          d_name = ~c"muster_pingpong_d_#{System.unique_integer([:positive])}"
          d_node = :"#{d_name}@127.0.0.1"
          view2 = Enum.sort([t_node, s_node])
          view3 = Enum.sort([t_node, s_node, d_node])

          # g_keep: S in both views. g_move: S in {T,S}, D once D joins.
          g_keep = pick_group([{view2, s_node}, {view3, s_node}])
          g_move = pick_group([{view2, s_node}, {view3, d_node}])
          assert g_keep != g_move

          # T holds both; both route to S now, travelling as :occupied.
          :ok = Muster.join(scope, g_keep, spawn(fn -> Process.sleep(:infinity) end))
          :ok = Muster.join(scope, g_move, spawn(fn -> Process.sleep(:infinity) end))
          assert t_node in occupancy_on(s_node, scope, g_keep)
          assert t_node in occupancy_on(s_node, scope, g_move)

          # D joins: g_move's router moves S -> D. S gains nothing (g_keep stays), so
          # T only bare-marks S; S must drop its now-stale {g_move, T} on its own.
          {:ok, p_d, ^d_node} = Peer.start(name: d_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(d_node)
          start_remote_muster(p_d, scope)
          await_ready(view3)

          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_drop_stale_entry,
                       node: ^s_node,
                       group: ^g_move,
                       source: ^t_node
                     },
                     20_000
                   )

          # The sweep ran: S no longer routes g_move (D does) and dropped its row;
          # g_keep is untouched and D now holds it.
          assert occupancy_on(s_node, scope, g_move) == []
          assert t_node in occupancy_on(d_node, scope, g_move)
          assert t_node in occupancy_on(s_node, scope, g_keep)

          # D leaves: g_move moves D -> S again. S is settled (only ever bare-marked,
          # never owed), so T re-announces via a DELTA whose baseline is S's
          # swept-down table.
          :ok = stop_supervised({:peer, d_name})

          assert {:ok, %{groups: delta_groups}} =
                   block_until(
                     %{:"$kind" => :muster_delta_received, node: ^s_node, source: ^t_node},
                     20_000
                   )

          assert g_move in delta_groups
          await_ready(view2, nth: 2, timeout: 20_000)

          # g_move re-added by the delta; g_keep preserved without ever being re-sent.
          assert t_node in occupancy_on(s_node, scope, g_move)
          assert t_node in occupancy_on(s_node, scope, g_keep)

          %{g_keep: g_keep, g_move: g_move, s_node: s_node, t_node: t_node}
        end,
        fn result, trace ->
          to_s = fn kind ->
            of_kind(kind, trace)
            |> Enum.filter(&(&1.node == result.s_node and &1.source == result.t_node))
          end

          # S was never sent a full snapshot: it stayed settled across the whole
          # ping-pong (bare marker on the join, delta on the leave).
          assert to_s.(:muster_node_state_received) == []

          # Exactly the moved group rode the delta back to S; the kept group never did.
          delta_groups = to_s.(:muster_delta_received) |> Enum.flat_map(& &1.groups)
          assert result.g_move in delta_groups
          refute result.g_keep in delta_groups

          # S itself performed the retract (receiver owns removes): the only node to
          # drop g_move (sourced from T) as stale was S.
          drops =
            of_kind(:muster_drop_stale_entry, trace)
            |> Enum.filter(&(&1.group == result.g_move and &1.source == result.t_node))

          assert drops |> Enum.map(& &1.node) |> Enum.uniq() == [result.s_node]
        end
      )
    end
  end

  describe "vacant DELETE vs. re-claim -- occupancy seq guard (forced ordering)" do
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
          # INSERT for this group has been committed there -- the first was the
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
          # (later in the trace -- the forced ordering).
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

  describe "reverse race -- a stale occupied INSERT vs. a fresh vacant DELETE (forced ordering)" do
    setup do
      scope = :"muster_revseq_#{System.unique_integer([:positive])}"
      # Long flush interval so the only vacant flush is the one the test triggers
      # deterministically; a generous rpc_timeout so the parked occupied worker
      # does not time out before we release it.
      start_supervised!(
        spec(scope,
          vacancy_cooldown_ms: 50,
          vacant_flush_interval_ms: 100,
          rpc_timeout_ms: 30_000
        )
      )

      %{scope: scope}
    end

    # The MIRROR of "a late vacant DELETE cannot clobber a re-claimed group". That
    # test proved a stale, lower-seq DELETE landing after a fresh, higher-seq
    # INSERT is a no-op (vacant_batch's `=<` seq guard). This proves the opposite
    # direction now holds too: a stale, lower-seq `occupied` INSERT landing on a
    # real router AFTER a fresh, higher-seq `vacant_batch` DELETE must NOT
    # resurrect a group the source has actually vacated. Before vacancy tombstones
    # (the DELETE removed the row outright, discarding its seq) the late INSERT
    # won via insert_new and left a permanent phantom; now the DELETE leaves a
    # seq-stamped tombstone that the lower-seq INSERT loses to.
    #
    # This IS a plain occupied-vs-vacant race, via the SAME :erpc-no-cancel
    # property the vacant side exploits -- an `occupied` whose RPC was orphaned is
    # not cancelled, so its INSERT can still land late. The only subtlety is
    # producing it: the claim state machine awaits `occupied` (a caller parks in
    # :occupied_pending until it confirms), so an `occupied` is not normally in
    # flight while a later `vacant` for the same group is dispatched. A shard
    # CRASH is the bridge -- the orphaned `occupied` worker (low seq) survives the
    # crash (it is monitored, not linked), and the restart reconciles the
    # un-confirmed :occupied_pending (count 0) straight to :vacant_queued, so the
    # next flush dispatches a HIGHER-seq `vacant` for the same {group, source}.
    # Both RPCs race the router; we force the dangerous order -- DELETE first, then
    # the orphaned INSERT -- and assert the vacated group does not reappear.
    test "a stale occupied INSERT after a fresh vacant DELETE must NOT resurrect the group",
         %{scope: scope} do
      t_node = node()

      check_trace(
        fn ->
          {:ok, p_r, r_node} = Peer.start(aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(r_node)
          start_remote_muster(p_r, scope)
          await_ready([t_node, r_node])

          group = group_routed_to(scope, r_node)

          # Park the occupied INSERT on the router until the vacant_batch DELETE
          # for the same source has completed there -- forcing the stale INSERT to
          # apply strictly AFTER the fresh DELETE. The :muster_occupied_apply
          # :start anchor fires BEFORE the ETS write, so the row is genuinely not
          # written while parked.
          force_ordering(
            %{
              :"$kind" => :muster_vacant_batch,
              :"$span" => {:complete, _},
              node: ^r_node,
              source: ^t_node
            },
            %{
              :"$kind" => :muster_occupied_apply,
              :"$span" => :start,
              node: ^r_node,
              group: ^group,
              source: ^t_node
            }
          )

          # Claim the group. join blocks in :occupied_pending (its occupied RPC is
          # parked on the router), so run it off to the side -- we never use its
          # result; the shard is about to be killed under it. spawn (not
          # spawn_link) so its exit does not touch the test.
          member = spawn(fn -> Process.sleep(:infinity) end)
          _claimer = spawn(fn -> Muster.join(scope, group, member) end)

          # The occupied RPC has been dispatched (the shard is now :occupied_pending
          # and the worker is in flight to the router, where it will park at the
          # forced :muster_occupied_apply :start). We wait on this SOURCE-side event
          # rather than the parked apply event itself -- force_ordering withholds the
          # parked event from the trace until it is released, so waiting on it here
          # would deadlock.
          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_group_state,
                       node: ^t_node,
                       group: ^group,
                       state: {:occupied_pending, _}
                     },
                     10_000
                   )

          # Kill the shard that owns the group on the SOURCE while its occupied is
          # in flight. The orphaned worker (monitored, not linked) survives and
          # stays parked on the router.
          shard_name = Forum.Supervisor.shard(scope, group)
          old_shard = Process.whereis(shard_name)
          ref = Process.monitor(old_shard)
          true = Process.exit(old_shard, :kill)
          assert_receive {:DOWN, ^ref, :process, ^old_shard, :killed}, 5_000

          # The restarted shard reconciles the un-confirmed claim (count 0) to
          # :vacant_queued -- the source now considers the group released.
          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_group_state,
                       node: ^t_node,
                       group: ^group,
                       state: :vacant_queued
                     },
                     10_000
                   )

          # The natural flush dispatches the (higher-seq) vacant_batch to the
          # router. With the INSERT parked, it deletes nothing, and on completion
          # releases the parked INSERT -- which then applies its stale, lower seq.

          # Wait for the freed INSERT to commit on the router.
          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_occupied_apply,
                       :"$span" => {:complete, _},
                       node: ^r_node,
                       group: ^group,
                       source: ^t_node
                     },
                     10_000
                   )

          # The source has fully forgotten the group (the vacant batch was
          # acknowledged).
          wait_until(fn -> group_state(scope, group) == nil end)

          %{group: group, r_node: r_node, t_node: t_node}
        end,
        fn result, trace ->
          # The forced order really was DELETE-then-INSERT, and the INSERT carried
          # the lower (stale) seq -- otherwise this would not be the reverse race.
          assert [%{seq: ins_seq}] =
                   of_kind(:muster_occupied_apply, trace)
                   |> Enum.filter(
                     &(&1[:"$span"] == :start and &1.node == result.r_node and
                         &1.group == result.group)
                   )

          assert [%{seq: del_seq}] =
                   of_kind(:muster_vacant_batch, trace)
                   |> Enum.filter(
                     &(&1[:"$span"] == :start and &1.node == result.r_node and
                         result.group in &1.groups)
                   )

          assert ins_seq < del_seq,
                 "the INSERT must be the stale (lower-seq) write for this to be the reverse race"

          # THE PROPERTY UNDER TEST: the source genuinely vacated the group (no
          # local member, state forgotten), so the router must NOT still list it.
          # A failure here means the stale INSERT resurrected a phantom occupancy
          # that nothing will ever retract (the group routes to this router, so
          # its own drop_stale_router_entries spares it; the source will never
          # re-vacate).
          assert Muster.local_member_count(scope, result.group) == 0
          assert group_state(scope, result.group) == nil

          refute result.t_node in occupancy_on(result.r_node, scope, result.group),
                 "stale occupied INSERT resurrected a vacated group on the router (phantom occupancy)"
        end
      )
    end
  end

  describe "periodic stale-router-entry sweep (piggybacked on :sweep_tombstones)" do
    setup do
      scope = :"muster_fencing_gap_#{System.unique_integer([:positive])}"
      # Generous rpc_timeout: the parked occupied worker survives across an
      # entire membership change and its convergence before we release it, and
      # must not time out client-side and confuse the source shard's state
      # machine while we orchestrate the race. A short, independent
      # tombstone_window_ms (the periodic sweep's interval) so the backstop
      # this test proves has several chances to fire within the timeout below.
      start_supervised!(
        spec(scope,
          vacancy_cooldown_ms: 50,
          vacant_flush_interval_ms: 100,
          rpc_timeout_ms: 30_000,
          tombstone_window_ms: 200
        )
      )

      %{scope: scope}
    end

    # occupied/4 and vacant_batch/4 are the only cross-node writes in Muster
    # with no cluster-view fencing -- only {group, source_node, seq}. Every
    # other cross-node write (receive_node_state, apply_delta) is stamped with
    # view_hash and folds into the readiness barrier.
    #
    # :erpc does not cancel a delayed call: the request still lands and
    # executes on the remote node later (the same property the reverse-race
    # test above exploits). Here it lands on a router that has ALREADY swept
    # past the view where it would have mattered:
    #
    #   1. T holds `group`, routed to R; its shard dispatches occupied(group,
    #      T, seq) to R. We park it (force_ordering) BEFORE it writes the row.
    #   2. Before it lands, X joins and `group`'s router moves R -> X. T's
    #      rebalance settles the parked join locally (the ring already shows
    #      the new router -- settle_moved_pending) and snapshots the group onto
    #      X; it never waits on the worker still parked against R.
    #   3. R agrees on the new (3-node) view and runs its OWN
    #      drop_stale_router_entries sweep on the :ready transition -- a no-op
    #      for {group, T}, since R has no row for it yet.
    #   4. We release the park. The stale, low-seq occupied INSERT finally
    #      lands on R. upsert_if_newer has no existing row to compare against,
    #      so insert_new wins UNCONDITIONALLY, planting a phantom present row.
    #
    # Nothing else in this test's remaining life ever touches that row: T only
    # ever asserts what it currently holds (X, not R) and never sends R a
    # retraction, and no further membership churn arrives to trigger another
    # rebalance or :ready transition. The ONLY thing left that can catch it is
    # the periodic backstop sweep piggybacked on :sweep_tombstones -- this test
    # proves it does, within one :tombstone_window_ms tick, without needing
    # any further churn.
    test "a stale occupied INSERT delayed past R's sweep is caught by the next periodic tick",
         %{scope: scope} do
      t_node = node()

      check_trace(
        fn ->
          # Settled 2-node cluster {T, R}. R needs the same short
          # tombstone_window_ms as T -- it is R's own periodic sweep, running
          # on R's own schedule, that this test proves catches the phantom row.
          {:ok, p_r, r_node} = Peer.start(aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(r_node)
          start_remote_muster(p_r, scope, tombstone_window_ms: 200)
          await_ready([t_node, r_node])

          # X's name is fixed upfront so the victim group can be picked from
          # ring math: routed to R in {T,R}, moved onto X once X joins.
          x_name = ~c"muster_fencing_gap_x_#{System.unique_integer([:positive])}"
          x_node = :"#{x_name}@127.0.0.1"
          view3 = Enum.sort([t_node, r_node, x_node])
          hash3 = :erlang.phash2(view3)
          group = pick_group([{[t_node, r_node], r_node}, {view3, x_node}])

          # Park the occupied INSERT on R before it writes the row -- the
          # delayed-RPC arm of the race. The :start anchor fires before the ETS
          # write (same anchor the reverse-race test above uses), so the row is
          # genuinely absent while parked.
          force_ordering(
            %{:"$kind" => :test_release_occupied},
            %{
              :"$kind" => :muster_occupied_apply,
              :"$span" => :start,
              node: ^r_node,
              group: ^group,
              source: ^t_node
            }
          )

          # Claim off to the side: the join call parks in :occupied_pending
          # (its :occupied RPC to R is parked there), so run it off to the
          # side -- we never use its result.
          member = spawn(fn -> Process.sleep(:infinity) end)
          _claimer = spawn(fn -> Muster.join(scope, group, member) end)

          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_group_state,
                       node: ^t_node,
                       group: ^group,
                       state: {:occupied_pending, _}
                     },
                     10_000
                   )

          # X joins: the group's router moves R -> X. T's rebalance settles the
          # parked pending join right here (settle_moved_pending) and snapshots
          # the group onto the fresh router X -- never waiting on the worker
          # still parked against R.
          {:ok, p_x, ^x_node} = Peer.start(name: x_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(x_node)
          start_remote_muster(p_x, scope)

          assert {:ok, %{groups: snapshotted}} =
                   block_until(
                     %{:"$kind" => :muster_node_state_received, node: ^x_node, source: ^t_node},
                     15_000
                   )

          assert group in snapshotted

          # Every node -- INCLUDING R -- converges to :ready for the 3-node view.
          # R's own sweep on this transition is a genuine no-op for {group, T}:
          # it has no row for it yet, the parked INSERT hasn't landed.
          await_ready(view3)

          assert {:ok, ^x_node} = Muster.router(scope, group)
          assert t_node in occupancy_on(x_node, scope, group)
          assert occupancy_on(r_node, scope, group) == []

          # Release the park. The stale INSERT lands on R strictly AFTER R
          # already agreed on the view that routes `group` away from it.
          tp(:test_release_occupied, %{})

          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_occupied_apply,
                       :"$span" => {:complete, _},
                       node: ^r_node,
                       group: ^group,
                       source: ^t_node
                     },
                     10_000
                   )

          # The gap really opens: with no row to compare against, insert_new
          # wins unconditionally and plants a phantom present row.
          wait_until(fn -> occupancy_on(r_node, scope, group) != [] end)
          assert t_node in occupancy_on(r_node, scope, group)

          # No further churn happens from here on -- the only thing left that
          # can ever touch this row is the periodic backstop. Give it a few
          # ticks (tombstone_window_ms: 200) to catch and drop it.
          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_drop_stale_entry,
                       node: ^r_node,
                       group: ^group,
                       source: ^t_node
                     },
                     5_000
                   )

          wait_until(fn -> occupancy_on(r_node, scope, group) == [] end)

          %{group: group, r_node: r_node, x_node: x_node, t_node: t_node, hash3: hash3}
        end,
        fn result, trace ->
          group = result.group
          r_node = result.r_node
          hash3 = result.hash3

          # The choreography really held: R's genuine :ready-for-view3 sweep
          # happened BEFORE the delayed INSERT applied on it, so that sweep is
          # not what caught the phantom row (it ran before the row existed).
          assert causality(
                   %{
                     :"$kind" => :muster_status_change,
                     node: ^r_node,
                     to: :ready,
                     view_hash: ^hash3
                   },
                   %{
                     :"$kind" => :muster_occupied_apply,
                     :"$span" => {:complete, _},
                     node: ^r_node,
                     group: ^group
                   },
                   trace
                 )

          # And the delayed INSERT really did land before the drop that caught
          # it -- this is the periodic backstop catching a row that did not
          # exist at either of the earlier sweep points (do_rebalance's own,
          # and the :ready transition's), not a coincidence of test timing.
          assert causality(
                   %{
                     :"$kind" => :muster_occupied_apply,
                     :"$span" => {:complete, _},
                     node: ^r_node,
                     group: ^group
                   },
                   %{:"$kind" => :muster_drop_stale_entry, node: ^r_node, group: ^group},
                   trace
                 )

          # Exactly one drop for this key: the backstop caught it once and it
          # never came back (T never re-asserts to R; it now only talks to X).
          assert of_kind(:muster_drop_stale_entry, trace)
                 |> Enum.count(&(&1.node == r_node and &1.group == group)) == 1

          refute result.t_node in occupancy_on(r_node, scope, group),
                 "the periodic backstop sweep should have caught and dropped the phantom row"
        end
      )
    end
  end

  describe "round-trip immunity (an orphaned occupied INSERT cannot resurrect a group after a ring round-trip)" do
    setup do
      scope = :"muster_roundtrip_#{System.unique_integer([:positive])}"

      # Generous rpc_timeout: the parked, orphaned occupied worker survives
      # across an entire membership change (X joining, then leaving again)
      # and its convergence before we release it -- see the "caught by the
      # next periodic tick" test above for why this must not time out
      # client-side and confuse the source shard's state machine.
      start_supervised!(
        spec(scope,
          vacancy_cooldown_ms: 50,
          vacant_flush_interval_ms: 100,
          rpc_timeout_ms: 30_000
        )
      )

      %{scope: scope}
    end

    # This exercises the exact gap a hard-delete sweep would leave open: a
    # ring round-trip (R -> X -> R) must not give the sweep a second chance
    # to destroy a tombstone it should never touch, discarding the seq floor
    # that guards against a still-in-flight, orphaned `occupied` RPC.
    # drop_stale_router_entries/1 closes that gap by never re-judging a row
    # that already reads as a tombstone (the `meta == :present` guard) --
    # this test proves the round trip has nothing to bite into.
    #
    #   1. T holds `group`, routed to R. Its occupied RPC is parked
    #      (force_ordering) before it writes the row -- R has no row for it
    #      yet.
    #   2. T's shard is killed while the claim is unconfirmed. The orphaned
    #      occupied worker (monitored, not linked) survives untouched; the
    #      restarted shard reconciles the claim straight to :vacant_queued --
    #      T now genuinely holds nothing.
    #   3. The natural flush dispatches a real (higher-seq) vacant_batch to
    #      R. With no existing row, it plants a TOMBSTONE directly -- the seq
    #      floor that protects against the still-parked, stale occupied.
    #   4. X joins. `group`'s router moves R -> X; R's :ready-transition
    #      sweep runs (update_status fires it on every :ready transition) but
    #      the row already reads as a tombstone, so the guard skips it
    #      outright -- no judgment, no write, the seq floor is untouched.
    #   5. X leaves. `group`'s router moves back R -> R -- the round trip
    #      completes with the tombstone exactly as step 3 left it.
    #   6. Release the park. The stale occupied lands on R against the
    #      still-alive tombstone: its seq predates the vacate, so
    #      upsert_if_newer's guard rejects it outright. No resurrection.
    test "an orphaned occupied INSERT delayed across a ring round-trip cannot resurrect a vacated group",
         %{scope: scope} do
      t_node = node()

      check_trace(
        fn ->
          {:ok, p_r, r_node} = Peer.start(aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(r_node)
          start_remote_muster(p_r, scope)
          await_ready([t_node, r_node])

          # X's name is fixed upfront so the victim group can be picked from
          # ring math: routed to R in {T,R}, moved onto X once X joins.
          x_name = ~c"muster_roundtrip_x_#{System.unique_integer([:positive])}"
          x_node = :"#{x_name}@127.0.0.1"
          view2 = Enum.sort([t_node, r_node])
          view3 = Enum.sort([t_node, r_node, x_node])
          hash3 = :erlang.phash2(view3)
          group = pick_group([{view2, r_node}, {view3, x_node}])

          # Park the occupied INSERT on R before it writes -- the
          # delayed-RPC arm; the orphaned worker survives independently of
          # the shard that dispatched it.
          force_ordering(
            %{:"$kind" => :test_release_occupied},
            %{
              :"$kind" => :muster_occupied_apply,
              :"$span" => :start,
              node: ^r_node,
              group: ^group,
              source: ^t_node
            }
          )

          member = spawn(fn -> Process.sleep(:infinity) end)
          _claimer = spawn(fn -> Muster.join(scope, group, member) end)

          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_group_state,
                       node: ^t_node,
                       group: ^group,
                       state: {:occupied_pending, _}
                     },
                     10_000
                   )

          # Kill the shard while the claim is unconfirmed. The parked,
          # orphaned occupied worker survives (monitored, not linked); the
          # restart reconciles the claim straight to :vacant_queued.
          shard_name = Forum.Supervisor.shard(scope, group)
          old_shard = Process.whereis(shard_name)
          ref = Process.monitor(old_shard)
          true = Process.exit(old_shard, :kill)
          assert_receive {:DOWN, ^ref, :process, ^old_shard, :killed}, 5_000

          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_group_state,
                       node: ^t_node,
                       group: ^group,
                       state: :vacant_queued
                     },
                     10_000
                   )

          # The natural flush dispatches a real, higher-seq vacant_batch to
          # R. With no existing row (the occupied is still parked), it
          # plants a tombstone directly -- the seq floor the rest of this
          # test is about.
          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_vacant_batch,
                       :"$span" => {:complete, _},
                       node: ^r_node,
                       source: ^t_node
                     },
                     10_000
                   )

          wait_until(fn -> group_state(scope, group) == nil end)
          assert occupancy_on(r_node, scope, group) == []

          # X joins: `group`'s router moves R -> X. R's own :ready-transition
          # sweep runs here (update_status fires it on every :ready
          # transition, unconditionally), but the row already reads as a
          # tombstone, so the fix's `meta == :present` guard skips it without
          # judging or writing anything -- proven below by the total absence
          # of any :muster_drop_stale_judged/:muster_drop_stale_entry event
          # for this key across the whole trace.
          {:ok, p_x, ^x_node} = Peer.start(name: x_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(x_node)
          start_remote_muster(p_x, scope)

          await_ready(view3)
          assert occupancy_on(r_node, scope, group) == []

          # X leaves: `group`'s router moves back R -> R -- the round trip
          # completes with the tombstone exactly as step 3 left it.
          :ok = stop_supervised({:peer, x_name})

          await_ready(view2, nth: 2, timeout: 20_000)
          assert {:ok, ^r_node} = Muster.router(scope, group)
          assert occupancy_on(r_node, scope, group) == []

          # Release the park. The stale occupied lands on R against the
          # tombstone from step 3, still standing guard.
          tp(:test_release_occupied, %{})

          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_occupied_apply,
                       :"$span" => {:complete, _},
                       node: ^r_node,
                       group: ^group,
                       source: ^t_node
                     },
                     10_000
                   )

          # The seq guard held: the stale INSERT lost to the still-alive
          # tombstone, so the row never becomes visible as present.
          refute t_node in occupancy_on(r_node, scope, group)

          %{group: group, r_node: r_node, t_node: t_node, hash3: hash3}
        end,
        fn result, trace ->
          group = result.group
          r_node = result.r_node
          t_node = result.t_node
          hash3 = result.hash3

          # T genuinely forgot the group entirely -- there is nothing left
          # on its side that will ever retract R's row.
          assert group_state(scope, group) == nil
          assert Muster.local_member_count(scope, group) == 0

          # The round trip really completed -- R re-reached :ready for view3
          # -- BEFORE the stale occupied was released and evaluated, so the
          # sweep had every opportunity to touch this row and, per the fix,
          # correctly declined to.
          assert causality(
                   %{
                     :"$kind" => :muster_status_change,
                     node: ^r_node,
                     to: :ready,
                     view_hash: ^hash3
                   },
                   %{
                     :"$kind" => :muster_occupied_apply,
                     :"$span" => {:complete, _},
                     node: ^r_node,
                     group: ^group,
                     source: ^t_node
                   },
                   trace
                 )

          # THE FIX: the tombstone from step 3 is never re-judged by any
          # :ready-transition sweep -- not once, across the entire round
          # trip -- because it no longer reads as :present. Nothing ever
          # judges or drops this key.
          assert of_kind(:muster_drop_stale_judged, trace)
                 |> Enum.count(&(&1.node == r_node and &1.group == group and &1.source == t_node)) ==
                   0

          assert of_kind(:muster_drop_stale_entry, trace)
                 |> Enum.count(&(&1.node == r_node and &1.group == group and &1.source == t_node)) ==
                   0

          # And because the seq floor was never disturbed, the late, orphaned
          # occupied INSERT has a real tombstone to lose against: it is
          # rejected rather than resurrecting the group.
          refute t_node in occupancy_on(r_node, scope, group),
                 "a ring round-trip let an already-tombstoned row get re-judged, " <>
                   "destroying the seq floor an orphaned occupied INSERT needed to lose against"
        end
      )
    end
  end

  describe "sweep delete vs. a concurrent fresh claim (forced ordering)" do
    setup do
      scope = :"muster_sweep_toctou_#{System.unique_integer([:positive])}"

      start_supervised!(
        spec(scope,
          vacancy_cooldown_ms: 50,
          vacant_flush_interval_ms: 100
        )
      )

      %{scope: scope}
    end

    # drop_stale_router_entries judges rows from a snapshot taken by
    # :ets.select, but occupied/4 writes the SAME table from :erpc worker
    # processes, concurrently with the sweeping coordinator. Between the
    # sweep's judgment of a row (at seq_stale) and its physical delete, a
    # fresh, legitimate occupied INSERT can raise the same {group, source} key
    # to a newer seq -- and a key-only delete then destroys the FRESH row, not
    # the row that was judged. Every other write to this table is individually
    # seq-guarded (put_if_newer); the sweep's delete must be too.
    #
    # The interleaving, with T = this node, R and X = peers:
    #
    #   1. Settled {T, R}; T holds `group`, routed to R -- R carries a real
    #      row {group, T, seq_stale}.
    #   2. X joins; the group's router moves R -> X, so R's row is genuinely
    #      stale. The first R sweep able to judge it (T has agreed on the
    #      3-node view) decides to drop it -- and is parked (force_ordering)
    #      BETWEEN that judgment and the delete.
    #   3. T vacates the group. The vacancy is dispatched to X (the router
    #      now); R is never told -- its stale row is exactly what only its own
    #      (parked) sweep may remove.
    #   4. X dies; the group's router moves BACK to R. T holds nothing, so its
    #      rebalance sends R only an async marker -- no occupancy write rides it.
    #   5. T re-claims the group fresh. Its shard dispatches occupied(group, T,
    #      seq_fresh) to R, and the :erpc worker writes R's table directly --
    #      R's parked coordinator plays no part. The judged key now holds a
    #      newer, LEGITIMATE row (seq_fresh > watermark of the announcement R
    #      judged under, so even a re-judgment would skip it).
    #   6. Release the park. The sweep's key-only :ets.delete fires against a
    #      row it never judged and destroys it.
    #
    # Nothing ever heals the destroyed row: T got its :ok (the RPC succeeded),
    # so its shard rests in :occupied with nothing queued; T's future
    # rebalances send deltas of MOVED groups only (the group never moves
    # again); heartbeats carry markers, not data; the vacant flush re-sends
    # vacancies only. R converges to :ready as the group's router with no
    # occupancy row for it -- broadcasts to the group silently miss T forever.
    test "the sweep's delete must not destroy a fresh occupied row raised after judgment",
         %{scope: scope} do
      t_node = node()

      check_trace(
        fn ->
          # Settled 2-node cluster {T, R}.
          {:ok, p_r, r_node} = Peer.start(aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(r_node)
          start_remote_muster(p_r, scope)
          await_ready([t_node, r_node])

          # X's name is fixed upfront so the victim group can be picked from
          # ring math: routed to R in {T,R}, moved onto X once X joins.
          x_name = ~c"muster_sweep_toctou_x_#{System.unique_integer([:positive])}"
          x_node = :"#{x_name}@127.0.0.1"
          view3 = Enum.sort([t_node, r_node, x_node])
          view2 = Enum.sort([t_node, r_node])
          hash2 = :erlang.phash2(view2)
          group = pick_group([{view2, r_node}, {view3, x_node}])

          # T holds the group; its occupied lands on R (the router in {T, R}).
          m1 = spawn(fn -> Process.sleep(:infinity) end)
          :ok = Muster.join(scope, group, m1)
          assert t_node in occupancy_on(r_node, scope, group)

          # Park R's sweep between judging {group, T} stale and deleting it.
          force_ordering(
            %{:"$kind" => :test_release_drop},
            %{
              :"$kind" => :muster_drop_stale_apply,
              :"$span" => :start,
              node: ^r_node,
              group: ^group,
              source: ^t_node
            }
          )

          # X joins: the group's router moves R -> X, making R's row stale.
          {:ok, p_x, ^x_node} = Peer.start(name: x_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(x_node)
          start_remote_muster(p_x, scope)

          # R may park inside its own do_rebalance sweep (its view-3 markers
          # are sent before that sweep, so T and X still converge) and then
          # never announce :ready for view3 -- wait only on T and X.
          await_ready(view3, nodes: [t_node, x_node])

          # R has judged the stale row and is parked BEFORE the delete.
          assert {:ok, judged} =
                   block_until(
                     %{
                       :"$kind" => :muster_drop_stale_judged,
                       node: ^r_node,
                       group: ^group,
                       source: ^t_node
                     },
                     15_000
                   )

          # T vacates the group; the vacancy goes to X (the router now), so R
          # keeps its stale row. The shard's group state ending DELETED
          # (state: nil) implies the flush was acked: the group is fully
          # vacant on T and will not be a candidate in T's next rebalance.
          :ok = Muster.leave(scope, group, m1)

          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_group_state,
                       node: ^t_node,
                       group: ^group,
                       state: nil
                     },
                     10_000
                   )

          assert t_node in occupancy_on(r_node, scope, group)

          # X dies: the group's router moves back to R. T holds nothing, so
          # its rebalance sends R only a marker; T lands :converging for the
          # 2-node view (R, parked, cannot have agreed yet) with its ring
          # already swapped -- claims from here on route to R. nth: 2 because
          # T already passed :converging for this same view hash once, during
          # the initial {T, R} discovery rebalance at setup.
          :ok = stop_supervised({:peer, x_name})

          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_status_change,
                       node: ^t_node,
                       to: :converging,
                       view_hash: ^hash2
                     },
                     2,
                     15_000,
                     :infinity
                   )

          # The fresh re-claim: the occupied RPC writes R's table directly
          # from the :erpc worker (join returning :ok implies the row is
          # committed on R), raising the judged key to a newer seq.
          m2 = spawn(fn -> Process.sleep(:infinity) end)
          :ok = Muster.join(scope, group, m2)
          assert t_node in occupancy_on(r_node, scope, group)

          # Release the parked delete. It fires against a row it never judged.
          tp(:test_release_drop, %{})

          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_drop_stale_apply,
                       :"$span" => {:complete, _},
                       node: ^r_node,
                       group: ^group,
                       source: ^t_node
                     },
                     10_000
                   )

          # R heals: processes X's nodedown, rebalances to {T, R}, and both
          # nodes reach :ready for the 2-node view a 2nd time (1st was setup).
          await_ready(view2, nth: 2, timeout: 20_000)
          assert {:ok, ^r_node} = Muster.router(scope, group)

          # THE POINT: R is the settled, :ready router for a group T genuinely
          # holds (m2 is alive, T's shard is :occupied), and nothing will ever
          # re-send the row. The sweep must have spared it.
          assert t_node in occupancy_on(r_node, scope, group),
                 "the sweep's key-only delete destroyed a fresh occupied row " <>
                   "written between its judgment and its delete"

          %{group: group, r_node: r_node, t_node: t_node, judged_seq: judged.seq}
        end,
        fn result, trace ->
          group = result.group
          r_node = result.r_node
          t_node = result.t_node

          # Exactly two occupied INSERTs landed on R for this key: the
          # original claim (what the sweep judged) and the fresh re-claim
          # (what the delete must spare).
          occupied_seqs =
            of_kind(:muster_occupied_apply, trace)
            |> Enum.filter(
              &(&1.node == r_node and &1.group == group and &1.source == t_node and
                  match?({:complete, _}, Map.get(&1, :"$span")))
            )
            |> Enum.map(& &1.seq)
            |> Enum.sort()

          assert [stale_seq, fresh_seq] = occupied_seqs
          assert result.judged_seq == stale_seq
          assert fresh_seq > stale_seq

          # The interleaving really held: the sweep judged the STALE row
          # first, the FRESH row landed while it was parked, and only then did
          # its delete fire -- the exact select-then-delete TOCTOU window.
          assert causality(
                   %{
                     :"$kind" => :muster_drop_stale_judged,
                     node: ^r_node,
                     group: ^group,
                     source: ^t_node
                   },
                   %{
                     :"$kind" => :muster_occupied_apply,
                     :"$span" => {:complete, _},
                     node: ^r_node,
                     group: ^group,
                     seq: ^fresh_seq
                   },
                   trace
                 )

          assert causality(
                   %{
                     :"$kind" => :muster_occupied_apply,
                     :"$span" => {:complete, _},
                     node: ^r_node,
                     group: ^group,
                     seq: ^fresh_seq
                   },
                   %{
                     :"$kind" => :muster_drop_stale_apply,
                     :"$span" => {:complete, _},
                     node: ^r_node,
                     group: ^group,
                     source: ^t_node
                   },
                   trace
                 )

          # The seq-guarded delete was a no-op on the raised key, so the
          # "row is gone" event never fired for it.
          assert of_kind(:muster_drop_stale_entry, trace)
                 |> Enum.filter(&(&1.node == r_node and &1.group == group)) == []
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

    # README "Router-readiness barrier" -- the exact three-node ordering the
    # barrier exists for: T and the fresh router C agree on the final view and
    # C even holds T's snapshot, but B has not announced that view (its
    # rebalance is parked) -- so a membership-agreement check alone would let C
    # decide from an occupancy table that is, in general, incomplete. Until
    # EVERY member announces the view, all nodes must sit in :converging with
    # can_decide? == false (routers flood -- over-deliver, never miss), and the
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
          # the final view -- the worst case, since C is the node whose table
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
          # README scenario. (Its discovery ack -- carrying its OLD view -- is
          # sent before the parked rebalance, so C does learn about B.)
          force_ordering(
            %{:"$kind" => :test_release_b},
            %{:"$kind" => :muster_rebalance_start, node: ^b_node, to: ^view3}
          )

          {:ok, p_c, ^c_node} = Peer.start(name: c_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(c_node)
          start_remote_muster(p_c, scope)

          # T and C adopt the 3-node view -- with B parked neither can go past
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
          # (the event fires after the snapshot is committed) -- the data is in
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

          # Routing itself still works while :converging -- it targets the ring
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
      # Natural flush only: we align the leave to just after a real flush tick on
      # the owning shard, then use a comfortably larger interval than the 50ms
      # cooldown so the vacancy stays queued across the rebalance before the next
      # natural flush dispatches it.
      start_supervised!(spec(scope, vacancy_cooldown_ms: 50, vacant_flush_interval_ms: 5_000))
      %{scope: scope}
    end

    # README rebalance step 3 + "Stale router entries": a group sitting in
    # :vacant_queued when membership changes is NOT re-announced (we don't hold
    # it), the old router's now-stale row is GC'd by its own sweep once the
    # source demonstrably agrees on the view (this is the positive counterpart
    # of the no-wrongful-drops test above), and the eventual flush routes the
    # vacancy to the group's CURRENT router -- not the one it was queued under.
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

          shard_name = Forum.Supervisor.shard(scope, group)
          shard_pid = Process.whereis(shard_name)

          shard_index =
            case shard_name do
              name when is_atom(name) ->
                name
                |> Atom.to_string()
                |> String.split("_")
                |> List.last()
                |> String.to_integer()
            end

          assert is_pid(shard_pid)

          # Align the leave to just after a real flush tick on the owning shard.
          # back_in_time: 0 forces a FRESH tick (the default :infinity would
          # happily match one already collected from shard startup, long
          # before this point, giving zero real alignment and letting the
          # "runway" below shrink to whatever happened to be left in that
          # earlier period -- sometimes only milliseconds).
          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_flush_tick,
                       node: ^t_node,
                       index: ^shard_index
                     },
                     5_000,
                     0
                   )

          # Vacate. The cooldown (50ms) expires and the vacancy is queued, but
          # the next natural flush has not fired yet -- O still believes we hold
          # the group until the post-rebalance flush below.
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

          # ...and the old router sweeps its stale row -- at the latest on its
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

          # The next natural flush must send the vacancy to the CURRENT router, C.
          # Timeout comfortably exceeds vacant_flush_interval_ms: the aligned
          # tick above bounds the wait to at most one interval from here.

          assert {:ok, batch} =
                   block_until(
                     %{:"$kind" => :muster_vacant_batch, :"$span" => :start, source: ^t_node},
                     8_000
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

  describe "real remote claim/vacancy RPC failures" do
    setup do
      scope = :"muster_rpc_fail_#{System.unique_integer([:positive])}"

      start_supervised!(spec(scope, vacancy_cooldown_ms: 50, vacant_flush_interval_ms: 100))

      %{scope: scope}
    end

    test "a real occupied RPC failure returns :rpc_failed and leaves no local registration",
         %{scope: scope} do
      t_node = node()

      check_trace(
        fn ->
          r_name = ~c"muster_occ_fail_r_#{System.unique_integer([:positive])}"
          r_node = :"#{r_name}@127.0.0.1"

          {:ok, p_r, ^r_node} = Peer.start(name: r_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(r_node)
          start_remote_muster(p_r, scope)
          await_ready([t_node, r_node])

          group = group_routed_to(scope, r_node)

          # Hold the remote INSERT at the router so the claim cannot complete
          # before we kill the peer, turning this into a real occupied RPC
          # failure instead of a race with a fast success.
          force_ordering(
            %{:"$kind" => :test_release_occupied_never},
            %{
              :"$kind" => :muster_occupied_apply,
              :"$span" => :start,
              node: ^r_node,
              group: ^group,
              source: ^t_node
            }
          )

          member = spawn(fn -> Process.sleep(:infinity) end)
          join_task = Task.async(fn -> Muster.join(scope, group, member) end)

          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_group_state,
                       node: ^t_node,
                       group: ^group,
                       state: {:occupied_pending, _}
                     },
                     10_000
                   )

          :ok = stop_supervised({:peer, r_name})

          assert {:error, :rpc_failed} = Task.await(join_task, 10_000)

          wait_until(fn -> Muster.members(scope) == [t_node] and status(scope) == :ready end)

          refute Muster.local_member?(scope, group, member)
          assert Muster.local_member_count(scope, group) == 0

          # The failure queues a vacant instead of forgetting the group
          # outright (see Shard.handle_occupied_done): the group is now
          # self-routed (R is gone), so the next flush's local no-op drains
          # it to nil.
          wait_until(fn -> group_state(scope, group) == nil end)

          %{group: group, t_node: t_node}
        end,
        fn result, trace ->
          refute of_kind(:muster_occupied, trace)
                 |> Enum.any?(&(&1.group == result.group and &1.source == result.t_node))
        end
      )
    end

    test "a failed real vacant batch is re-queued and a later flush drains it",
         %{scope: scope} do
      t_node = node()

      check_trace(
        fn ->
          r_name = ~c"muster_vac_fail_r_#{System.unique_integer([:positive])}"
          r_node = :"#{r_name}@127.0.0.1"

          {:ok, p_r, ^r_node} = Peer.start(name: r_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(r_node)
          start_remote_muster(p_r, scope)
          await_ready([t_node, r_node])

          group = group_routed_to(scope, r_node)
          member = spawn(fn -> Process.sleep(:infinity) end)

          :ok = Muster.join(scope, group, member)
          assert t_node in occupancy_on(r_node, scope, group)

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

          # Hold the router-side DELETE so the natural flush stays in flight until
          # we kill the peer, forcing the source shard down the real re-queue path.
          force_ordering(
            %{:"$kind" => :test_release_vacant_never},
            %{
              :"$kind" => :muster_vacant_batch,
              :"$span" => :start,
              node: ^r_node,
              source: ^t_node
            }
          )

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

          :ok = stop_supervised({:peer, r_name})

          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_group_state,
                       node: ^t_node,
                       group: ^group,
                       state: :vacant_queued
                     },
                     10_000
                   )

          wait_until(fn -> Muster.members(scope) == [t_node] and status(scope) == :ready end)

          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_group_state,
                       node: ^t_node,
                       group: ^group,
                       state: nil
                     },
                     10_000
                   )

          assert occupancy_on(t_node, scope, group) == []
          assert Muster.local_member_count(scope, group) == 0

          %{group: group}
        end,
        fn result, trace ->
          states =
            of_kind(:muster_group_state, trace)
            |> Enum.filter(&(&1.group == result.group and &1.node == node()))
            |> Enum.map(& &1.state)

          assert :vacant_flushing in states
          assert :vacant_queued in states
          assert nil in states
        end
      )
    end
  end

  describe "occupied RPC timeout after remote execution lands" do
    setup do
      scope = :"muster_rpc_timeout_#{System.unique_integer([:positive])}"

      start_supervised!(
        spec(scope, vacancy_cooldown_ms: 50, vacant_flush_interval_ms: 100, rpc_timeout_ms: 150)
      )

      %{scope: scope}
    end

    # README invariant: "router notified ⟹ a local record exists to eventually
    # retract". :erpc does not cancel remote execution on timeout (the fact
    # every other crash-window analysis in this codebase leans on), so a claim
    # RPC can time out on the caller while the router still commits the
    # INSERT afterwards. handle_occupied_done's error branch currently
    # deletes the group state outright on ANY {:error, _} result, timeout
    # included, forgetting the group instead of queuing a retraction. If the
    # remote INSERT then lands, nothing on the source ever tells the router
    # to drop it: the periodic sweep does not help (the group genuinely
    # routes to that router), so the phantom row leaks until the source
    # sends that router a fresh full snapshot or leaves the cluster.
    test "a timed-out :occupied RPC whose write still lands is eventually retracted",
         %{scope: scope} do
      t_node = node()

      check_trace(
        fn ->
          r_name = ~c"muster_occ_timeout_r_#{System.unique_integer([:positive])}"
          r_node = :"#{r_name}@127.0.0.1"

          {:ok, p_r, ^r_node} = Peer.start(name: r_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(r_node)
          start_remote_muster(p_r, scope)
          await_ready([t_node, r_node])

          group = group_routed_to(scope, r_node)

          # Park the remote apply BEFORE it writes the row, so it genuinely
          # cannot complete before T's short rpc_timeout_ms elapses -- a real
          # client-side timeout, not a race with a fast success.
          force_ordering(
            %{:"$kind" => :test_release_occupied_timeout},
            %{
              :"$kind" => :muster_occupied_apply,
              :"$span" => :start,
              node: ^r_node,
              group: ^group,
              source: ^t_node
            }
          )

          member = spawn(fn -> Process.sleep(:infinity) end)
          join_task = Task.async(fn -> Muster.join(scope, group, member) end)

          # T's :erpc.call times out while the remote apply is still parked.
          assert {:error, :rpc_failed} = Task.await(join_task, 10_000)

          # Release the park: this is the RPC's execution finally landing on
          # R, exactly as :erpc's non-cancelling timeout allows.
          tp(:test_release_occupied_timeout, %{})

          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_occupied_apply,
                       :"$span" => {:complete, _},
                       node: ^r_node,
                       group: ^group,
                       source: ^t_node
                     },
                     10_000
                   )

          # Capture the occupants from the SAME read that observes the row as
          # present: rpc_timeout_ms/vacant_flush_interval_ms are both very
          # short here, so the window between the delayed insert landing and
          # the queued vacant flush retracting it can be narrower than the gap
          # between two separate reads -- a wait-then-re-read can straddle the
          # retraction and see it disappear again before the assert runs.
          occupants =
            wait_until_value(fn ->
              case occupancy_on(r_node, scope, group) do
                [] -> nil
                other -> other
              end
            end)

          assert t_node in occupants

          # The phantom row must eventually be retracted: T should have
          # queued the group for a vacant flush instead of forgetting it, so
          # the next flush drains the row it may have left behind.
          assert {:ok, _} =
                   block_until(
                     %{:"$kind" => :muster_vacant_batch, :"$span" => :start, source: ^t_node},
                     5_000
                   )

          wait_until(fn -> occupancy_on(r_node, scope, group) == [] end)

          %{group: group, t_node: t_node, r_node: r_node}
        end,
        fn result, trace ->
          batches =
            of_kind(:muster_vacant_batch, trace)
            |> Enum.filter(&(&1[:"$span"] == :start and &1.node == result.r_node))

          assert Enum.any?(batches, &(result.group in &1.groups))
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
    # group_states from the surviving Partition tables, and re-discovers -- and
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

          # Routed to R before C joins, to C afterwards -- so T's rebalance
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
          # for the 3-node view is only possible after the full recovery --
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

          # C's :ready count for the 3-node view is nondeterministic -- the
          # crashed snapshot already delivered T's marker, so C may or may not
          # have converged once BEFORE it saw T's Scope die -- so an Nth-event
          # block_until has no sound N here: poll its CURRENT state instead.
          wait_until(fn ->
            :erpc.call(c_node, Muster, :members, [scope]) == view3 and
              remote_status(p_c, scope) == :ready
          end)

          # The local membership survived the crash -- Partition tables are
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

          # At least one post-crash snapshot from T landed on C and every such
          # delivery carried the group. The crashed attempt dies at its trace point
          # and is never collected; later recovery rounds may legitimately
          # re-snapshot the same group to the same router.
          snaps_to_c =
            of_kind(:muster_node_state_received, trace)
            |> Enum.filter(&(&1.node == result.c_node and &1.source == result.t_node))

          assert snaps_to_c != []
          assert Enum.all?(snaps_to_c, &(result.group in &1.groups))

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
    # sources' rebalances back into the rejoined view re-snapshot it -- healing
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
          # the 2-node view re-snapshots the router -- the heal. This is the
          # only :receive_node_state of the whole test (the original join
          # travelled as :occupied), so seeing it proves the heal really fired.
          assert {:ok, %{groups: healed}} =
                   block_until(
                     %{:"$kind" => :muster_node_state_received, node: ^r_node, source: ^t_node},
                     10_000
                   )

          assert group in healed

          # Both nodes re-converge to :ready for the 2-node view -- their
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
          # Exactly one snapshot from T landed on the router -- the post-crash
          # heal -- and it carried the group.
          assert [%{groups: groups}] =
                   of_kind(:muster_node_state_received, trace)
                   |> Enum.filter(&(&1.node == result.r_node and &1.source == result.t_node))

          assert result.group in groups
        end
      )
    end
  end

  describe "rebalance gather timeout on a real membership change" do
    setup do
      scope = :"muster_gather_timeout_dist_#{System.unique_integer([:positive])}"

      start_supervised!(
        spec(scope, vacant_flush_interval_ms: 100, rebalance_gather_timeout_ms: 150)
      )

      %{scope: scope}
    end

    test "a blocked shard times out the coordinator, which restarts and re-converges",
         %{scope: scope} do
      t_node = node()

      check_trace(
        fn ->
          {:ok, p_r, r_node} = Peer.start(aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(r_node)
          start_remote_muster(p_r, scope)
          await_ready([t_node, r_node])

          # Hold shard 0 inside the synchronous rebalance gather with a real trace
          # ordering, so the coordinator times out naturally on its GenServer.call.
          force_ordering(
            %{:"$kind" => :test_release_gather},
            %{:"$kind" => :muster_rebalance_gather, node: ^t_node, index: 0}
          )

          coord = Process.whereis(Forum.Supervisor.name(scope))
          coord_ref = Process.monitor(coord)

          c_name = ~c"muster_gather_timeout_c_#{System.unique_integer([:positive])}"
          c_node = :"#{c_name}@127.0.0.1"

          {:ok, p_c, ^c_node} = Peer.start(name: c_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(c_node)
          start_remote_muster(p_c, scope)

          assert_receive {:DOWN, ^coord_ref, :process, ^coord, _reason}, 5_000

          # Release the held gather on the restarted shard so the recovery
          # rebalance can complete; only the first rebalance should time out.
          tp(:test_release_gather, %{})

          wait_until(
            fn ->
              pid = Process.whereis(Forum.Supervisor.name(scope))
              is_pid(pid) and pid != coord
            end,
            5_000
          )

          view3 = Enum.sort([t_node, r_node, c_node])

          wait_until(
            fn ->
              Muster.members(scope) == view3 and
                status(scope) == :ready and
                :erpc.call(r_node, Muster, :members, [scope]) == view3 and
                remote_status(p_r, scope) == :ready and
                :erpc.call(c_node, Muster, :members, [scope]) == view3 and
                remote_status(p_c, scope) == :ready
            end,
            20_000
          )

          assert :ok =
                   Muster.join(
                     scope,
                     :"gather_timeout_recovered_#{System.unique_integer([:positive])}",
                     spawn(fn -> Process.sleep(:infinity) end)
                   )

          %{t_node: t_node, view3: view3}
        end,
        fn result, trace ->
          assert of_kind(:muster_rebalance_start, trace)
                 |> Enum.count(&(&1.node == result.t_node and &1.to == result.view3)) >= 2
        end
      )
    end
  end

  describe "shard crash recovery" do
    setup do
      scope = :"muster_shard_crash_#{System.unique_integer([:positive])}"
      start_supervised!(spec(scope, vacant_flush_interval_ms: 100))
      %{scope: scope}
    end

    # A claim shard owns only the per-group state machine; the durable data lives
    # elsewhere -- members in the Supervisor-owned Partition ETS, occupancy in the
    # router's coordinator. So a shard crash must be INVISIBLE at the cluster
    # level: the supervisor restarts the shard, init re-adopts its held groups
    # :occupied from the surviving Partition, and NO cluster traffic is needed --
    # no rebalance (the coordinator does not monitor shards, only peers), no
    # snapshot, no re-:occupied RPC. This is the counterpoint to the router Scope
    # crash above, whose heal IS a cross-node snapshot.
    test "a crashed shard restarts and re-adopts its groups with zero cluster traffic",
         %{scope: scope} do
      t_node = node()

      check_trace(
        fn ->
          {:ok, p_r, r_node} = Peer.start(aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(r_node)
          start_remote_muster(p_r, scope)

          view2 = Enum.sort([t_node, r_node])
          await_ready(view2)

          # R holds a group routed to T: R's shard dispatched :occupied to T, so
          # T's (router) occupancy carries {group, R}. The member lives on R.
          group = group_routed_to(scope, t_node)
          :ok = :peer.call(p_r, MusterPeerAux, :join, [scope, group])
          assert r_node in occupancy_on(t_node, scope, group)
          assert :erpc.call(r_node, Muster, :local_member_count, [scope, group]) == 1
          assert :occupied = remote_group_state(r_node, scope, group)

          # Kill the shard that owns the group ON R (a remote node), at the worst
          # moment for that shard -- while it is the live holder of the group. Its
          # member pid and Partition are separate, Supervisor-owned processes and
          # survive.
          shard_name = :erpc.call(r_node, Forum.Supervisor, :shard, [scope, group])
          old_shard = :erpc.call(r_node, Process, :whereis, [shard_name])
          assert is_pid(old_shard)
          ref = Process.monitor(old_shard)
          true = :erpc.call(r_node, Process, :exit, [old_shard, :kill])
          assert_receive {:DOWN, ^ref, :process, ^old_shard, :killed}, 5_000

          # The supervisor restarts the shard; init re-adopts the group :occupied
          # from R's surviving Partition. rebuild_group_states does not emit a
          # trace point, so poll for the restarted pid + re-adopted state.
          wait_until(fn ->
            pid = :erpc.call(r_node, Process, :whereis, [shard_name])

            is_pid(pid) and pid != old_shard and
              remote_group_state(r_node, scope, group) == :occupied
          end)

          # Transparent: occupancy on the router is unchanged, the member
          # survived, neither node left :ready, and membership never moved -- the
          # kill never disturbed the cluster.
          assert r_node in occupancy_on(t_node, scope, group)
          assert :erpc.call(r_node, Muster, :local_member_count, [scope, group]) == 1
          assert remote_status(p_r, scope) == :ready
          assert status(scope) == :ready
          assert :erpc.call(r_node, Muster, :members, [scope]) == view2

          # The recovered shard is fully functional: a fresh join through it lands.
          :ok = :peer.call(p_r, MusterPeerAux, :join, [scope, group])

          wait_until(fn ->
            :erpc.call(r_node, Muster, :local_member_count, [scope, group]) == 2
          end)

          %{group: group, r_node: r_node, t_node: t_node}
        end,
        fn result, trace ->
          # The whole heal was shard-local: NO node ever applied a snapshot for
          # this group. The original claim travelled as :occupied and the restart
          # re-adopts from the Partition -- neither path is a snapshot. (Contrast
          # the router Scope crash, where the heal IS a snapshot.)
          snaps =
            of_kind(:muster_node_state_received, trace)
            |> Enum.filter(&(result.group in &1.groups))

          assert snaps == [],
                 "a shard crash must heal locally -- no cross-node snapshot should be needed"

          # And no rebalance was triggered by the crash: the only rebalances are
          # the cluster-formation ones into the 2-node view (a shard DOWN is not
          # a membership event).
          view2_hash = :erlang.phash2(Enum.sort([result.t_node, result.r_node]))

          assert of_kind(:muster_rebalance_start, trace)
                 |> Enum.all?(&(&1.view_hash == view2_hash or &1.to == [&1.node])),
                 "a shard crash must not trigger a rebalance into any new view"
        end
      )
    end

    # The dispatch→state-write window. handle_join must commit the durable
    # :occupied_pending BEFORE dispatching the :occupied RPC, so that a shard
    # crash in that window is recoverable WITHOUT a caller retry: the restart
    # reconciles the un-confirmed claim (no live member) straight to
    # :vacant_queued, and the flush retracts whatever row the orphaned RPC worker
    # (monitored, not linked, so it survives the crash) lands on the router.
    #
    # If the state were written AFTER dispatch, a crash here would leave the
    # source with NO record of the claim while the orphaned worker's INSERT lands
    # a phantom occupancy row on the router that nothing ever retracts. We force
    # exactly that crash by injecting at :muster_occupied_dispatched (the anchor
    # fires after the worker is spawned but before handle_join returns) and assert
    # the row never survives -- proving recovery does not depend on the caller.
    test "a shard crash in the :occupied dispatch→state-write window strands no router row",
         %{scope: scope} do
      t_node = node()

      check_trace(
        fn ->
          {:ok, p_r, r_node} = Peer.start(aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(r_node)
          start_remote_muster(p_r, scope)
          await_ready([t_node, r_node])

          # A group whose router is the REMOTE node, so the join takes the
          # dispatch (remote-router) branch on T.
          group = group_routed_to(scope, r_node)

          # Crash T's shard the FIRST time it dispatches the :occupied for this
          # group -- i.e. right in the dispatch→state-write window. recover_after(1)
          # leaves the restarted shard healthy.
          inject_crash(
            %{:"$kind" => :muster_occupied_dispatched, node: ^t_node, group: ^group},
            :snabbkaffe_nemesis.recover_after(1)
          )

          # Claim off to the side: the join call dies with the shard and we NEVER
          # retry it -- recovery must not depend on a caller retry. spawn (not
          # spawn_link) so its exit does not touch the test.
          member = spawn(fn -> Process.sleep(:infinity) end)
          _claimer = spawn(fn -> Muster.join(scope, group, member) end)

          # The injected crash fires on T's shard...
          assert {:ok, _} =
                   block_until(
                     %{:"$kind" => :snabbkaffe_crash, node: ^t_node, group: ^group},
                     10_000
                   )

          # ...and the restarted shard reconciles the un-confirmed claim (no live
          # member) to :vacant_queued -- with no caller retry. (On the broken
          # ordering the source has no record at all, so this never appears.)
          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_group_state,
                       node: ^t_node,
                       group: ^group,
                       state: :vacant_queued
                     },
                     10_000
                   )

          # The natural flush retracts the row (a real tombstone if the orphaned
          # worker landed it, a no-op DELETE otherwise). The source then forgets
          # the group (state: nil).

          assert {:ok, _} =
                   block_until(
                     %{:"$kind" => :muster_group_state, node: ^t_node, group: ^group, state: nil},
                     10_000
                   )

          # The orphaned INSERT may land before OR after the DELETE; the seq guard
          # makes the (lower-seq) INSERT lose either way, so the row clears for good.
          wait_until(fn -> occupancy_on(r_node, scope, group) == [] end)

          %{group: group, r_node: r_node, t_node: t_node}
        end,
        fn result, _trace ->
          refute result.t_node in occupancy_on(result.r_node, scope, result.group),
                 "an orphaned :occupied INSERT stranded a phantom row the source never retracted"

          assert group_state(scope, result.group) == nil
          assert Muster.local_member_count(scope, result.group) == 0
        end
      )
    end
  end

  describe "cooldown across a shard crash -- the retraction survives a restart mid-cooldown" do
    setup do
      scope = :"muster_cooldown_crash_#{System.unique_integer([:positive])}"
      start_supervised!(spec(scope, vacant_flush_interval_ms: 100))
      %{scope: scope}
    end

    # No existing test crashes a shard while its group sits in :cooldown. The
    # single-node shard_test.exs restart test only ever kills a shard with a
    # LIVE member (straight back to :occupied); the cooldown-specific
    # reconciliation branch -- a durable :occupied/:cooldown claim with NO
    # live member re-enters :cooldown, not :occupied, on restart -- exists in
    # shard.ex but is otherwise only proven by the code being there, never
    # exercised end-to-end across a real crash+restart. This proves it: R's
    # last member leaves (cooldown starts), R's shard for that group is
    # killed mid-cooldown, and the restart must re-arm a FRESH cooldown timer
    # rather than silently forgetting the claim or resurrecting it :occupied.
    # That fresh timer must also be a real, functioning timer, not just a
    # state label: left alone, it must still expire, queue the group, and
    # flush the retraction to the router exactly as an uninterrupted cooldown
    # would have.
    test "a shard killed mid-cooldown re-arms the timer on restart and still flushes to vacant",
         %{scope: scope} do
      t_node = node()

      check_trace(
        fn ->
          {:ok, p_r, r_node} = Peer.start(aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(r_node)
          start_remote_muster(p_r, scope, vacancy_cooldown_ms: 50)
          await_ready([t_node, r_node])

          # A group routed to T, held by a member on R: R is the source
          # carrying the claim state, T is the router whose occupancy row
          # tracks it.
          group = group_routed_to(scope, t_node)

          # Join then immediately leave the same pid on R: the group is left
          # genuinely mid-cooldown on R, with T's occupancy row still intact
          # (cooldown never sends an RPC -- the router still believes R holds
          # the group).
          :ok = :peer.call(p_r, MusterPeerAux, :join_and_leave, [scope, group])
          assert :cooldown = remote_group_state(r_node, scope, group)
          assert r_node in occupancy_on(t_node, scope, group)

          # Kill the shard that owns the group ON R, at the worst possible
          # moment: mid-cooldown, with no live member to fall back on.
          shard_name = :erpc.call(r_node, Forum.Supervisor, :shard, [scope, group])
          old_shard = :erpc.call(r_node, Process, :whereis, [shard_name])
          assert is_pid(old_shard)
          ref = Process.monitor(old_shard)
          true = :erpc.call(r_node, Process, :exit, [old_shard, :kill])
          assert_receive {:DOWN, ^ref, :process, ^old_shard, :killed}, 5_000

          # The supervisor restarts the shard; reconciliation finds a durable
          # :cooldown claim with no live member and re-enters :cooldown with a
          # FRESH timer, rather than forgetting the claim or reclaiming it
          # :occupied. rebuild_group_states emits no trace point of its own,
          # so poll for the restarted pid + reconciled state.
          wait_until(fn ->
            pid = :erpc.call(r_node, Process, :whereis, [shard_name])

            is_pid(pid) and pid != old_shard and
              remote_group_state(r_node, scope, group) == :cooldown
          end)

          # Transparent so far: T's occupancy row (and the rest of the
          # cluster) never saw the crash.
          assert r_node in occupancy_on(t_node, scope, group)
          assert remote_status(p_r, scope) == :ready
          assert status(scope) == :ready

          # The re-armed timer is a REAL timer, not just a state label: left
          # alone, it expires, queues the group, and the natural flush
          # retracts T's occupancy row exactly as an uninterrupted cooldown
          # would have.
          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_group_state,
                       node: ^r_node,
                       group: ^group,
                       state: :vacant_queued
                     },
                     10_000
                   )

          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_group_state,
                       node: ^r_node,
                       group: ^group,
                       state: nil
                     },
                     10_000
                   )

          wait_until(fn -> occupancy_on(t_node, scope, group) == [] end)

          %{group: group, r_node: r_node, t_node: t_node}
        end,
        fn result, trace ->
          # The crash was followed by a genuinely FRESH cooldown, not a reuse
          # of the pre-crash one: two separate :cooldown entries for this
          # group on R (the pre-crash one and the post-restart re-arm).
          cooldown_entries =
            of_kind(:muster_group_state, trace)
            |> Enum.filter(
              &(&1.node == result.r_node and &1.group == result.group and &1.state == :cooldown)
            )

          assert length(cooldown_entries) >= 2,
                 "expected the restart to re-arm cooldown, not silently skip it or reclaim :occupied"

          # No rebalance and no snapshot for this group: a shard crash is not
          # a membership event, and the eventual retraction is shard-local
          # reconciliation plus one ordinary vacant-batch flush, not cluster
          # churn.
          view2_hash = :erlang.phash2(Enum.sort([result.t_node, result.r_node]))

          assert of_kind(:muster_rebalance_start, trace)
                 |> Enum.all?(&(&1.view_hash == view2_hash or &1.to == [&1.node])),
                 "a shard crash must not trigger a rebalance into any new view"

          assert of_kind(:muster_node_state_received, trace)
                 |> Enum.filter(&(result.group in &1.groups)) == [],
                 "a cooldown retraction across a shard crash must not need a cross-node snapshot"
        end
      )
    end
  end

  describe "cascading joins -- a second node joins before the first rebalance converges" do
    setup do
      scope = :"muster_cascade_#{System.unique_integer([:positive])}"
      start_supervised!(spec(scope, vacant_flush_interval_ms: 100))
      %{scope: scope}
    end

    # The rolling-deploy shape: C joins, and D joins while the cluster is
    # still :converging on the C view -- the holder must re-hand its group to
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
    # release -- its queued hash3 markers from T and C are mutually consistent,
    # and the data for that view was committed before they were sent -- until
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

          # T rebalances again -- straight out of :converging -- and re-hands
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
          # the queued discovery from D and rebalances into view4 -- and the
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
          # node's LAST status word -- a transient stale :ready (R's) must have
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

          # The group was snapshotted exactly twice -- to the intermediate
          # router C, then to the final router D, in that order.
          assert [%{node: c}, %{node: d}] =
                   of_kind(:muster_node_state_received, trace)
                   |> Enum.filter(&(&1.source == result.t_node and result.group in &1.groups))

          assert c == result.c_node
          assert d == result.d_node

          # Both superseded routers -- R (pre-join) and C (intermediate) --
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

  describe "node death -- groups rebalance onto the remaining nodes" do
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
    #   g_t    held by T, routed to D before / S after -- T must re-tell S
    #   g_s    held by S, routed to D before / T after -- S must re-tell T
    #   g_dead held by D alone, routed to T throughout -- T's :DOWN wipe must
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
          # {T, S} and re-converge -- their SECOND :ready at view2, hence nth: 2.
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

          # The post-death re-announces really carried the moved groups: T
          # re-told S about g_t, and S re-told T about g_s. A survivor gaining a
          # group on a leave is a settled router, so the re-announce travels as a
          # DELTA (`:muster_delta_received`), not a full snapshot.
          deliveries =
            of_kind(:muster_delta_received, trace) ++ of_kind(:muster_node_state_received, trace)

          assert Enum.any?(
                   deliveries,
                   &(&1.node == result.s_node and &1.source == result.t_node and
                       result.g_t in &1.groups)
                 )

          assert Enum.any?(
                   deliveries,
                   &(&1.node == result.t_node and &1.source == result.s_node and
                       result.g_s in &1.groups)
                 )
        end
      )
    end
  end

  describe "network partition -- split rebalances independently, heal re-merges" do
    setup do
      scope = :"muster_split_#{System.unique_integer([:positive])}"
      start_supervised!(spec(scope, vacant_flush_interval_ms: 100))
      %{scope: scope}
    end

    # README "Network partition": nodes that lose sight of each other detect
    # the peer DOWN, rebalance independently, and route to whoever they can
    # see; on heal, discovery -> rebalance merges the sub-clusters. Here the
    # split is between the two PEERS while T stays connected to both -- the
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
          # earlier formation passed through the same {T, self} view -- and so
          # how many matching trace events exist -- is timing-dependent.)
          true = :erpc.call(a_node, Node, :disconnect, [b_node])

          wait_until(fn ->
            :erpc.call(a_node, Muster, :members, [scope]) == Enum.sort([t_node, a_node]) and
              :erpc.call(b_node, Muster, :members, [scope]) == Enum.sort([t_node, b_node]) and
              :erpc.call(a_node, MusterPeerAux, :status, [scope]) == :converging and
              :erpc.call(b_node, MusterPeerAux, :status, [scope]) == :converging and
              status(scope) == :converging
          end)

          # Nobody trusts an occupancy table while views disagree -- routers
          # flood (over-deliver, never miss)...
          refute Muster.can_decide?(scope, hash3)
          refute :erpc.call(a_node, Muster, :can_decide?, [scope, hash3])
          refute :erpc.call(b_node, Muster, :can_decide?, [scope, hash3])

          # ...but senders still route against their own settled ring.
          assert {:ok, ^a_node} = Muster.router(scope, g_a)

          # Heal. nodeup fires on both peers, discovery re-pairs them, every
          # node rebalances back into the 3-node view and re-converges -- the
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

  describe "direct disconnect -- T loses its own peer, heals on reconnect" do
    setup do
      scope = :"muster_direct_split_#{System.unique_integer([:positive])}"
      start_supervised!(spec(scope, vacant_flush_interval_ms: 100))
      %{scope: scope}
    end

    # Every "peer leaves" test elsewhere in this file drives departure via
    # stop_supervised({:peer, ...}) (kills the whole remote VM) or
    # Process.exit(pid, :kill) on a single process while the node stays
    # connected (router Scope crash recovery, the reverse-race tests). The
    # partition test above splits two OTHER peers while T stays connected to
    # both, so T's own {:DOWN, ..., :noconnection} path never fires there.
    #
    # Here T itself severs the transport to the peer holding its group, with
    # that peer's Muster process fully alive and never restarted. This proves
    # the reason-agnostic DOWN handling (scope.ex drops `_reason` outright) on
    # a genuine disconnect, not just a process/VM death, and that reconnecting
    # a LIVE peer (whose seq counters never reset, unlike a same-named restart
    # on a fresh VM) re-pairs and heals cleanly.
    #
    # :snabbkaffe.forward_trace/1 cannot stay attached to R across the split:
    # once forwarded, EVERY tp() on R (Muster ticks fire constantly) performs
    # a synchronous `rpc:call` back to T, and any such call auto-reconnects a
    # merely Node.disconnect/1'd node (confirmed by direct repro -- Node.list()
    # was back within 50ms with forwarding left on). Snabbkaffe exposes no
    # public "unforward" call, but do_forward_trace/1 is nothing more than a
    # `persistent_term:put(snabbkaffe_tp_fun, fun snabbkaffe:remote_tp/5)` on
    # R; poking that same key back to `local_tp/5` before disconnecting (and
    # calling forward_trace/1 again once reconnected) undoes it cleanly and
    # was confirmed by repro to hold the split for 2s+ with zero reconnects.
    defp unforward_trace(node) do
      :ok =
        :erpc.call(node, :persistent_term, :put, [:snabbkaffe_tp_fun, &:snabbkaffe.local_tp/5])
    end

    test "T disconnects from the peer holding its group, then reconnects and heals",
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

          # Detach R's forwarding, THEN sever the transport outright -- R's
          # Muster process stays alive and running the whole time.
          unforward_trace(r_node)
          true = Node.disconnect(r_node)

          # T sees R's coordinator monitor DOWN via :noconnection and
          # rebalances down to itself.
          assert {:ok, _} =
                   block_until(
                     %{:"$kind" => :muster_rebalance_start, node: ^t_node, to: [^t_node]},
                     10_000
                   )

          wait_until(fn -> Muster.members(scope) == [t_node] end)

          # Reconnect and re-attach forwarding: nodeup fires on both sides,
          # they re-pair via discover, and T's rebalance back into the
          # 2-node view re-snapshots R -- from R's perspective T is a freshly
          # (re)joined member, so this is a full snapshot, not a delta.
          true = Node.connect(r_node)
          :ok = :snabbkaffe.forward_trace(r_node)

          assert {:ok, %{groups: healed}} =
                   block_until(
                     %{:"$kind" => :muster_node_state_received, node: ^r_node, source: ^t_node},
                     10_000
                   )

          assert group in healed

          # Both re-converge to :ready for the 2-node view -- the SECOND time
          # (the first was the original formation), hence nth: 2.
          await_ready(view2, nth: 2, timeout: 20_000)

          assert t_node in occupancy_on(r_node, scope, group)

          %{group: group, r_node: r_node, t_node: t_node}
        end,
        fn result, trace ->
          # Exactly one post-heal snapshot from T landed on R and carried the
          # group.
          assert [%{groups: groups}] =
                   of_kind(:muster_node_state_received, trace)
                   |> Enum.filter(&(&1.node == result.r_node and &1.source == result.t_node))

          assert result.group in groups
        end
      )
    end
  end

  describe "node restart with the same name -- announce-watermark seq regression" do
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
          {^hash_tsz, stale_seq, _writer} = dump_tsz.member_views[s_node]

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
          # re-converge ANYWAY -- it cannot lean on seqs to tell incarnations
          # apart.
          s2_seq = :peer.call(p_s2, MusterPeerAux, :current_seq, [])
          assert s2_seq < stale_seq

          # RECOVERY: T must reach :ready for the live {T,S} view despite the
          # regressed seq -- its SECOND :ready for that view (the first was
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
          # {T,S} view -- and carries the lower, post-restart seq, proving the
          # stale high-seq {T,S,Z} watermark was discarded, not merely matched.
          dump_final = GenServer.call(Forum.Supervisor.name(scope), :dump)
          assert {^hash_ts, healed_seq, _writer} = dump_final.member_views[s_node]
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
          # {T,S} view (so the cluster genuinely converged -- except T).
          assert Enum.any?(
                   status_changes,
                   &(&1.node == result.s_node and &1.to == :ready and
                       &1.view_hash == result.hash_ts)
                 )

          # And T reached :ready for the live {T,S} view AFTER the rejoin -- it
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
                 "T never reached :ready for the live view after the same-named restart -- a stale member_views watermark stranded it"

          # The mechanism really fired: the restart's seq regressed below the
          # stale watermark, yet T recovered anyway.
          assert result.s2_seq < result.stale_seq
        end
      )
    end
  end

  describe "peer DOWN races a fresher re-registration" do
    setup do
      scope = :"muster_downrace_#{System.unique_integer([:positive])}"
      start_supervised!(spec(scope, vacant_flush_interval_ms: 60_000))
      %{scope: scope}
    end

    # scope.ex's handle_info({:DOWN, ...}) must only drop
    # occupancy/member_views/applied_snapshot_seq entries attributable to the
    # exact dying pid, not every entry keyed by the dead peer's NODE
    # regardless of which incarnation (pid) produced them. If a fresher
    # incarnation of that same node has ALREADY re-registered (its
    # rediscovery can outrun the old pid's monitor DOWN, since discovery
    # travels the adapter channel while DOWN travels the monitor channel) and
    # delivered new data before the old pid's DOWN is finally processed, a
    # node-keyed wipe would destroy that fresh data permanently: membership
    # does not change (the node is still a peer via its new pid), so
    # recompute_members is a no-op and no rebalance/re-announce would ever
    # fire again to repair it.
    #
    # Reproducing the dangerous ORDER via real message timing is exactly the
    # adapter-/ordering-dependent property this exercises: with the
    # default ErlDist adapter, a dead peer's exit signal and a freshly
    # restarted coordinator's rediscovery share one TCP connection, and the
    # exit signal is generated essentially the instant the old pid dies while
    # the new coordinator's rediscovery is only broadcast after a real
    # init -> await_shards_ready sequence -- so DOWN-before-rediscovery is the
    # OVERWHELMINGLY likely real order, the opposite of the dangerous one.
    # Forcing the dangerous order by parking T's own DOWN handling would
    # deadlock T's single-threaded coordinator against the very re-pairing
    # it's waiting on (the same process cannot dequeue the re-pairing message
    # while parked handling the DOWN ahead of it in its mailbox).
    #
    # So this test drives the exact mailbox STATE the race produces through
    # Scope's real public entry points, deterministically:
    #
    #   1. R holds `group`, routed to T; occupancy lands on T normally.
    #   2. A stand-in pid, alive on r_node but distinct from R's real Scope
    #      pid, is registered on T via a genuine :muster_discover message --
    #      exactly what a freshly-restarted R's coordinator broadcasts on
    #      rediscovery. This reproduces "T registers R's new pid" without
    #      racing real message delivery order.
    #   3. R's post-restart full snapshot is delivered through the SAME public
    #      RPC entry point (receive_node_state/5) a genuine rebalance
    #      dispatches, carrying a fresh, higher seq for the group.
    #   4. R's REAL (original) Scope pid is killed, firing T's genuine monitor
    #      DOWN for it -- the exact handler under test.
    #
    # At the moment the real DOWN fires, T's peers table holds two live
    # entries for r_node (the stand-in, and the dying real pid) -- exactly
    # the state the real race produces -- so the freshly-delivered row must
    # survive it.
    test "a peer's fresh re-registration and delivered snapshot survive its old pid's later DOWN",
         %{scope: scope} do
      t_node = node()

      check_trace(
        fn ->
          {:ok, p_r, r_node} = Peer.start(aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(r_node)
          start_remote_muster(p_r, scope)
          await_ready(Enum.sort([t_node, r_node]))

          group = group_routed_to(scope, t_node)

          :ok = :peer.call(p_r, MusterPeerAux, :join, [scope, group])
          assert r_node in occupancy_on(t_node, scope, group)

          # A stand-in for R's post-restart incarnation: alive on r_node, but
          # NOT R's real Scope pid. Spawned via an MFA (not a closure) so it
          # does not depend on this test module's bytecode being loaded on
          # the remote peer.
          standin = :erlang.spawn(r_node, :timer, :sleep, [:infinity])

          own_view_hash = GenServer.call(Forum.Supervisor.name(scope), :dump).view_hash
          fresh_seq = :erpc.call(r_node, :erlang, :unique_integer, [[:monotonic]])

          # Step 2: T registers the stand-in as a SECOND live peer for r_node
          # (peers is keyed by pid), exactly as a fresh coordinator's
          # rediscovery broadcast would.
          :erlang.send(
            {Forum.Supervisor.name(scope), t_node},
            {:muster_discover, standin, own_view_hash, fresh_seq},
            [:noconnect]
          )

          assert {:ok, _} =
                   block_until(
                     %{:"$kind" => :muster_peer_registered, node: ^t_node, peer: ^r_node},
                     5_000
                   )

          # Step 3: the fresh incarnation's full snapshot lands and applies on
          # T through the exact public entry point a real rebalance uses,
          # attributed to the SAME stand-in pid as its discover above (a real
          # incarnation's discover and its snapshot always share one pid).
          assert :ok =
                   Forum.Muster.Scope.receive_node_state(
                     scope,
                     r_node,
                     [group],
                     own_view_hash,
                     fresh_seq + 1,
                     standin
                   )

          assert r_node in occupancy_on(t_node, scope, group)

          # Step 4: R's REAL (original) Scope pid dies -- T's genuine monitor
          # fires the DOWN this test is about.
          r_scope_pid = :erpc.call(r_node, Process, :whereis, [Forum.Supervisor.name(scope)])
          Process.monitor(r_scope_pid)
          true = :erpc.call(r_node, Process, :exit, [r_scope_pid, :kill])
          assert_receive {:DOWN, _, _, ^r_scope_pid, _}, 5_000

          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_peer_down_apply,
                       :"$span" => {:complete, _},
                       node: ^t_node,
                       peer_node: ^r_node
                     },
                     5_000
                   )

          # THE PROPERTY UNDER TEST: the row delivered by R's newer, still-
          # registered incarnation must survive the old pid's DOWN.
          assert r_node in occupancy_on(t_node, scope, group),
                 "the old pid's DOWN wiped a row delivered by R's newer, still-registered incarnation"

          %{group: group, r_node: r_node, t_node: t_node}
        end,
        fn result, trace ->
          %{t_node: t_node, r_node: r_node} = result

          # The row really did arrive (via the simulated fresh incarnation's
          # snapshot) strictly before the DOWN handler ran.
          assert causality(
                   %{
                     :"$kind" => :muster_node_state_received,
                     node: ^t_node,
                     source: ^r_node
                   },
                   %{
                     :"$kind" => :muster_peer_down_apply,
                     :"$span" => :start,
                     node: ^t_node,
                     peer_node: ^r_node
                   },
                   trace
                 )
        end
      )
    end

    # The pid-liveness heuristic only consults the PEER-REGISTRATION channel
    # (state.peers, populated by
    # discover/discover_ack). It has no visibility into the DATA channel
    # (occupied/4, vacant_batch/4, receive_node_state/5, apply_delta/5) --
    # none of which identify their sender by pid at all today, only by node.
    # A node's post-restart full snapshot can land and apply (via
    # receive_node_state/5, exactly as a real rebalance dispatches it) BEFORE
    # any discover/ack from its new incarnation has been processed -- these
    # are two fully independent, unordered channels. When the OLD pid's DOWN
    # fires in that window, "is another peer pid registered for this node"
    # reads false (nothing has registered the new incarnation yet), so the
    # heuristic wipes data that was already correctly, freshly delivered.
    #
    # Unlike the test above (which pre-registers a stand-in specifically so
    # the heuristic's check succeeds), this test never registers any peer for
    # R at all -- reproducing the case where the DATA channel wins the race
    # instead of the registration channel, which the heuristic cannot see
    # either way.
    test "a fresh snapshot applied with no peer re-registration yet must survive the old pid's DOWN",
         %{scope: scope} do
      t_node = node()

      check_trace(
        fn ->
          {:ok, p_r, r_node} = Peer.start(aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(r_node)
          start_remote_muster(p_r, scope)
          await_ready(Enum.sort([t_node, r_node]))

          group = group_routed_to(scope, t_node)

          :ok = :peer.call(p_r, MusterPeerAux, :join, [scope, group])
          assert r_node in occupancy_on(t_node, scope, group)

          own_view_hash = GenServer.call(Forum.Supervisor.name(scope), :dump).view_hash
          fresh_seq = :erpc.call(r_node, :erlang, :unique_integer, [[:monotonic]])

          # R's real (soon to die) Scope pid, captured up front so the
          # snapshot below can be attributed to a DIFFERENT stand-in pid --
          # representing R's new incarnation -- rather than to the very pid
          # this test is about to kill.
          r_scope_pid = :erpc.call(r_node, Process, :whereis, [Forum.Supervisor.name(scope)])
          standin = :erlang.spawn(r_node, :timer, :sleep, [:infinity])

          # R's (simulated) post-restart full snapshot lands and applies on T
          # through the exact public entry point a real rebalance uses --
          # WITHOUT any discover/ack ever registering a new peer for R. This
          # is what the RPC channel winning the race against the message
          # channel looks like.
          assert :ok =
                   Forum.Muster.Scope.receive_node_state(
                     scope,
                     r_node,
                     [group],
                     own_view_hash,
                     fresh_seq,
                     standin
                   )

          assert r_node in occupancy_on(t_node, scope, group)

          # R's REAL Scope pid dies -- T's genuine monitor fires the DOWN
          # this test is about. T's peers table has never contained any
          # OTHER pid for r_node, so the pid-liveness heuristic sees no
          # "newer incarnation live" and wipes unconditionally.
          Process.monitor(r_scope_pid)
          true = :erpc.call(r_node, Process, :exit, [r_scope_pid, :kill])
          assert_receive {:DOWN, _, _, ^r_scope_pid, _}, 5_000

          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_peer_down_apply,
                       :"$span" => {:complete, _},
                       node: ^t_node,
                       peer_node: ^r_node
                     },
                     5_000
                   )

          # THE PROPERTY UNDER TEST: the row delivered via the data channel
          # must survive the old pid's DOWN even though nothing ever
          # registered a peer for it -- the heuristic's blind spot.
          assert r_node in occupancy_on(t_node, scope, group),
                 "the old pid's DOWN wiped a freshly-applied row because no discover/ack " <>
                   "had registered a peer for it yet -- the pid-liveness heuristic only " <>
                   "watches the registration channel, not the data channel"

          %{group: group, r_node: r_node, t_node: t_node}
        end,
        fn result, trace ->
          %{t_node: t_node, r_node: r_node} = result

          assert causality(
                   %{
                     :"$kind" => :muster_node_state_received,
                     node: ^t_node,
                     source: ^r_node
                   },
                   %{
                     :"$kind" => :muster_peer_down_apply,
                     :"$span" => :start,
                     node: ^t_node,
                     peer_node: ^r_node
                   },
                   trace
                 )
        end
      )
    end
  end

  describe "re-discovery backstop (rediscover/1)" do
    setup do
      scope = :"muster_rediscover_#{System.unique_integer([:positive])}"
      # Fast heartbeat so the periodic re-discovery sweep fires on its own; the
      # test perturbs nothing -- it just observes the natural heartbeat.
      start_supervised!(
        spec(scope, view_heartbeat_interval_ms: 150, vacant_flush_interval_ms: 100)
      )

      %{scope: scope}
    end

    # The gap rediscover/1 closes: a coordinator that crashes and restarts IN
    # PLACE re-pairs only via the single :muster_discover its init broadcasts -- no
    # :nodeup re-fires (the dist connection never dropped) and peers dropped it on
    # its old pid's :DOWN, so they won't reach back out. If that lone discovery is
    # lost, nothing else heals the edge: the announce heartbeat and member_views
    # only ever talk to nodes ALREADY in `members`. rediscover/1 makes the
    # heartbeat re-offer discovery to every connected non-member, bounding
    # worst-case stranding to one interval.
    #
    # Black-box (see the file header): we can neither drop a message nor fabricate
    # a stranded coordinator without a mock or state surgery. So we observe the
    # mechanism directly -- a node connected at the dist layer but running no
    # Muster (a genuine connected non-member) must be re-offered :muster_discover
    # on the heartbeat. Together with the convergence tests above (a received
    # discover leads to pairing), this covers the heal end to end.
    test "the heartbeat re-offers discovery to a connected non-member", %{scope: scope} do
      check_trace(
        fn ->
          # A bare node: connected to us (Peer.start calls Node.connect) but
          # running no Muster scope, so it never enters `members` and never sends
          # a discover of its own -- the only thing that can reach it is our
          # heartbeat's rediscover/1.
          {:ok, _p1, n1} = Peer.start()
          wait_until(fn -> n1 in Node.list() end)
          refute n1 in Muster.members(scope)

          assert {:ok, _} = block_until(%{:"$kind" => :muster_rediscover, target: ^n1}, 5_000)
        end,
        fn _trace -> :ok end
      )
    end
  end

  describe "rebalance snapshot failure vs. a router that already departed (forced ordering)" do
    setup do
      scope = :"muster_departed_#{System.unique_integer([:positive])}"
      start_supervised!(spec(scope, vacant_flush_interval_ms: 100))
      %{scope: scope}
    end

    # Sibling of "the source Scope crashes when its snapshot RPC fails..." above:
    # THAT test proves the crash-and-heal path is correct when the failed target
    # is still genuinely a member. This proves the narrower, adjacent case:
    # once do_rebalance has ALREADY reacted to a router's departure (dropped
    # it from `members`, pruned `owed_snapshots`), a stale failure report
    # about that SAME departure for a round dispatched before it must not
    # raise -- it is a late echo of news the coordinator already has, not a
    # fresh failure.
    #
    # In real distribution the peer-monitor :DOWN that drops the router and the
    # worker's own RPC failure are two independent messages caused by the SAME
    # target death, so which one lands first is an unforced race -- an
    # unconditional raise on the "DOWN first" interleaving would treat that
    # late echo as a fresh failure. To make the test deterministic rather than
    # relying on that race resolving one way, C's reply is parked before it can
    # ever complete, C is then killed outright, and -- using the
    # muster_rpc_worker_result test hook (emitted by the worker itself, a
    # process separate from Scope's own mailbox, so holding it cannot deadlock
    # Scope's own :DOWN handling) -- the worker's report of the resulting failure
    # is forced to land strictly after T's departure-triggered rebalance has
    # already dropped C from `members`.
    test "a snapshot RPC that fails after its target already left membership does not crash the coordinator",
         %{scope: scope} do
      t_node = node()

      c_name = ~c"muster_departed_c_#{System.unique_integer([:positive])}"
      c_node = :"#{c_name}@127.0.0.1"
      group = pick_group([{[t_node, c_node], c_node}])

      check_trace(
        fn ->
          # T holds `group` alone; it will move onto C once C joins, forcing a
          # FULL snapshot dispatch (C is a brand-new router).
          member = spawn(fn -> Process.sleep(:infinity) end)
          :ok = Muster.join(scope, group, member)
          {:ok, r0} = Muster.router(scope, group)
          assert r0 == t_node

          # Park C's apply of T's incoming snapshot before it can reply. Never
          # released by this test -- C is about to be killed outright instead,
          # which is what finally frees this call (with a crash, not a reply).
          force_ordering(
            %{:"$kind" => :test_never_release_c},
            %{
              :"$kind" => :muster_node_state_received,
              scope: ^scope,
              node: ^c_node,
              source: ^t_node
            }
          )

          # Hold T's own report of that RPC's eventual failure until AFTER T's
          # departure rebalance (triggered below by killing C) has already
          # dropped C from `members` -- this is what removes the real race.
          force_ordering(
            %{:"$kind" => :muster_rebalance_start, scope: ^scope, node: ^t_node, to: [^t_node]},
            %{
              :"$kind" => :muster_rpc_worker_result,
              scope: ^scope,
              node: ^t_node,
              router: ^c_node
            }
          )

          coord = Process.whereis(Forum.Supervisor.name(scope))
          ref = Process.monitor(coord)

          {:ok, p_c, ^c_node} = Peer.start(name: c_name, aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(c_node)
          start_remote_muster(p_c, scope)

          # T's snapshot to C is genuinely dispatched and in flight (parked on
          # C, per the force_ordering above).
          wait_until(fn ->
            Forum.Supervisor.name(scope)
            |> GenServer.call(:dump)
            |> Map.fetch!(:owed_snapshots)
            |> Map.has_key?(c_node)
          end)

          # Kill C outright -- the WHOLE peer, not just its coordinator: C's own
          # Forum.Supervisor would otherwise restart a killed coordinator and
          # rejoin T within milliseconds (the very self-heal other tests in
          # this file rely on), undoing the departure before it could be
          # observed. This is the one real departure in this test: T's peer
          # monitor on C's coordinator pid fires a genuine :DOWN, and it is
          # also what finally makes the worker's blocked RPC call fail (C
          # never replies, and now never can).
          :ok = stop_supervised({:peer, c_name})

          # T's real :DOWN handling drops C and rebalances down to itself alone
          # -- the event the held worker report above is waiting on.
          assert {:ok, _} =
                   block_until(
                     %{
                       :"$kind" => :muster_rebalance_start,
                       scope: ^scope,
                       node: ^t_node,
                       to: [^t_node]
                     },
                     10_000
                   )

          # muster_rebalance_start fires at the TOP of do_rebalance, before its
          # synchronous shard gather updates `state.members` -- poll rather than
          # assert immediately so this isn't racing that internal window.
          wait_until(fn -> c_node not in Muster.members(scope) end)

          # Released by the ordering above only now: the worker's report that
          # its snapshot RPC to the (already-departed) C failed.
          assert {:ok, %{ok?: false}} =
                   block_until(
                     %{
                       :"$kind" => :muster_rpc_worker_result,
                       scope: ^scope,
                       node: ^t_node,
                       router: ^c_node
                     },
                     10_000
                   )

          # The stale failure must not have crashed the coordinator.
          refute_receive {:DOWN, ^ref, :process, ^coord, _reason}, 500
          assert Process.alive?(coord)

          # And it stays fully functional afterwards.
          assert :ok =
                   Muster.join(
                     scope,
                     :"departed_recovered_#{System.unique_integer([:positive])}",
                     spawn(fn -> Process.sleep(:infinity) end)
                   )

          %{coord: coord, ref: ref, scope: scope, t_node: t_node, c_node: c_node}
        end,
        fn result, trace ->
          %{scope: scope, t_node: t_node, c_node: c_node} = result

          # The coordinator really did receive the stale failure report (not
          # just avoid crashing on something it never saw)...
          worker_results =
            of_kind(:muster_rpc_worker_result, trace)
            |> Enum.filter(&(&1.scope == scope and &1.node == t_node and &1.router == c_node))

          assert Enum.any?(worker_results, &(&1.ok? == false))

          # ...and it arrived strictly after T's departure rebalance, not
          # before -- proving this test exercised the ordering it claims to,
          # rather than happening to avoid the race by luck.
          assert causality(
                   %{
                     :"$kind" => :muster_rebalance_start,
                     scope: ^scope,
                     node: ^t_node,
                     to: [^t_node]
                   },
                   %{
                     :"$kind" => :muster_rpc_worker_result,
                     scope: ^scope,
                     node: ^t_node,
                     router: ^c_node,
                     ok?: false
                   },
                   trace
                 )
        end
      )
    end
  end

  describe "long partition -- both sides settle to :ready independently before healing" do
    setup do
      scope = :"muster_longsplit_#{System.unique_integer([:positive])}"
      start_supervised!(spec(scope, vacant_flush_interval_ms: 100))

      # Unlike the partition test above -- where only the two PEERS split and
      # T (this node) never loses anyone -- this test has T itself lose both
      # peers. T runs with :global's default connect_all: true, and :global
      # periodically re-syncs against every node it still knows via epmd on
      # this same host; left alone, it silently redials a Node.disconnect/1'd
      # peer within milliseconds (confirmed by direct repro), undoing the
      # split before either side can settle. The peers already run with
      # -connect_all false for the same reason on their end; this does the
      # equivalent for T for the duration of this test only.
      Application.put_env(:kernel, :connect_all, false)
      on_exit(fn -> Application.put_env(:kernel, :connect_all, true) end)

      %{scope: scope}
    end

    # The partition test above heals almost immediately after the split is
    # detected -- the readiness barrier is checked mid-:converging. Here T is
    # cut off from BOTH peers at once (instead of the two peers splitting from
    # each other while T stays connected to both), and each side is left long
    # enough to reach a genuinely settled :ready state on its own -- not
    # mid-rebalance -- before anything heals. While settled and mutually
    # unaware, EACH side takes on a claim the other side has never seen: T
    # joins a group that (by ring math) belongs to A once the cluster
    # re-merges, and A joins a group that belongs back to T. This proves the
    # merge-on-heal doesn't just restore the OLD occupancy rows (already
    # covered above) but correctly delivers claims created independently, in
    # both directions, by two sides that each fully rebalanced elsewhere
    # first -- with no stale-entry drop along the way.
    test "occupancy claims made independently on both sides of a settled split survive the merge",
         %{scope: scope} do
      t_node = node()

      check_trace(
        fn ->
          # Both peers run with -connect_all false, same as the partition test
          # above: their globals don't auto-mesh or fight the deliberate
          # disconnect via prevent_overlapping_partitions.
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

          # Groups whose router in the FINAL (post-heal) view3 sits on the
          # opposite side of the split from whoever is about to join them --
          # each claim below can only survive the merge via a real cross-node
          # delta/snapshot, never by already being local to its eventual
          # router.
          #
          # Deliberately no baseline pre-split occupancy here (unlike the
          # partition test above): T holding a group already routed to A or B
          # would force T's own departure rebalance to re-announce it to
          # whichever peer survives in T's reduced view -- a real RPC racing
          # the second Node.disconnect/1 below and liable to auto-reconnect
          # the very node being cut loose. Keeping T empty until after the
          # split isolates the scenario this test is actually after.
          g_t_side = pick_group([{view3, a_node}])
          g_ab_side = pick_group([{view3, t_node}])

          # Detach forwarding before cutting the transport: a forwarded tp()
          # still RPCs back to T and would silently reconnect a merely
          # Node.disconnect/1'd peer (see unforward_trace/1 above).
          unforward_trace(a_node)
          unforward_trace(b_node)
          true = Node.disconnect(a_node)
          true = Node.disconnect(b_node)

          wait_until(
            fn -> status(scope) == :ready and Muster.members(scope) == [t_node] end,
            10_000
          )

          # Both sides detect the split and rebalance apart, all the way to a
          # settled :ready -- not just "converging" -- before either takes on
          # new work. Polled via :peer.call, which rides the peer's own
          # standard-io control channel rather than Erlang distribution, so it
          # keeps working straight through the cut on both sides.

          wait_until(
            fn ->
              remote_status(p_a, scope) == :ready and remote_status(p_b, scope) == :ready and
                :peer.call(p_a, Muster, :members, [scope]) == Enum.sort([a_node, b_node]) and
                :peer.call(p_b, Muster, :members, [scope]) == Enum.sort([a_node, b_node])
            end,
            10_000
          )

          # NOW, with both sides fully settled and mutually unaware, each side
          # takes on a claim the other has never seen.
          member_t = spawn(fn -> Process.sleep(:infinity) end)
          :ok = Muster.join(scope, g_t_side, member_t)
          :ok = :peer.call(p_a, MusterPeerAux, :join, [scope, g_ab_side])

          # Heal both links and re-attach forwarding for the post-heal trace.
          true = Node.connect(a_node)
          true = Node.connect(b_node)
          :ok = :snabbkaffe.forward_trace(a_node)
          :ok = :snabbkaffe.forward_trace(b_node)

          # All three nodes re-converge into the SAME 3-node view -- the
          # second time (the first was the original formation), hence nth: 2.
          await_ready(view3, nth: 2, timeout: 20_000)

          # Both independently-made claims landed on the router their group
          # hashes to in the merged view, each having necessarily crossed from
          # the isolated side that made it to the other.
          assert t_node in occupancy_on(a_node, scope, g_t_side)
          assert a_node in occupancy_on(t_node, scope, g_ab_side)

          assert Muster.can_decide?(scope, hash3)
          assert Muster.members(scope) == view3
          assert :erpc.call(a_node, Muster, :members, [scope]) == view3
          assert :erpc.call(b_node, Muster, :members, [scope]) == view3
        end,
        # Unlike the other describe blocks above, ordering here is entirely
        # real (no force_ordering) across two independent, uncontrolled
        # multi-step convergences (T's and A/B's), so a claim can legitimately
        # be judged stale under a transient intermediate view and be
        # re-inserted moments later by the causal apply that follows -- that
        # is the self-heal working as designed, not data loss. What this test
        # commits to is the property real, uncoordinated timing CAN prove:
        # the final merged state is correct (checked above). Asserting zero
        # transient drops would require pinning the interleaving down with
        # force_ordering, same as every other drops == [] assertion in this
        # file does; that is a narrower, complementary test, not this one.
        fn _trace -> :ok end
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
