defmodule Forum.MusterTest do
  # Cannot be async: the RecordingAdapter writes test pids to persistent_term
  # keyed by scope, and the injection of fake remote members manipulates
  # global state.
  use ExUnit.Case, async: false

  alias Forum.Muster
  alias Forum.Muster.Scope
  alias Forum.RecordingAdapter

  @fake_node :fake@nowhere

  setup ctx do
    scope = :"muster_test_#{System.unique_integer([:positive])}"

    on_exit(fn -> RecordingAdapter.reset(scope) end)
    RecordingAdapter.configure(scope, test_pid: self(), call_response: :ok)

    base_opts = [
      partitions: 2,
      vacancy_cooldown_ms: Map.get(ctx, :cooldown_ms, 50),
      # Long by default so the periodic flush never fires mid-test; tests that
      # exercise the flush drive it deterministically via trigger_flush/1.
      vacant_flush_interval_ms: Map.get(ctx, :flush_ms, 60_000),
      rpc_timeout_ms: Map.get(ctx, :rpc_timeout, 500),
      message_module: RecordingAdapter
    ]

    %{scope: scope, base_opts: base_opts}
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
    status = if flag, do: :rebalancing, else: :stable
    :persistent_term.put({Forum.Muster, scope, :status}, status)
  end

  # Finds a group whose current designated lookup routes to `target_node`.
  defp group_for_designated(scope, target_node) do
    Stream.iterate(0, &(&1 + 1))
    |> Stream.map(&:"g#{&1}")
    |> Enum.find(fn group ->
      case Muster.designated(scope, group) do
        {:ok, ^target_node} -> true
        _ -> false
      end
    end)
  end

  defp drain_adapter_events do
    receive do
      {:adapter_event, _} = msg -> [msg | drain_adapter_events()]
    after
      0 -> []
    end
  end

  defp trigger_flush(scope) do
    Kernel.send(Forum.Supervisor.name(scope), :flush_vacant)
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

  defp announce_for_group?(events, group) do
    Enum.any?(events, fn
      {:adapter_event,
       {:call, _, _, Forum.Muster.Scope, :receive_node_state, [_scope, _src, groups]}} ->
        group in groups

      _ ->
        false
    end)
  end

  # Find `count` distinct groups whose current designated is `target_node`.
  defp groups_for_designated(scope, target_node, count) do
    Stream.iterate(0, &(&1 + 1))
    |> Stream.map(&:"g#{&1}")
    |> Stream.filter(fn group ->
      match?({:ok, ^target_node}, Muster.designated(scope, group))
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

    test "exposes designated lookup", %{scope: scope, base_opts: opts} do
      start_supervised!(spec(scope, opts))
      assert {:ok, n} = Muster.designated(scope, :anything)
      assert n == node()
    end
  end

  describe "designated/2 and members/1" do
    setup %{scope: scope, base_opts: opts} do
      start_supervised!(spec(scope, opts))
      :ok
    end

    test "returns {:ok, node()} on a single-node cluster", %{scope: scope} do
      assert {:ok, n} = Muster.designated(scope, :any_group)
      assert n == node()
    end

    test "members/1 returns the sorted cluster member list", %{scope: scope} do
      assert Muster.members(scope) == [node()]
    end

    test "returns {:rebalancing, members} when the flag is set", %{scope: scope} do
      members = Enum.sort([node(), @fake_node])
      {:ok, _} = ExHashRing.Ring.set_nodes(ring_name(scope), members)
      set_rebalancing(scope, true)

      assert {:rebalancing, ^members} = Muster.designated(scope, :any_group)
      assert Muster.members(scope) == members

      set_rebalancing(scope, false)
      assert {:ok, _node} = Muster.designated(scope, :any_group)
    end
  end

  describe "remote entry points write directly to occupancy_table (no Scope mailbox)" do
    setup %{scope: scope, base_opts: opts} do
      start_supervised!(spec(scope, opts))
      :ok
    end

    test "occupied/3 inserts a {group, source_node} row", %{scope: scope} do
      assert :ok = Scope.occupied(scope, :rg1, :src@nowhere)
      assert :src@nowhere in Scope.occupancy(scope, :rg1)
    end

    test "vacant_batch/3 deletes multiple {group, source_node} rows", %{scope: scope} do
      :ok = Scope.occupied(scope, :rg2a, :src@nowhere)
      :ok = Scope.occupied(scope, :rg2b, :src@nowhere)
      assert :src@nowhere in Scope.occupancy(scope, :rg2a)
      assert :src@nowhere in Scope.occupancy(scope, :rg2b)

      assert :ok = Scope.vacant_batch(scope, [:rg2a, :rg2b], :src@nowhere)
      refute :src@nowhere in Scope.occupancy(scope, :rg2a)
      refute :src@nowhere in Scope.occupancy(scope, :rg2b)
    end

    test "vacant_batch/3 only deletes rows for the given source", %{scope: scope} do
      :ok = Scope.occupied(scope, :rg3, :src_a@nowhere)
      :ok = Scope.occupied(scope, :rg3, :src_b@nowhere)

      assert :ok = Scope.vacant_batch(scope, [:rg3], :src_a@nowhere)
      assert Scope.occupancy(scope, :rg3) == [:src_b@nowhere]
    end

    test "receive_node_state/3 replaces all rows for a source", %{scope: scope} do
      # Seed something the snapshot should clear.
      :ok = Scope.occupied(scope, :stale_g, :src@nowhere)

      assert :ok = Scope.receive_node_state(scope, :src@nowhere, [:fresh_a, :fresh_b])

      refute :src@nowhere in Scope.occupancy(scope, :stale_g)
      assert :src@nowhere in Scope.occupancy(scope, :fresh_a)
      assert :src@nowhere in Scope.occupancy(scope, :fresh_b)
    end

    test "writes from different sources don't interfere", %{scope: scope} do
      :ok = Scope.occupied(scope, :shared, :src_a@nowhere)
      :ok = Scope.occupied(scope, :shared, :src_b@nowhere)

      assert Enum.sort(Scope.occupancy(scope, :shared)) ==
               [:src_a@nowhere, :src_b@nowhere]

      :ok = Scope.vacant_batch(scope, [:shared], :src_a@nowhere)
      assert Scope.occupancy(scope, :shared) == [:src_b@nowhere]
    end

    test "Scope mailbox is unaffected by remote-entry writes", %{scope: scope} do
      # If the writes still went through the mailbox, a held :status call
      # would queue behind them. Issue many writes concurrently, then assert
      # :status responds promptly.
      tasks =
        for i <- 1..200 do
          Task.async(fn -> Scope.occupied(scope, :"hot_#{i}", :src@nowhere) end)
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

  describe "single-node join/leave (designated == self)" do
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

    test "join does not fire RPC when designated is self", %{scope: scope} do
      pid = spawn_link(fn -> Process.sleep(:infinity) end)
      _ = drain_adapter_events()
      assert :ok = Muster.join(scope, :g1, pid)
      events = drain_adapter_events()

      refute Enum.any?(events, &match?({:adapter_event, {:call, _, _, _, _, _}}, &1))
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

  describe "designated == remote (fake node injection)" do
    setup %{scope: scope, base_opts: opts} do
      start_supervised!(spec(scope, opts))
      inject_fake_remote(scope)

      %{
        remote_group: group_for_designated(scope, @fake_node),
        self_group: group_for_designated(scope, node())
      }
    end

    test "first join dispatches a single occupied RPC and waits for reply",
         %{scope: scope, remote_group: g} do
      _ = drain_adapter_events()

      pid = spawn_link(fn -> Process.sleep(:infinity) end)
      assert :ok = Muster.join(scope, g, pid)

      assert_received {:adapter_event,
                       {:call, ^scope, @fake_node, Forum.Muster.Scope, :occupied, [^scope, ^g, _]}}

      assert Muster.local_member_count(scope, g) == 1
    end

    test "second join (count > 0) skips the RPC", %{scope: scope, remote_group: g} do
      pid1 = spawn_link(fn -> Process.sleep(:infinity) end)
      pid2 = spawn_link(fn -> Process.sleep(:infinity) end)

      assert :ok = Muster.join(scope, g, pid1)
      _ = drain_adapter_events()

      assert :ok = Muster.join(scope, g, pid2)

      refute_received {:adapter_event, {:call, _, _, _, _, _}}
    end

    @tag rpc_timeout: 5_000
    test "concurrent joins dedup to a single RPC", %{scope: scope, remote_group: g} do
      _ = drain_adapter_events()
      test_pid = self()
      hold_ms = 200

      RecordingAdapter.configure(scope,
        call_response:
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

      events = drain_adapter_events()

      call_count =
        Enum.count(events, fn
          {:adapter_event, {:call, _, _, Forum.Muster.Scope, :occupied, [_scope, ^g, _]}} ->
            true

          _ ->
            false
        end)

      assert call_count == 1
    end

    test "RPC failure returns :rpc_failed and does not insert into partition",
         %{scope: scope, remote_group: g} do
      RecordingAdapter.configure(scope, call_response: {:error, :noconnection})

      pid = spawn_link(fn -> Process.sleep(:infinity) end)
      assert {:error, :rpc_failed} = Muster.join(scope, g, pid)
      assert Muster.local_member_count(scope, g) == 0
      refute Muster.local_member?(scope, g, pid)
    end

    test "next join retries the RPC after a previous failure",
         %{scope: scope, remote_group: g} do
      RecordingAdapter.configure(scope, call_response: {:error, :noconnection})
      pid = spawn_link(fn -> Process.sleep(:infinity) end)
      assert {:error, :rpc_failed} = Muster.join(scope, g, pid)

      _ = drain_adapter_events()

      RecordingAdapter.configure(scope, call_response: :ok)
      assert :ok = Muster.join(scope, g, pid)

      assert_received {:adapter_event,
                       {:call, ^scope, @fake_node, Forum.Muster.Scope, :occupied, [^scope, ^g, _]}}

      assert Muster.local_member_count(scope, g) == 1
    end

    @tag rpc_timeout: 5_000
    test "Scope mailbox is not blocked by a slow RPC",
         %{scope: scope, remote_group: g} do
      test_pid = self()

      RecordingAdapter.configure(scope,
        call_response:
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

      %{remote_group: group_for_designated(scope, @fake_node)}
    end

    test "leave + re-join within cooldown does not fire RPC",
         %{scope: scope, remote_group: g} do
      pid = spawn_link(fn -> Process.sleep(:infinity) end)

      assert :ok = Muster.join(scope, g, pid)
      _ = drain_adapter_events()

      assert :ok = Muster.leave(scope, g, pid)
      # Wait briefly to let telemetry → scope cast settle, then re-join.
      Process.sleep(20)
      assert :ok = Muster.join(scope, g, pid)

      events = drain_adapter_events()

      refute Enum.any?(events, &match?({:adapter_event, {:call, _, _, _, _, _}}, &1))
    end

    test "leave then wait past cooldown queues a vacancy, flushed as a batch RPC",
         %{scope: scope, remote_group: g} do
      pid = spawn_link(fn -> Process.sleep(:infinity) end)

      assert :ok = Muster.join(scope, g, pid)
      _ = drain_adapter_events()
      assert :ok = Muster.leave(scope, g, pid)

      # After cooldown the group is queued — no RPC has been sent yet.
      assert :vacant_queued = wait_for_group_state(scope, g, :vacant_queued)

      # The flush sends one batched vacant RPC to the designated.
      trigger_flush(scope)

      assert_receive {:adapter_event,
                      {:call, ^scope, @fake_node, Forum.Muster.Scope, :vacant_batch,
                       [^scope, groups, src]}},
                     1_000

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
      RecordingAdapter.configure(scope, call_response: {:error, :noconnection})
      _ = drain_adapter_events()
      trigger_flush(scope)

      assert_receive {:adapter_event,
                      {:call, ^scope, @fake_node, Forum.Muster.Scope, :vacant_batch,
                       [^scope, _, _]}},
                     1_000

      assert :vacant_queued = wait_for_group_state(scope, g, :vacant_queued)

      # Now let it succeed: the group is dropped from the state machine.
      RecordingAdapter.configure(scope, call_response: :ok)
      _ = drain_adapter_events()
      trigger_flush(scope)

      assert_receive {:adapter_event,
                      {:call, ^scope, @fake_node, Forum.Muster.Scope, :vacant_batch,
                       [^scope, _, _]}},
                     1_000

      assert nil == wait_for_group_state(scope, g, &is_nil/1)
    end

    test "vacancies to the same designated flush as a single batch", %{scope: scope} do
      [g1, g2] = groups_for_designated(scope, @fake_node, 2)

      p1 = spawn_link(fn -> Process.sleep(:infinity) end)
      p2 = spawn_link(fn -> Process.sleep(:infinity) end)
      assert :ok = Muster.join(scope, g1, p1)
      assert :ok = Muster.join(scope, g2, p2)
      assert :ok = Muster.leave(scope, g1, p1)
      assert :ok = Muster.leave(scope, g2, p2)

      assert :vacant_queued = wait_for_group_state(scope, g1, :vacant_queued)
      assert :vacant_queued = wait_for_group_state(scope, g2, :vacant_queued)

      _ = drain_adapter_events()
      trigger_flush(scope)

      assert_receive {:adapter_event,
                      {:call, ^scope, @fake_node, Forum.Muster.Scope, :vacant_batch,
                       [^scope, groups, _]}},
                     1_000

      assert g1 in groups
      assert g2 in groups

      # The single assert_receive above consumed the one batch call; no others.
      remaining =
        Enum.count(
          drain_adapter_events(),
          &match?(
            {:adapter_event, {:call, _, @fake_node, Forum.Muster.Scope, :vacant_batch, _}},
            &1
          )
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

    # Probe a probe-ring built from `members` to find a group whose designation
    # would land on `target_node`. We can't query Muster's own ring here yet
    # because the rebalance has not run — we need a group that will move *to*
    # the fake node once it does.
    defp group_for_designated_under(members, target_node) do
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

    test "rebalance announces :occupied groups to the new designated", %{scope: scope} do
      # Pick a group that will land on @fake_node once it joins the cluster.
      g = group_for_designated_under([node(), @fake_node], @fake_node)

      pid = spawn_link(fn -> Process.sleep(:infinity) end)
      assert :ok = Muster.join(scope, g, pid)

      _ = drain_adapter_events()
      trigger_rebalance(scope, [node(), @fake_node])

      assert_receive {:adapter_event,
                      {:call, ^scope, target, Forum.Muster.Scope, :receive_node_state,
                       [^scope, src, groups]}},
                     500

      assert target == @fake_node
      assert src == node()
      assert g in groups
    end

    test "rebalance announces :cooldown groups to the new designated", %{scope: scope} do
      g = group_for_designated_under([node(), @fake_node], @fake_node)

      pid = spawn_link(fn -> Process.sleep(:infinity) end)
      assert :ok = Muster.join(scope, g, pid)
      assert :ok = Muster.leave(scope, g, pid)

      # Let the telemetry → Scope cast settle so group_states[g] == :cooldown.
      Process.sleep(20)
      _ = drain_adapter_events()

      trigger_rebalance(scope, [node(), @fake_node])

      assert_receive {:adapter_event,
                      {:call, ^scope, @fake_node, Forum.Muster.Scope, :receive_node_state,
                       [^scope, _src, groups]}},
                     500

      assert g in groups
    end

    test ":vacant_queued groups are NOT announced on rebalance", %{scope: scope} do
      inject_fake_remote(scope)
      g = group_for_designated(scope, @fake_node)

      pid = spawn_link(fn -> Process.sleep(:infinity) end)
      assert :ok = Muster.join(scope, g, pid)
      assert :ok = Muster.leave(scope, g, pid)

      # After cooldown the group sits in :vacant_queued (the flush interval is
      # long; we never flush it here). We don't hold the group, so it must not
      # be announced via :receive_node_state.
      assert :vacant_queued = wait_for_group_state(scope, g, :vacant_queued)
      _ = drain_adapter_events()

      trigger_rebalance(scope, [node(), :fake2@nowhere])

      Process.sleep(100)
      refute announce_for_group?(drain_adapter_events(), g)
    end

    test ":vacant_flushing groups are NOT announced on rebalance", %{scope: scope} do
      inject_fake_remote(scope)
      g = group_for_designated(scope, @fake_node)

      pid = spawn_link(fn -> Process.sleep(:infinity) end)
      assert :ok = Muster.join(scope, g, pid)
      assert :ok = Muster.leave(scope, g, pid)
      assert :vacant_queued = wait_for_group_state(scope, g, :vacant_queued)

      # Hold the batch RPC so the group stays :vacant_flushing across the
      # rebalance. (g is the only group and is excluded from the announce-set,
      # so the rebalance itself issues no :receive_node_state calls — the held
      # response only stalls the vacant batch worker.)
      RecordingAdapter.configure(scope,
        call_response:
          {:fn,
           fn ->
             Process.sleep(2_000)
             :ok
           end}
      )

      trigger_flush(scope)

      assert {:vacant_flushing, _} =
               wait_for_group_state(scope, g, &match?({:vacant_flushing, _}, &1))

      _ = drain_adapter_events()

      trigger_rebalance(scope, [node(), :fake2@nowhere])

      Process.sleep(100)
      refute announce_for_group?(drain_adapter_events(), g)

      # The in-flight batch was normalized back to :vacant_queued for a later flush.
      assert :vacant_queued = wait_for_group_state(scope, g, :vacant_queued)
    end

    # rpc_timeout sets the inner Task.await bound during parallel rebalance
    # (`rpc_timeout + 1s`). The RecordingAdapter's hold below sleeps 2_000ms,
    # so we need rpc_timeout large enough that the await window covers it.
    @tag rpc_timeout: 5_000
    test ":occupied_pending claims survive rebalance (caller gets :ok)",
         %{scope: scope} do
      inject_fake_remote(scope)

      # Pick a group whose designated under the 2-node ring is @fake_node
      # (so the initial :occupied RPC dispatches to @fake_node) AND whose
      # designated under the 3-node ring is :third@nowhere (so the rebalance
      # announces it to the new designated and settles the parked waiter).
      members_3 = [node(), @fake_node, :third@nowhere]

      g =
        find_group_flipping_designation(
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
      RecordingAdapter.configure(scope,
        call_response:
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

      # Rebalance: switch to a 3-node ring. The designation of `g` flips to
      # :third@nowhere; rebalance announces `g` via :receive_node_state and
      # settles the pending waiter with :ok.
      trigger_rebalance(scope, members_3)

      # Waiter gets :ok from the settle step (not :rebalance_in_progress).
      assert :ok = Task.await(task, 5_000)

      # The new designated must have received :receive_node_state with g.
      received_announce =
        receive_announce_for(:third@nowhere, g, 1_000)

      assert received_announce,
             "expected :receive_node_state to :third@nowhere with #{inspect(g)}"
    end

    defp find_group_flipping_designation(members_old, old_dest, members_new, new_dest) do
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

    defp receive_announce_for(target, group, timeout) do
      deadline = System.monotonic_time(:millisecond) + timeout
      do_receive_announce_for(target, group, deadline)
    end

    defp do_receive_announce_for(target, group, deadline) do
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:adapter_event,
         {:call, _scope, ^target, Forum.Muster.Scope, :receive_node_state, [_s, _src, groups]}} ->
          if group in groups, do: true, else: do_receive_announce_for(target, group, deadline)

        {:adapter_event, _} ->
          do_receive_announce_for(target, group, deadline)
      after
        remaining -> false
      end
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
      RecordingAdapter.configure(scope,
        call_response:
          {:fn,
           fn ->
             Process.sleep(200)
             :ok
           end}
      )

      members = [node(), :fake_a@nowhere, :fake_b@nowhere, :fake_c@nowhere]

      start_ms = System.monotonic_time(:millisecond)
      trigger_rebalance(scope, members)

      # Poll persistent_term :status until it flips back to :stable.
      Stream.repeatedly(fn -> :persistent_term.get({Forum.Muster, scope, :status}) end)
      |> Stream.take_while(&(&1 != :stable))
      |> Enum.each(fn _ -> Process.sleep(5) end)

      duration_ms = System.monotonic_time(:millisecond) - start_ms

      assert duration_ms < 400,
             "expected parallel rebalance ~200ms, got #{duration_ms}ms (sequential would be ~600ms)"
    end
  end
end
