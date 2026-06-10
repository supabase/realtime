defmodule Forum.MusterTest do
  # Cannot be async: Mimic runs in global mode here (the RPC workers Muster
  # spawns are arbitrary processes, so stubs must apply cluster-wide), and the
  # injection of fake remote members manipulates global ring/state.
  use ExUnit.Case, async: false
  use Mimic

  alias Forum.Muster
  alias Forum.Muster.Scope
  alias Forum.Adapter.ErlDist

  @fake_node :fake@nowhere

  setup :set_mimic_global

  setup ctx do
    scope = :"muster_test_#{System.unique_integer([:positive])}"

    # Default transport stubs. `call/6` (the RPC primitive) returns :ok; tests
    # re-stub it to inject failures or holds. `send/3` is a no-op — its targets
    # are always fake remote nodes — but it is stubbed so its invocations are
    # recorded and inspectable via `Mimic.calls/3`. `register/1` and
    # `broadcast/*` are left un-stubbed: they pass through to the real
    # ErlDist (register actually names the Scope process; broadcast is a no-op
    # with no connected nodes).
    stub_call(:ok)
    stub(ErlDist, :send, fn _scope, _node, _message -> :ok end)

    base_opts = [
      partitions: 2,
      vacancy_cooldown_ms: Map.get(ctx, :cooldown_ms, 50),
      # Long by default so the periodic flush never fires mid-test; tests that
      # exercise the flush drive it deterministically via trigger_flush/1.
      vacant_flush_interval_ms: Map.get(ctx, :flush_ms, 60_000),
      # Same: long so the view heartbeat never fires mid-test; the heartbeat
      # test drives it deterministically via trigger_view_heartbeat/1.
      view_heartbeat_interval_ms: Map.get(ctx, :heartbeat_ms, 60_000),
      rpc_timeout_ms: Map.get(ctx, :rpc_timeout, 500),
      message_module: ErlDist
    ]

    %{scope: scope, base_opts: base_opts}
  end

  # Stub the RPC transport `ErlDist.call/6`. `response` mirrors the old
  # RecordingAdapter contract:
  #   * `:ok` / `{:error, term}` — returned directly.
  #   * `{:fn, fun}` — `fun` is invoked synchronously in the calling (worker)
  #     process, letting tests inject sleeps or arbitrary logic.
  defp stub_call({:fn, fun}) do
    stub(ErlDist, :call, fn _scope, _node, _module, _function, _args, _timeout -> fun.() end)
  end

  defp stub_call(response) do
    stub(ErlDist, :call, fn _scope, _node, _module, _function, _args, _timeout -> response end)
  end

  defp spec(scope, opts) do
    %{
      id: scope,
      start: {Muster, :start_link, [scope, opts]},
      type: :supervisor
    }
  end

  defp ring_name(scope), do: :"#{scope}_muster_ring"

  defp inject_fake_remote(scope, fake_node \\ @fake_node) do
    members = Enum.sort([node(), fake_node])
    {:ok, _} = ExHashRing.Ring.set_nodes(ring_name(scope), members)

    :sys.replace_state(Forum.Supervisor.name(scope), fn s ->
      %{s | members: members}
    end)
  end

  defp set_rebalancing(scope, flag) do
    status = if flag, do: :rebalancing, else: :ready
    :persistent_term.put({Forum.Muster, scope, :status}, status)
  end

  # Finds a group whose current router lookup routes to `target_node`.
  defp group_for_router(scope, target_node) do
    Stream.iterate(0, &(&1 + 1))
    |> Stream.map(&:"g#{&1}")
    |> Enum.find(fn group ->
      case Muster.router(scope, group) do
        {:ok, ^target_node} -> true
        _ -> false
      end
    end)
  end

  # Drain and return the ErlDist.call/6 invocations recorded since the last
  # drain, each as the 6-element argument list
  # `[scope, node, module, function, args, timeout]`. `Mimic.calls/3` is
  # consuming, so this behaves like the old `drain_adapter_events`.
  defp drain_calls, do: Mimic.calls(ErlDist, :call, 6)

  # Drain and return the ErlDist.send/3 invocations recorded since the last
  # drain, each as `[scope, node, message]`.
  defp drain_sends, do: Mimic.calls(ErlDist, :send, 3)

  # Poll the drained call log (accumulating across the consuming drains) until a
  # recorded ErlDist.call/6 whose argument list satisfies `pred` appears. Used
  # for RPCs dispatched asynchronously (via the Scope mailbox / spawned worker).
  defp wait_call(pred, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_call(pred, deadline, [])
  end

  defp do_wait_call(pred, deadline, acc) do
    acc = acc ++ drain_calls()

    case Enum.find(acc, pred) do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(5)
          do_wait_call(pred, deadline, acc)
        end

      call ->
        {:ok, call}
    end
  end

  defp assert_call(pred, timeout \\ 1_000) do
    case wait_call(pred, timeout) do
      {:ok, call} -> call
      :timeout -> flunk("no ErlDist.call/6 matching the predicate within #{timeout}ms")
    end
  end

  defp trigger_flush(scope) do
    Kernel.send(Forum.Supervisor.name(scope), :flush_vacant)
  end

  defp trigger_view_heartbeat(scope) do
    Kernel.send(Forum.Supervisor.name(scope), :view_heartbeat)
  end

  defp group_states(scope) do
    GenServer.call(Forum.Supervisor.name(scope), :status).group_states
  end

  # Poll the Scope's group_states until `group` reaches `expected`. `expected`
  # may be a value or a predicate fun.
  defp wait_for_group_state(scope, group, expected, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_group_state(scope, group, expected, deadline)
  end

  defp do_wait_for_group_state(scope, group, expected, deadline) do
    actual = Map.get(group_states(scope), group)

    cond do
      match_state?(expected, actual) ->
        actual

      System.monotonic_time(:millisecond) >= deadline ->
        flunk(
          "group #{inspect(group)} state #{inspect(actual)} did not match #{inspect(expected)} in time"
        )

      true ->
        Process.sleep(5)
        do_wait_for_group_state(scope, group, expected, deadline)
    end
  end

  defp match_state?(pred, actual) when is_function(pred, 1), do: pred.(actual)
  defp match_state?(expected, actual), do: expected == actual

  # True if any recorded call announced `group` to its new router via
  # Scope.receive_node_state.
  defp announced?(calls, group) do
    Enum.any?(calls, fn
      [_scope, _target, Scope, :receive_node_state, [_s, _src, groups | _], _timeout] ->
        group in groups

      _ ->
        false
    end)
  end

  # Find `count` distinct groups whose current router is `target_node`.
  defp groups_for_router(scope, target_node, count) do
    Stream.iterate(0, &(&1 + 1))
    |> Stream.map(&:"g#{&1}")
    |> Stream.filter(fn group ->
      match?({:ok, ^target_node}, Muster.router(scope, group))
    end)
    |> Enum.take(count)
  end

  describe "start_link/2" do
    test "starts with custom partition count", %{scope: scope, base_opts: opts} do
      pid = start_supervised!(spec(scope, opts))
      assert Process.alive?(pid)
      assert length(Forum.Supervisor.partitions(scope)) == 2
    end

    test "raises on invalid partition count", %{scope: scope} do
      assert_raise ArgumentError, ~r/expected :partitions to be a positive integer/, fn ->
        Muster.start_link(scope, partitions: 0)
      end
    end

    test "raises on invalid vacancy_cooldown_ms", %{scope: scope} do
      assert_raise ArgumentError, ~r/expected :vacancy_cooldown_ms/, fn ->
        Muster.start_link(scope, vacancy_cooldown_ms: -1)
      end
    end

    test "raises on invalid vacant_flush_interval_ms", %{scope: scope} do
      assert_raise ArgumentError, ~r/expected :vacant_flush_interval_ms/, fn ->
        Muster.start_link(scope, vacant_flush_interval_ms: 0)
      end
    end

    test "raises on invalid view_heartbeat_interval_ms", %{scope: scope} do
      assert_raise ArgumentError, ~r/expected :view_heartbeat_interval_ms/, fn ->
        Muster.start_link(scope, view_heartbeat_interval_ms: 0)
      end
    end

    test "exposes router lookup", %{scope: scope, base_opts: opts} do
      start_supervised!(spec(scope, opts))
      assert {:ok, n} = Muster.router(scope, :anything)
      assert n == node()
    end
  end

  describe "router/2 and members/1" do
    setup %{scope: scope, base_opts: opts} do
      start_supervised!(spec(scope, opts))
      :ok
    end

    test "returns {:ok, node()} on a single-node cluster", %{scope: scope} do
      assert {:ok, n} = Muster.router(scope, :any_group)
      assert n == node()
    end

    test "members/1 returns the sorted cluster member list", %{scope: scope} do
      assert Muster.members(scope) == [node()]
    end

    test "returns {:rebalancing, members} when the flag is set", %{scope: scope} do
      members = Enum.sort([node(), @fake_node])
      {:ok, _} = ExHashRing.Ring.set_nodes(ring_name(scope), members)
      set_rebalancing(scope, true)

      assert {:rebalancing, ^members} = Muster.router(scope, :any_group)
      assert Muster.members(scope) == members

      set_rebalancing(scope, false)
      assert {:ok, _node} = Muster.router(scope, :any_group)
    end
  end

  describe "remote entry points write directly to occupancy_table (no Scope mailbox)" do
    setup %{scope: scope, base_opts: opts} do
      start_supervised!(spec(scope, opts))
      :ok
    end

    test "occupied/4 inserts a {group, source_node} row", %{scope: scope} do
      assert :ok = Scope.occupied(scope, :rg1, :src@nowhere, 1)
      assert :src@nowhere in Scope.occupancy(scope, :rg1)
    end

    test "vacant_batch/4 deletes multiple {group, source_node} rows", %{scope: scope} do
      :ok = Scope.occupied(scope, :rg2a, :src@nowhere, 1)
      :ok = Scope.occupied(scope, :rg2b, :src@nowhere, 1)
      assert :src@nowhere in Scope.occupancy(scope, :rg2a)
      assert :src@nowhere in Scope.occupancy(scope, :rg2b)

      assert :ok = Scope.vacant_batch(scope, [:rg2a, :rg2b], :src@nowhere, 2)
      refute :src@nowhere in Scope.occupancy(scope, :rg2a)
      refute :src@nowhere in Scope.occupancy(scope, :rg2b)
    end

    test "vacant_batch/4 only deletes rows for the given source", %{scope: scope} do
      :ok = Scope.occupied(scope, :rg3, :src_a@nowhere, 1)
      :ok = Scope.occupied(scope, :rg3, :src_b@nowhere, 1)

      assert :ok = Scope.vacant_batch(scope, [:rg3], :src_a@nowhere, 2)
      assert Scope.occupancy(scope, :rg3) == [:src_b@nowhere]
    end

    test "vacant_batch/4 with a stale (lower) seq does NOT delete a newer occupied",
         %{scope: scope} do
      # The core of the timeout race: a re-claim wrote a fresh, higher-seq
      # occupied; a stale vacant DELETE (lower seq) arrives late and must be
      # ignored so it cannot clobber the live entry.
      :ok = Scope.occupied(scope, :race_g, :src@nowhere, 10)
      assert :ok = Scope.vacant_batch(scope, [:race_g], :src@nowhere, 5)
      assert :src@nowhere in Scope.occupancy(scope, :race_g)

      # A vacant at or above the stored seq still deletes (the real vacancy).
      assert :ok = Scope.vacant_batch(scope, [:race_g], :src@nowhere, 10)
      refute :src@nowhere in Scope.occupancy(scope, :race_g)
    end

    test "receive_node_state/5 replaces all rows for a source", %{scope: scope} do
      # Seed something the snapshot should clear.
      :ok = Scope.occupied(scope, :stale_g, :src@nowhere, 1)

      assert :ok = Scope.receive_node_state(scope, :src@nowhere, [:fresh_a, :fresh_b], 0, 2)

      refute :src@nowhere in Scope.occupancy(scope, :stale_g)
      assert :src@nowhere in Scope.occupancy(scope, :fresh_a)
      assert :src@nowhere in Scope.occupancy(scope, :fresh_b)
    end

    test "writes from different sources don't interfere", %{scope: scope} do
      :ok = Scope.occupied(scope, :shared, :src_a@nowhere, 1)
      :ok = Scope.occupied(scope, :shared, :src_b@nowhere, 1)

      assert Enum.sort(Scope.occupancy(scope, :shared)) ==
               [:src_a@nowhere, :src_b@nowhere]

      :ok = Scope.vacant_batch(scope, [:shared], :src_a@nowhere, 2)
      assert Scope.occupancy(scope, :shared) == [:src_b@nowhere]
    end

    test "Scope mailbox is unaffected by remote-entry writes", %{scope: scope} do
      # If the writes still went through the mailbox, a held :status call
      # would queue behind them. Issue many writes concurrently, then assert
      # :status responds promptly.
      tasks =
        for i <- 1..200 do
          Task.async(fn -> Scope.occupied(scope, :"hot_#{i}", :src@nowhere, 1) end)
        end

      Task.await_many(tasks, 5_000)

      t0 = System.monotonic_time(:millisecond)
      reply = GenServer.call(Forum.Supervisor.name(scope), :status, 500)
      t1 = System.monotonic_time(:millisecond)

      assert is_map(reply)
      # Mailbox processing should be near-instant since writes never queued.
      assert t1 - t0 < 100
    end
  end

  describe "single-node join/leave (router == self)" do
    setup %{scope: scope, base_opts: opts} do
      start_supervised!(spec(scope, opts))
      :ok
    end

    test "join registers locally and updates occupancy table", %{scope: scope} do
      pid = spawn_link(fn -> Process.sleep(:infinity) end)
      assert :ok = Muster.join(scope, :g1, pid)
      assert Muster.local_member?(scope, :g1, pid)
      assert Muster.local_member_count(scope, :g1) == 1
      assert node() in Scope.occupancy(scope, :g1)
    end

    test "join does not fire RPC when router is self", %{scope: scope} do
      pid = spawn_link(fn -> Process.sleep(:infinity) end)
      _ = drain_calls()
      assert :ok = Muster.join(scope, :g1, pid)

      assert drain_calls() == []
    end

    test "subsequent joins skip Scope entirely", %{scope: scope} do
      pid1 = spawn_link(fn -> Process.sleep(:infinity) end)
      pid2 = spawn_link(fn -> Process.sleep(:infinity) end)
      assert :ok = Muster.join(scope, :g1, pid1)
      assert :ok = Muster.join(scope, :g1, pid2)
      assert Muster.local_member_count(scope, :g1) == 2
    end

    test "leave + cooldown then re-join is silent", %{scope: scope} do
      pid = spawn_link(fn -> Process.sleep(:infinity) end)
      assert :ok = Muster.join(scope, :g1, pid)
      assert :ok = Muster.leave(scope, :g1, pid)
      # Wait past cooldown
      Process.sleep(120)
      assert :ok = Muster.join(scope, :g1, pid)
      assert Muster.local_member_count(scope, :g1) == 1
    end

    test "rejects non-local pids", %{scope: scope} do
      # Construct a pid that nominally belongs to a different node.
      # We can't easily forge a pid; instead we just confirm the guard:
      # spawn a process and ensure the join allows it.
      pid = spawn_link(fn -> Process.sleep(:infinity) end)
      assert :ok = Muster.join(scope, :g1, pid)
    end
  end

  describe "router == remote (fake node injection)" do
    setup %{scope: scope, base_opts: opts} do
      start_supervised!(spec(scope, opts))
      inject_fake_remote(scope)

      %{
        remote_group: group_for_router(scope, @fake_node),
        self_group: group_for_router(scope, node())
      }
    end

    test "first join dispatches a single occupied RPC and waits for reply",
         %{scope: scope, remote_group: g} do
      _ = drain_calls()

      pid = spawn_link(fn -> Process.sleep(:infinity) end)
      assert :ok = Muster.join(scope, g, pid)

      assert [[^scope, @fake_node, Scope, :occupied, [^scope, ^g, _, _], _]] = drain_calls()

      assert Muster.local_member_count(scope, g) == 1
    end

    test "second join (count > 0) skips the RPC", %{scope: scope, remote_group: g} do
      pid1 = spawn_link(fn -> Process.sleep(:infinity) end)
      pid2 = spawn_link(fn -> Process.sleep(:infinity) end)

      assert :ok = Muster.join(scope, g, pid1)
      _ = drain_calls()

      assert :ok = Muster.join(scope, g, pid2)

      assert drain_calls() == []
    end

    @tag rpc_timeout: 5_000
    test "concurrent joins dedup to a single RPC", %{scope: scope, remote_group: g} do
      _ = drain_calls()
      test_pid = self()
      hold_ms = 200

      stub_call(
        {:fn,
         fn ->
           Kernel.send(test_pid, :rpc_started)
           Process.sleep(hold_ms)
           :ok
         end}
      )

      callers =
        for _ <- 1..50 do
          Task.async(fn ->
            pid = spawn_link(fn -> Process.sleep(:infinity) end)
            Muster.join(scope, g, pid)
          end)
        end

      assert_receive :rpc_started, 1_000

      results = Enum.map(callers, &Task.await(&1, 5_000))
      assert Enum.all?(results, &(&1 == :ok))

      call_count =
        Enum.count(
          drain_calls(),
          &match?([^scope, _, Scope, :occupied, [^scope, ^g, _, _], _], &1)
        )

      assert call_count == 1
    end

    test "RPC failure returns :rpc_failed and does not insert into partition",
         %{scope: scope, remote_group: g} do
      stub_call({:error, :noconnection})

      pid = spawn_link(fn -> Process.sleep(:infinity) end)
      assert {:error, :rpc_failed} = Muster.join(scope, g, pid)
      assert Muster.local_member_count(scope, g) == 0
      refute Muster.local_member?(scope, g, pid)
    end

    test "next join retries the RPC after a previous failure",
         %{scope: scope, remote_group: g} do
      stub_call({:error, :noconnection})
      pid = spawn_link(fn -> Process.sleep(:infinity) end)
      assert {:error, :rpc_failed} = Muster.join(scope, g, pid)

      _ = drain_calls()

      stub_call(:ok)
      assert :ok = Muster.join(scope, g, pid)

      assert [[^scope, @fake_node, Scope, :occupied, [^scope, ^g, _, _], _]] = drain_calls()

      assert Muster.local_member_count(scope, g) == 1
    end

    @tag rpc_timeout: 5_000
    test "Scope mailbox is not blocked by a slow RPC",
         %{scope: scope, remote_group: g} do
      test_pid = self()

      stub_call(
        {:fn,
         fn ->
           Kernel.send(test_pid, :rpc_started)
           Process.sleep(500)
           :ok
         end}
      )

      pid = spawn_link(fn -> Process.sleep(:infinity) end)

      slow_join =
        Task.async(fn -> Muster.join(scope, g, pid) end)

      assert_receive :rpc_started, 1_000

      # While the slow RPC is in flight, ask Scope for status — should reply quickly.
      scope_name = Forum.Supervisor.name(scope)

      t0 = System.monotonic_time(:millisecond)
      reply = GenServer.call(scope_name, :status, 500)
      t1 = System.monotonic_time(:millisecond)

      assert is_map(reply)
      assert t1 - t0 < 200

      assert :ok = Task.await(slow_join, 5_000)
    end
  end

  describe "vacancy cooldown" do
    @describetag cooldown_ms: 100

    setup %{scope: scope, base_opts: opts} do
      start_supervised!(spec(scope, opts))
      inject_fake_remote(scope)

      %{remote_group: group_for_router(scope, @fake_node)}
    end

    test "leave + re-join within cooldown does not fire RPC",
         %{scope: scope, remote_group: g} do
      pid = spawn_link(fn -> Process.sleep(:infinity) end)

      assert :ok = Muster.join(scope, g, pid)
      _ = drain_calls()

      assert :ok = Muster.leave(scope, g, pid)
      # Wait briefly to let telemetry → scope cast settle, then re-join.
      Process.sleep(20)
      assert :ok = Muster.join(scope, g, pid)

      assert drain_calls() == []
    end

    test "leave then wait past cooldown queues a vacancy, flushed as a batch RPC",
         %{scope: scope, remote_group: g} do
      pid = spawn_link(fn -> Process.sleep(:infinity) end)

      assert :ok = Muster.join(scope, g, pid)
      _ = drain_calls()
      assert :ok = Muster.leave(scope, g, pid)

      # After cooldown the group is queued — no RPC has been sent yet.
      assert :vacant_queued = wait_for_group_state(scope, g, :vacant_queued)

      # The flush sends one batched vacant RPC to the router.
      trigger_flush(scope)

      [^scope, @fake_node, Scope, :vacant_batch, [^scope, groups, src, _], _] =
        assert_call(fn
          [^scope, @fake_node, Scope, :vacant_batch, [^scope, _, _, _], _] -> true
          _ -> false
        end)

      assert g in groups
      assert src == node()
    end

    test "a failed vacant batch re-queues the group for the next flush",
         %{scope: scope, remote_group: g} do
      pid = spawn_link(fn -> Process.sleep(:infinity) end)
      assert :ok = Muster.join(scope, g, pid)
      assert :ok = Muster.leave(scope, g, pid)
      assert :vacant_queued = wait_for_group_state(scope, g, :vacant_queued)

      # Fail the batch: the group must return to :vacant_queued (the retry).
      stub_call({:error, :noconnection})
      _ = drain_calls()
      trigger_flush(scope)

      assert_call(fn
        [^scope, @fake_node, Scope, :vacant_batch, [^scope, _, _, _], _] -> true
        _ -> false
      end)

      assert :vacant_queued = wait_for_group_state(scope, g, :vacant_queued)

      # Now let it succeed: the group is dropped from the state machine.
      stub_call(:ok)
      _ = drain_calls()
      trigger_flush(scope)

      assert_call(fn
        [^scope, @fake_node, Scope, :vacant_batch, [^scope, _, _, _], _] -> true
        _ -> false
      end)

      assert nil == wait_for_group_state(scope, g, &is_nil/1)
    end

    test "vacancies to the same router flush as a single batch", %{scope: scope} do
      [g1, g2] = groups_for_router(scope, @fake_node, 2)

      p1 = spawn_link(fn -> Process.sleep(:infinity) end)
      p2 = spawn_link(fn -> Process.sleep(:infinity) end)
      assert :ok = Muster.join(scope, g1, p1)
      assert :ok = Muster.join(scope, g2, p2)
      assert :ok = Muster.leave(scope, g1, p1)
      assert :ok = Muster.leave(scope, g2, p2)

      assert :vacant_queued = wait_for_group_state(scope, g1, :vacant_queued)
      assert :vacant_queued = wait_for_group_state(scope, g2, :vacant_queued)

      _ = drain_calls()
      trigger_flush(scope)

      [^scope, @fake_node, Scope, :vacant_batch, [^scope, groups, _, _], _] =
        assert_call(fn
          [^scope, @fake_node, Scope, :vacant_batch, [^scope, _, _, _], _] -> true
          _ -> false
        end)

      assert g1 in groups
      assert g2 in groups

      # The assert_call above consumed the one batch call; no others follow.
      remaining =
        Enum.count(
          drain_calls(),
          &match?([_, @fake_node, Scope, :vacant_batch, _, _], &1)
        )

      assert remaining == 0
    end
  end

  describe "rebalance × in-flight claim/cooldown races" do
    setup %{scope: scope, base_opts: opts} do
      start_supervised!(spec(scope, opts))
      :ok
    end

    defp trigger_rebalance(scope, new_members) do
      Kernel.send(Forum.Supervisor.name(scope), {:__rebalance_for_test, new_members})
    end

    # Probe a probe-ring built from `members` to find a group whose router
    # would land on `target_node`. We can't query Muster's own ring here yet
    # because the rebalance has not run — we need a group that will move *to*
    # the fake node once it does.
    defp group_for_router_under(members, target_node) do
      probe = :"_probe_#{System.unique_integer([:positive])}_muster_ring"
      {:ok, _} = ExHashRing.Ring.start_link(name: probe, replicas: 128)
      {:ok, _} = ExHashRing.Ring.set_nodes(probe, members)

      group =
        Stream.iterate(0, &(&1 + 1))
        |> Stream.map(&:"g#{&1}")
        |> Enum.find(fn g ->
          {:ok, n} = ExHashRing.Ring.find_node(probe, g)
          n == target_node
        end)

      ExHashRing.Ring.stop(probe)
      group
    end

    test "rebalance announces :occupied groups to the new router", %{scope: scope} do
      # Pick a group that will land on @fake_node once it joins the cluster.
      g = group_for_router_under([node(), @fake_node], @fake_node)

      pid = spawn_link(fn -> Process.sleep(:infinity) end)
      assert :ok = Muster.join(scope, g, pid)

      _ = drain_calls()
      trigger_rebalance(scope, [node(), @fake_node])

      [^scope, target, Scope, :receive_node_state, [^scope, src, groups | _], _] =
        assert_call(
          fn
            [^scope, _, Scope, :receive_node_state, [^scope, _, _ | _], _] -> true
            _ -> false
          end,
          500
        )

      assert target == @fake_node
      assert src == node()
      assert g in groups
    end

    test "rebalance announces :cooldown groups to the new router", %{scope: scope} do
      g = group_for_router_under([node(), @fake_node], @fake_node)

      pid = spawn_link(fn -> Process.sleep(:infinity) end)
      assert :ok = Muster.join(scope, g, pid)
      assert :ok = Muster.leave(scope, g, pid)

      # Let the telemetry → Scope cast settle so group_states[g] == :cooldown.
      Process.sleep(20)
      _ = drain_calls()

      trigger_rebalance(scope, [node(), @fake_node])

      [^scope, @fake_node, Scope, :receive_node_state, [^scope, _src, groups | _], _] =
        assert_call(
          fn
            [^scope, @fake_node, Scope, :receive_node_state, [^scope, _, _ | _], _] -> true
            _ -> false
          end,
          500
        )

      assert g in groups
    end

    test ":vacant_queued groups are NOT announced on rebalance", %{scope: scope} do
      inject_fake_remote(scope)
      g = group_for_router(scope, @fake_node)

      pid = spawn_link(fn -> Process.sleep(:infinity) end)
      assert :ok = Muster.join(scope, g, pid)
      assert :ok = Muster.leave(scope, g, pid)

      # After cooldown the group sits in :vacant_queued (the flush interval is
      # long; we never flush it here). We don't hold the group, so it must not
      # be announced via :receive_node_state.
      assert :vacant_queued = wait_for_group_state(scope, g, :vacant_queued)
      _ = drain_calls()

      trigger_rebalance(scope, [node(), :fake2@nowhere])

      Process.sleep(100)
      refute announced?(drain_calls(), g)
    end

    test ":vacant_flushing groups are NOT announced on rebalance", %{scope: scope} do
      inject_fake_remote(scope)
      g = group_for_router(scope, @fake_node)

      pid = spawn_link(fn -> Process.sleep(:infinity) end)
      assert :ok = Muster.join(scope, g, pid)
      assert :ok = Muster.leave(scope, g, pid)
      assert :vacant_queued = wait_for_group_state(scope, g, :vacant_queued)

      # Hold the batch RPC so the group stays :vacant_flushing across the
      # rebalance. (g is the only group and is excluded from the announce-set,
      # so the rebalance itself issues no :receive_node_state calls — the held
      # response only stalls the vacant batch worker.)
      stub_call(
        {:fn,
         fn ->
           Process.sleep(2_000)
           :ok
         end}
      )

      trigger_flush(scope)

      assert :vacant_flushing = wait_for_group_state(scope, g, :vacant_flushing)

      _ = drain_calls()

      trigger_rebalance(scope, [node(), :fake2@nowhere])

      Process.sleep(100)
      refute announced?(drain_calls(), g)

      # The in-flight batch was normalized back to :vacant_queued for a later flush.
      assert :vacant_queued = wait_for_group_state(scope, g, :vacant_queued)
    end

    # A re-join arriving while a vacant batch is in flight must NOT park behind
    # the batch: it re-claims immediately by dispatching :occupied. That
    # :occupied is dispatched after the batch, so it carries a higher seq and the
    # router's guard makes its INSERT win over the in-flight (lower-seq) DELETE
    # regardless of arrival order. Because the group moves straight to
    # :occupied_pending with a worker in flight, it can never wedge across a
    # rebalance (an earlier design parked the caller in :vacant_flushing and
    # could leave it with no worker to settle it when the router didn't move).
    test "re-join during an in-flight vacant flush re-claims immediately",
         %{scope: scope} do
      inject_fake_remote(scope)
      members_3 = [node(), @fake_node, :third@nowhere]

      # Router stays @fake_node across the rebalance — the formerly-wedging path.
      g = find_group_flipping_router([node(), @fake_node], @fake_node, members_3, @fake_node)

      pid = spawn_link(fn -> Process.sleep(:infinity) end)
      assert :ok = Muster.join(scope, g, pid)
      assert :ok = Muster.leave(scope, g, pid)
      assert :vacant_queued = wait_for_group_state(scope, g, :vacant_queued)

      # Hold every RPC so the vacant batch is still in flight when we re-join and
      # the re-claim's :occupied is still in flight across the rebalance.
      stub_call(
        {:fn,
         fn ->
           Process.sleep(2_000)
           :ok
         end}
      )

      trigger_flush(scope)
      assert :vacant_flushing = wait_for_group_state(scope, g, :vacant_flushing)
      _ = drain_calls()

      # Re-join while the batch is in flight → straight to :occupied_pending
      # (not parked in :vacant_flushing).
      rejoin =
        Task.async(fn ->
          Muster.join(scope, g, spawn_link(fn -> Process.sleep(:infinity) end))
        end)

      assert {:occupied_pending, [_]} =
               wait_for_group_state(scope, g, &match?({:occupied_pending, [_]}, &1))

      # The :occupied was dispatched immediately to the (current) router.
      assert {:ok, _} =
               wait_call(
                 fn
                   [_s, @fake_node, Scope, :occupied, [_, ^g, _, _], _] -> true
                   _ -> false
                 end,
                 3_000
               )

      # Rebalance with the router unchanged: :occupied_pending is left for the
      # in-flight :occupied worker to settle (the formerly-wedging case).
      trigger_rebalance(scope, members_3)

      assert :ok = Task.await(rejoin, 10_000)
      assert :occupied = wait_for_group_state(scope, g, :occupied, 5_000)
    end

    # rpc_timeout sets the inner Task.await bound during parallel rebalance
    # (`rpc_timeout + 1s`). The held RPC below sleeps 2_000ms, so we need
    # rpc_timeout large enough that the await window covers it.
    @tag rpc_timeout: 5_000
    test ":occupied_pending claims survive rebalance (caller gets :ok)",
         %{scope: scope} do
      inject_fake_remote(scope)

      # Pick a group whose router under the 2-node ring is @fake_node
      # (so the initial :occupied RPC dispatches to @fake_node) AND whose
      # router under the 3-node ring is :third@nowhere (so the rebalance
      # announces it to the new router and settles the parked waiter).
      members_3 = [node(), @fake_node, :third@nowhere]

      g =
        find_group_flipping_router(
          [node(), @fake_node],
          @fake_node,
          members_3,
          :third@nowhere
        )

      hold = self()
      ref = make_ref()

      # Hold the initial :occupied RPC indefinitely. The rebalance fires
      # while we're stuck and should settle the waiter via
      # :receive_node_state to :third@nowhere.
      stub_call(
        {:fn,
         fn ->
           Kernel.send(hold, {:rpc_held, ref})
           Process.sleep(2_000)
           :ok
         end}
      )

      task =
        Task.async(fn ->
          Muster.join(scope, g, spawn_link(fn -> Process.sleep(:infinity) end))
        end)

      assert_receive {:rpc_held, ^ref}, 1_000

      # Rebalance: switch to a 3-node ring. The router of `g` flips to
      # :third@nowhere; rebalance announces `g` via :receive_node_state and
      # settles the pending waiter with :ok.
      trigger_rebalance(scope, members_3)

      # Waiter gets :ok from the settle step (not :rebalance_in_progress).
      assert :ok = Task.await(task, 5_000)

      # The new router must have received :receive_node_state with g.
      received_announce =
        received_announce_for?(:third@nowhere, g, 1_000)

      assert received_announce,
             "expected :receive_node_state to :third@nowhere with #{inspect(g)}"
    end

    defp find_group_flipping_router(members_old, old_dest, members_new, new_dest) do
      uid = System.unique_integer([:positive])
      old_probe = :"_probe_old_#{uid}_muster_ring"
      new_probe = :"_probe_new_#{uid}_muster_ring"
      {:ok, _} = ExHashRing.Ring.start_link(name: old_probe, replicas: 128)
      {:ok, _} = ExHashRing.Ring.set_nodes(old_probe, members_old)
      {:ok, _} = ExHashRing.Ring.start_link(name: new_probe, replicas: 128)
      {:ok, _} = ExHashRing.Ring.set_nodes(new_probe, members_new)

      result =
        Stream.iterate(0, &(&1 + 1))
        |> Stream.map(&:"flip#{&1}")
        |> Enum.find(fn g ->
          with {:ok, ^old_dest} <- ExHashRing.Ring.find_node(old_probe, g),
               {:ok, ^new_dest} <- ExHashRing.Ring.find_node(new_probe, g) do
            true
          else
            _ -> false
          end
        end)

      ExHashRing.Ring.stop(old_probe)
      ExHashRing.Ring.stop(new_probe)
      result
    end

    # Poll the recorded call log for a :receive_node_state announcement of
    # `group` to `target`. Returns true if one arrives within `timeout`.
    defp received_announce_for?(target, group, timeout) do
      match?(
        {:ok, _},
        wait_call(
          fn
            [_scope, ^target, Scope, :receive_node_state, [_s, _src, groups | _], _] ->
              group in groups

            _ ->
              false
          end,
          timeout
        )
      )
    end

    # Rebalance with three remote destinations, each sleeping 200ms inside
    # the adapter. With parallel rebalance the total duration is ~200ms;
    # with sequential rebalance it would be ~600ms. A < 400ms ceiling is a
    # comfortable factor-of-2 margin for CI noise.
    @tag rpc_timeout: 5_000
    test "parallel rebalance — slow destinations don't block each other",
         %{scope: scope} do
      # Seed a group occupied locally so the rebalance has something to
      # announce; without any candidates the rebalance is trivially fast
      # regardless of parallelism.
      pid = spawn_link(fn -> Process.sleep(:infinity) end)
      assert :ok = Muster.join(scope, :rb_slow, pid)

      # Every remote :receive_node_state RPC sleeps 200ms then returns :ok.
      stub_call(
        {:fn,
         fn ->
           Process.sleep(200)
           :ok
         end}
      )

      members = [node(), :fake_a@nowhere, :fake_b@nowhere, :fake_c@nowhere]

      start_ms = System.monotonic_time(:millisecond)
      trigger_rebalance(scope, members)

      # Poll persistent_term :status until it leaves :rebalancing (the fake
      # peers never announce, so it settles on :converging, not :ready).
      Stream.repeatedly(fn -> :persistent_term.get({Forum.Muster, scope, :status}) end)
      |> Stream.take_while(&(&1 == :rebalancing))
      |> Enum.each(fn _ -> Process.sleep(5) end)

      duration_ms = System.monotonic_time(:millisecond) - start_ms

      assert duration_ms < 400,
             "expected parallel rebalance ~200ms, got #{duration_ms}ms (sequential would be ~600ms)"
    end
  end

  describe "rebalance occupancy snapshot completeness" do
    setup %{scope: scope, base_opts: opts} do
      start_supervised!(spec(scope, opts))
      :ok
    end

    # This node holds two groups, both routed to :x@nowhere AFTER the rebalance.
    # g1's router does not change (x before and after); g2's router changes
    # (z -> x). Because receive_node_state wipes ALL of this source's rows on x
    # before inserting the snapshot, the snapshot to x must be a FULL snapshot
    # of every group we hold routed to x — both g1 and g2 — or x would silently
    # drop {g1, node()}.
    test "snapshot to a router that gains a group includes the groups already routed there",
         %{scope: scope} do
      members_old = Enum.sort([node(), :x@nowhere, :z@nowhere])
      members_new = Enum.sort([node(), :x@nowhere])

      # g1: x both before and after (router UNCHANGED).
      g1 = find_group_flipping_router(members_old, :x@nowhere, members_new, :x@nowhere)
      # g2: z before, x after (router CHANGES onto x).
      g2 = find_group_flipping_router(members_old, :z@nowhere, members_new, :x@nowhere)

      assert g1 && g2 && g1 != g2

      # Establish the old 3-node membership, then hold both groups locally.
      trigger_rebalance(scope, members_old)

      p1 = spawn_link(fn -> Process.sleep(:infinity) end)
      p2 = spawn_link(fn -> Process.sleep(:infinity) end)
      assert :ok = Muster.join(scope, g1, p1)
      assert :ok = Muster.join(scope, g2, p2)

      _ = drain_calls()

      # Drop :z@nowhere. g2 moves onto x; g1 stays on x.
      trigger_rebalance(scope, members_new)

      [^scope, :x@nowhere, Scope, :receive_node_state, [^scope, src, groups | _], _] =
        assert_call(
          fn
            [^scope, :x@nowhere, Scope, :receive_node_state, [^scope, _, _ | _], _] -> true
            _ -> false
          end,
          500
        )

      assert src == node()
      assert g2 in groups, "the moved group must be announced to its new router"

      assert g1 in groups,
             "the unchanged group still routed to x must be re-announced, " <>
               "else the source-wide wipe on x drops {g1, node()}"
    end

    test "a router that gains nothing is not sent a snapshot", %{scope: scope} do
      # Add a node: groups only ever move *to* the new node, never onto the
      # pre-existing node(). So the unrelated remote router that gains nothing
      # must receive no receive_node_state call.
      members_old = Enum.sort([node(), :keep@nowhere])
      members_new = Enum.sort([node(), :keep@nowhere, :new@nowhere])

      # A group that stays on :keep@nowhere across the change.
      g = find_group_flipping_router(members_old, :keep@nowhere, members_new, :keep@nowhere)
      assert g

      trigger_rebalance(scope, members_old)
      pid = spawn_link(fn -> Process.sleep(:infinity) end)
      assert :ok = Muster.join(scope, g, pid)
      _ = drain_calls()

      trigger_rebalance(scope, members_new)
      Process.sleep(100)

      refute Enum.any?(drain_calls(), fn
               [_, :keep@nowhere, Scope, :receive_node_state, _, _] -> true
               _ -> false
             end)
    end
  end

  describe "router-readiness barrier" do
    setup %{scope: scope, base_opts: opts} do
      start_supervised!(spec(scope, opts))
      :ok
    end

    defp send_marker(scope, source, members) do
      Kernel.send(
        Forum.Supervisor.name(scope),
        {:rebalance_marker, source, :erlang.phash2(Enum.sort(members))}
      )
    end

    defp ready?(scope), do: :persistent_term.get({Forum.Muster, scope, :status}) == :ready

    # trigger_rebalance is an async send; a synchronous :status call after it
    # flushes the Scope mailbox (FIFO), guaranteeing do_rebalance has run.
    defp rebalance_sync(scope, members) do
      trigger_rebalance(scope, members)
      GenServer.call(Forum.Supervisor.name(scope), :status)
    end

    test "a single-node cluster is ready and can_decide? for its own view", %{scope: scope} do
      assert ready?(scope)
      assert Muster.can_decide?(scope, Muster.view_hash(scope))
    end

    test "can_decide? is false when the sender's view hash disagrees", %{scope: scope} do
      refute Muster.can_decide?(scope, Muster.view_hash(scope) + 1)
    end

    test "rebalance clears readiness until every peer's marker arrives", %{scope: scope} do
      members = Enum.sort([node(), :a@nowhere, :b@nowhere])
      rebalance_sync(scope, members)

      # status flips back to :stable, but the barrier is not satisfied yet.
      assert Muster.router(scope, :g) |> elem(0) == :ok
      refute ready?(scope)
      refute Muster.can_decide?(scope, Muster.view_hash(scope))

      send_marker(scope, :a@nowhere, members)
      refute_ready(scope)

      send_marker(scope, :b@nowhere, members)
      assert_ready(scope)
      assert Muster.can_decide?(scope, Muster.view_hash(scope))
    end

    test "view_hash updates on rebalance and markers for it are honored", %{scope: scope} do
      h0 = Muster.view_hash(scope)
      members = Enum.sort([node(), :a@nowhere])
      rebalance_sync(scope, members)
      h1 = Muster.view_hash(scope)

      assert h1 != h0
      assert h1 == :erlang.phash2(members)

      send_marker(scope, :a@nowhere, members)
      assert_ready(scope)
    end

    test "a marker for a different view does not count toward readiness", %{scope: scope} do
      members = Enum.sort([node(), :a@nowhere, :b@nowhere])
      rebalance_sync(scope, members)

      # a announces a stale view; it's recorded but disagrees with ours.
      send_marker(scope, :a@nowhere, [node(), :a@nowhere])
      send_marker(scope, :b@nowhere, members)
      refute_ready(scope)

      # a re-announces the current view → now everyone agrees.
      send_marker(scope, :a@nowhere, members)
      assert_ready(scope)
    end

    test "an announcement received before we adopt its view is retained (no lost marker)",
         %{scope: scope} do
      members = Enum.sort([node(), :a@nowhere, :b@nowhere])

      # Both peers announce the NEW view while we are still single-node and
      # have not adopted it. The old set+reset+discard barrier would drop these
      # (wrong current view, source not yet a member) and leave us permanently
      # stuck not-ready; latest-view-map retains them.
      send_marker(scope, :a@nowhere, members)
      send_marker(scope, :b@nowhere, members)
      GenServer.call(Forum.Supervisor.name(scope), :status)

      rebalance_sync(scope, members)

      # Retained announcements satisfy the barrier immediately on adoption.
      assert_ready(scope)
    end

    test "view heartbeat re-announces our current view to every member", %{scope: scope} do
      members = Enum.sort([node(), :a@nowhere, :b@nowhere])
      rebalance_sync(scope, members)
      vh = Muster.view_hash(scope)
      _ = drain_sends()

      trigger_view_heartbeat(scope)
      GenServer.call(Forum.Supervisor.name(scope), :status)

      heartbeat_targets =
        drain_sends()
        |> Enum.flat_map(fn
          [^scope, target, {:rebalance_marker, src, ^vh}] when src == node() ->
            [target]

          _ ->
            []
        end)
        |> Enum.sort()

      assert heartbeat_targets == [:a@nowhere, :b@nowhere]
    end

    test "members with no snapshot get an async marker", %{scope: scope} do
      # No groups held, so no member is an affected router: every remote member
      # gets the cheap async marker.
      members = Enum.sort([node(), :a@nowhere, :b@nowhere])
      _ = drain_sends()
      trigger_rebalance(scope, members)
      Process.sleep(50)

      marker_targets =
        drain_sends()
        |> Enum.flat_map(fn
          [^scope, target, {:rebalance_marker, src, _hash}] when src == node() ->
            [target]

          _ ->
            []
        end)
        |> Enum.sort()

      assert marker_targets == [:a@nowhere, :b@nowhere]
    end

    test "receive_node_state self-marks its source (the RPC is the marker)", %{scope: scope} do
      members = Enum.sort([node(), :src@nowhere])
      rebalance_sync(scope, members)
      refute ready?(scope)

      # A data snapshot from the only peer marks it ready — no separate
      # :rebalance_marker message involved.
      assert :ok = Scope.receive_node_state(scope, :src@nowhere, [], Muster.view_hash(scope), 1)
      assert_ready(scope)
    end

    test "a router that receives a snapshot is not also sent a separate marker",
         %{scope: scope} do
      members_old = Enum.sort([node(), :x@nowhere, :z@nowhere])
      members_new = Enum.sort([node(), :x@nowhere])
      g = find_group_flipping_router(members_old, :z@nowhere, members_new, :x@nowhere)
      assert g

      trigger_rebalance(scope, members_old)
      pid = spawn_link(fn -> Process.sleep(:infinity) end)
      assert :ok = Muster.join(scope, g, pid)
      _ = drain_calls()
      _ = drain_sends()

      trigger_rebalance(scope, members_new)
      Process.sleep(50)
      calls = drain_calls()
      sends = drain_sends()

      # x is an affected router: it gets the snapshot RPC (which carries the marker)...
      assert Enum.any?(calls, fn
               [^scope, :x@nowhere, Scope, :receive_node_state, _, _] -> true
               _ -> false
             end)

      # ...and is NOT also sent a redundant async marker.
      refute Enum.any?(sends, fn
               [^scope, :x@nowhere, {:rebalance_marker, _, _}] -> true
               _ -> false
             end)
    end

    defp assert_ready(scope, timeout \\ 500) do
      deadline = System.monotonic_time(:millisecond) + timeout
      do_wait_ready(scope, true, deadline)
    end

    defp refute_ready(scope) do
      # Give any in-flight marker a chance to (wrongly) flip readiness.
      Process.sleep(20)
      refute ready?(scope)
    end

    defp do_wait_ready(scope, expected, deadline) do
      cond do
        ready?(scope) == expected ->
          :ok

        System.monotonic_time(:millisecond) >= deadline ->
          flunk("readiness did not reach #{expected} in time")

        true ->
          Process.sleep(5)
          do_wait_ready(scope, expected, deadline)
      end
    end
  end
end
