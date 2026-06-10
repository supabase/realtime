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

      # Form {A, P1}.
      {:ok, p1, n1} = Peer.start(aux_mod: @aux_mod)
      start_remote_muster(p1, scope)

      wait_until(fn -> n1 in Muster.members(scope) end)
      wait_until(fn -> status(scope) == :ready end)
      wait_until(fn -> remote_status(p1, scope) == :ready end)

      # P1 holds `group`; under {A, P1} its router is r1, which must hold {group, n1}.
      :ok = :peer.call(p1, MusterPeerAux, :join, [scope, group])
      {:ok, r1} = Muster.router(scope, group)
      wait_until(fn -> n1 in occupancy_on(r1, scope, group) end)

      # Add P2 -> {A, P1, P2}. `group`'s router may move; the rebalance must
      # re-announce {group, n1} to the new router, and every node must converge
      # all the way to :ready.
      {:ok, p2, n2} = Peer.start(aux_mod: @aux_mod)
      start_remote_muster(p2, scope)

      wait_until(fn -> n2 in Muster.members(scope) end)
      wait_until(fn -> status(scope) == :ready end)
      wait_until(fn -> remote_status(p1, scope) == :ready end)
      wait_until(fn -> remote_status(p2, scope) == :ready end)

      # Whoever the current router is, it holds {group, n1} — this is the core
      # invariant the barrier protects: by the time the cluster is :ready, the
      # new router's occupancy is complete.
      {:ok, r2} = Muster.router(scope, group)
      wait_until(fn -> n1 in occupancy_on(r2, scope, group) end)
      assert n1 in occupancy_on(r2, scope, group)
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
          wait_until(fn -> n1 in Muster.members(scope) end)

          # Add P2 -> {A, P1, P2}: every node rebalances and must re-converge.
          {:ok, p2, n2} = Peer.start(aux_mod: @aux_mod)
          :ok = :snabbkaffe.forward_trace(n2)
          start_remote_muster(p2, scope)

          members = Enum.sort([node(), n1, n2])
          view_hash = :erlang.phash2(members)

          # Wait for each node to announce :ready for the final 3-node view. The
          # view_hash match is what makes this "ready *again*": an earlier 2-node
          # :ready (from {A, P1}) carries a different hash and is ignored.
          for n <- members do
            assert {:ok, _} =
                     block_until(
                       %{
                         :"$kind" => :muster_status_change,
                         to: :ready,
                         node: ^n,
                         view_hash: ^view_hash
                       },
                       5_000
                     )
          end

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
end
