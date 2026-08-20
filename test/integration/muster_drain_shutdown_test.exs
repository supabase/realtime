defmodule Realtime.Integration.MusterDrainShutdownTest do
  # End-to-end smoke test of the Realtime-level graceful-shutdown wiring: bring up
  # a second full Realtime node and prove that tearing down its
  # `Realtime.MusterDrainer` child -- exactly what the Realtime supervision tree
  # does to that child on shutdown (SIGTERM -> init:stop -> reverse-order child
  # termination) -- runs `Forum.Muster.drain/2`, gracefully evacuating the peer's
  # Muster router role.
  #
  # We drive the drainer child directly with `Supervisor.terminate_child/2` rather
  # than stopping the whole peer app: it exercises the identical `terminate/2`
  # code path, but leaves the peer node (and its Muster coordinator) alive, which
  # is what makes the graceful leave observable. `drain/2`'s own cross-node
  # correctness (re-election, re-announce, ack/settle) is covered exhaustively in
  # forum/test/forum/muster_distributed_test.exs; here we only guard that Realtime
  # invokes it on shutdown.
  #
  # The distinguishing, snabbkaffe-free signal: after the drain the survivor drops
  # the peer from its Muster ring **while the peer node is still alive and
  # connected**. An abrupt node death is handled via `:DOWN` and could only evict
  # a *disconnected* node, so a still-connected eviction can only be the graceful
  # `:muster_leaving` broadcast drain/2 sends. (forum's tracepoints compile to
  # no-ops outside its own `:test` build, so they can't be asserted on from here.)
  use ExUnit.Case, async: false

  alias Forum.Muster

  @moduletag timeout: 60_000

  test "tearing down the peer's MusterDrainer gracefully evacuates its router role" do
    scope = Application.fetch_env!(:realtime, :muster_scope)
    local = node()

    # settle_ms kept small so drain/2's post-ack window (and thus terminate/2)
    # returns quickly; correctness doesn't depend on its length here.
    {:ok, peer} =
      Clustered.start(nil,
        name: :"muster_drain_smoke_#{System.unique_integer([:positive])}",
        extra_config: [{:realtime, :muster_drain_opts, [settle_ms: 100, timeout_ms: 5_000]}]
      )

    # Both nodes agree on the scope and converge to a 2-node :ready ring.
    assert :erpc.call(peer, Application, :fetch_env!, [:realtime, :muster_scope]) == scope
    await(fn -> Enum.sort(Muster.members(scope)) == Enum.sort([local, peer]) and Muster.status(scope) == :ready end)

    # Terminate the drainer child on the peer: this runs Realtime.MusterDrainer's
    # terminate/2 -> Forum.Muster.drain/2 while the peer's coordinator is alive.
    assert :ok = :erpc.call(peer, Supervisor, :terminate_child, [Realtime.Supervisor, Realtime.MusterDrainer], 30_000)

    # drain/2 stopped the peer from accepting new joins.
    assert :erpc.call(peer, :persistent_term, :get, [{Forum.Muster, scope, :accepting_joins}, true]) == false

    # The survivor rebalanced the peer out of its ring...
    await(fn -> Enum.sort(Muster.members(scope)) == [local] end)

    # ...and it did so while the peer node was still alive and connected -- proof
    # this was the graceful leave, not an abrupt-death :DOWN.
    assert peer in Node.list()
    assert :erpc.call(peer, Process, :whereis, [Forum.Supervisor.name(scope)]) |> is_pid()
  end

  defp await(fun, attempts \\ 100)
  defp await(_fun, 0), do: flunk("condition never became true within timeout")

  defp await(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(100)
      await(fun, attempts - 1)
    end
  end
end
