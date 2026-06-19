defmodule Forum.Muster.Shard do
  @moduledoc false
  # Per-group claim shard for Forum.Muster.
  #
  # There are N shards per node (N = the partition count), one per partition
  # index, looked up by `:erlang.phash2(group, N)` exactly like Forum.Partition.
  # A shard owns the per-group state machine for its slice of groups — the
  # "have I told the router about this group?" question — so that a storm of
  # first-member claims for distinct groups spreads across N mailboxes instead
  # of serializing through the single Forum.Muster.Scope coordinator.
  #
  # Owns:
  #   * group_states — the per-group state machine.
  #   * cooldown_timers — the "recently vacant" suppression timers.
  #   * A periodic vacant flush of its own :vacant_queued groups, in per-router
  #     batches; a failed batch re-queues, so the flush doubles as a
  #     self-draining retry.
  #
  # Does NOT own any cluster-coordination state. The ring, the router-role
  # occupancy table, the readiness barrier, snapshot apply, and rebalance
  # orchestration all live in Forum.Muster.Scope. A shard reads the (shared,
  # ETS-backed) ring directly and writes the (:public) occupancy table directly,
  # and it NEVER synchronously calls the coordinator — so the coordinator can
  # synchronously call shards during a rebalance without any deadlock risk.
  use GenServer
  require Logger
  use Snabbkaffe

  alias ExHashRing.Ring
  alias Forum.Muster.Scope

  defmodule State do
    @moduledoc false
    @type group_state ::
            :occupied
            | :cooldown
            | :vacant_queued
            | {:occupied_pending, [{GenServer.from(), pid}]}
            | :vacant_flushing

    @type t :: %__MODULE__{
            scope: atom,
            index: non_neg_integer,
            occupancy_table: atom,
            message_module: module,
            vacancy_cooldown_ms: non_neg_integer,
            vacant_flush_interval_ms: pos_integer,
            rpc_timeout_ms: timeout,
            group_states: %{Forum.group() => group_state},
            cooldown_timers: %{Forum.group() => reference}
          }
    defstruct [
      :scope,
      :index,
      :occupancy_table,
      :message_module,
      :vacancy_cooldown_ms,
      :vacant_flush_interval_ms,
      :rpc_timeout_ms,
      group_states: %{},
      cooldown_timers: %{}
    ]
  end

  @default_vacancy_cooldown_ms 30_000
  @default_vacant_flush_interval_ms 5_000
  @default_rpc_timeout_ms 5_000

  @spec start_link(atom, non_neg_integer, Keyword.t()) :: GenServer.on_start()
  def start_link(scope, index, opts \\ []) do
    GenServer.start_link(__MODULE__, [scope, index, opts],
      name: Forum.Supervisor.shard_name(scope, index)
    )
  end

  @impl true
  def init([scope, index, opts]) do
    vacancy_cooldown_ms = Keyword.get(opts, :vacancy_cooldown_ms, @default_vacancy_cooldown_ms)

    vacant_flush_interval_ms =
      Keyword.get(opts, :vacant_flush_interval_ms, @default_vacant_flush_interval_ms)

    rpc_timeout_ms = Keyword.get(opts, :rpc_timeout_ms, @default_rpc_timeout_ms)
    message_module = Keyword.get(opts, :message_module, Forum.Adapter.ErlDist)

    state = %State{
      scope: scope,
      index: index,
      occupancy_table: Scope.occupancy_table_name(scope),
      message_module: message_module,
      vacancy_cooldown_ms: vacancy_cooldown_ms,
      vacant_flush_interval_ms: vacant_flush_interval_ms,
      rpc_timeout_ms: rpc_timeout_ms
    }

    {:ok, rebuild_group_states(state), {:continue, :schedule}}
  end

  @impl true
  def handle_continue(:schedule, state) do
    schedule_vacant_flush(state)
    {:noreply, state}
  end

  # On (re)start, adopt every group our aligned partition still holds as
  # :occupied. The occupancy rows for those groups (self rows, or rows on a
  # remote router) are owned by the long-lived coordinator / remote routers and
  # survive a shard restart, so we only need to rebuild the local state machine.
  # Groups with no live members (a previous :cooldown / :occupied_pending) are
  # not re-adopted; their stale router entries drain via drop_stale / the flush,
  # exactly as on a coordinator restart.
  defp rebuild_group_states(state) do
    partition = Forum.Supervisor.partition_name(state.scope, state.index)

    group_states =
      partition
      |> Forum.Partition.groups()
      |> Map.new(fn group -> {group, :occupied} end)

    %{state | group_states: group_states}
  end

  ## handle_call

  # Local source — Muster.join asking us to claim this group on its router.
  @impl true
  def handle_call({:claim, group, pid}, from, state) do
    handle_claim(group, pid, from, state)
  end

  # Coordinator-driven rebalance (synchronous). The coordinator has already
  # flipped :status to :rebalancing and swapped the ring to `new_members` before
  # calling us, so:
  #   * find_node/2 returns the NEW router, find_historical_node(_, _, 1) the OLD.
  #   * because our mailbox is FIFO, every in-flight claim's occupancy write /
  #     :occupied dispatch was processed before this call, so the held set we
  #     return is COMPLETE — the coordinator can build a complete per-router
  #     snapshot from it (the "one complete snapshot per source" invariant).
  #
  # We do three things and reply with our held set:
  #   1) Normalize an in-flight vacant batch (:vacant_flushing) back to
  #      :vacant_queued so the next flush re-routes it to the post-rebalance
  #      router; the in-flight worker's result lands in the catch-all and is
  #      dropped.
  #   2) Settle every :occupied_pending group whose router CHANGED: register the
  #      waiters and reply :ok optimistically, then move to :occupied. Safe — and
  #      done here rather than after the snapshot dispatch — because :status is
  #      :rebalancing throughout, so senders flood (router/2) rather than target a
  #      not-yet-populated occupancy row. The coordinator includes these groups in
  #      the snapshot it sends right after gathering us. Their original
  #      (old-router) :occupied worker's reply lands in handle_occupied_done's
  #      catch-all (state is :occupied by then) and is dropped.
  #   3) Return held groups (:occupied | :cooldown | :occupied_pending) for the
  #      coordinator to snapshot.
  def handle_call({:rebalance, _new_members}, _from, state) do
    state = normalize_pending_for_rebalance(state)
    state = settle_moved_pending(state)

    held =
      for {group, gs} <- state.group_states,
          gs in [:occupied, :cooldown] or match?({:occupied_pending, _}, gs),
          do: group

    {:reply, {:held, held}, state}
  end

  # Introspection — the coordinator folds every shard's group_states together to
  # answer Muster.dump/1 and the :status call used by tests.
  def handle_call(:group_states, _from, state) do
    {:reply, state.group_states, state}
  end

  ## handle_info

  # Telemetry handler (attached by the coordinator) routes the [:group, :vacant]
  # event for groups in our slice here when their last local member leaves.
  @impl true
  def handle_info({:local_vacant, group}, state) do
    handle_local_vacant(group, state)
  end

  # Cooldown timer fired for `group`.
  def handle_info({:vacancy_expired, group}, state) do
    handle_vacancy_expired(group, state)
  end

  # Worker reported back the result of a claim (:occupied) RPC.
  def handle_info({{:occupied_done, group}, _ref, :process, _pid, exit_reason}, state) do
    handle_occupied_done(group, worker_result(exit_reason), state)
  end

  # Worker reported back the result of a batched :vacant flush to one router.
  def handle_info({{:vacant_batch_done, groups}, _ref, :process, _pid, exit_reason}, state) do
    {:noreply, handle_vacant_batch_done(groups, worker_result(exit_reason), state)}
  end

  # Periodic flush of queued vacancies.
  def handle_info(:flush_vacant, state) do
    state = flush_vacant(state)
    schedule_vacant_flush(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## State machine — claim

  defp handle_claim(group, pid, from, state) do
    case Map.get(state.group_states, group) do
      nil ->
        router_node = router_from_state(state, group)

        if router_node == node() do
          Logger.debug(
            "Muster[#{node()}|#{state.scope}] claim #{inspect(group)}: local router, occupied"
          )

          Scope.upsert_if_newer(state.occupancy_table, {group, node()}, next_seq())
          register_member(state, group, pid)
          {:reply, :ok, put_group_state(state, group, :occupied)}
        else
          Logger.debug(
            "Muster[#{node()}|#{state.scope}] claim #{inspect(group)}: dispatching :occupied to router #{inspect(router_node)}"
          )

          dispatch_rpc(:occupied, group, router_node, state)
          {:noreply, put_group_state(state, group, {:occupied_pending, [{from, pid}]})}
        end

      :occupied ->
        Logger.debug("Muster[#{node()}|#{state.scope}] claim #{inspect(group)}: already occupied")

        register_member(state, group, pid)
        {:reply, :ok, state}

      :cooldown ->
        Logger.debug(
          "Muster[#{node()}|#{state.scope}] claim #{inspect(group)}: reclaim from cooldown (no RPC)"
        )

        state = cancel_cooldown(state, group)
        register_member(state, group, pid)
        {:reply, :ok, put_group_state(state, group, :occupied)}

      {:occupied_pending, waiters} ->
        Logger.debug(
          "Muster[#{node()}|#{state.scope}] claim #{inspect(group)}: parked behind in-flight :occupied (#{length(waiters) + 1} waiter(s))"
        )

        {:noreply, put_group_state(state, group, {:occupied_pending, [{from, pid} | waiters]})}

      vacant when vacant in [:vacant_queued, :vacant_flushing] ->
        # Reclaim a group we were releasing. For :vacant_queued nothing is in
        # flight. For :vacant_flushing a vacant batch DELETE is in flight, but we
        # do NOT wait for it: the :occupied we dispatch now is dispatched after
        # that batch, so next_seq/0 gives it a strictly higher seq, and the
        # router's seq guard makes the INSERT win over the racing (lower-seq)
        # DELETE regardless of arrival order (see the versioning note above
        # Scope.occupied/4). The in-flight batch's eventual :vacant_batch_done
        # lands in handle_vacant_batch_done's catch-all (state is no longer
        # :vacant_flushing) and is dropped. Both the batch and the re-claim are
        # dispatched from THIS shard (same group → same shard), so their dispatch
        # order — and thus their seq order — is well defined.
        router_node = router_from_state(state, group)

        if router_node == node() do
          Logger.debug(
            "Muster[#{node()}|#{state.scope}] claim #{inspect(group)}: reclaim from #{vacant}, local router"
          )

          Scope.upsert_if_newer(state.occupancy_table, {group, node()}, next_seq())
          register_member(state, group, pid)
          {:reply, :ok, put_group_state(state, group, :occupied)}
        else
          Logger.debug(
            "Muster[#{node()}|#{state.scope}] claim #{inspect(group)}: reclaim from #{vacant}, dispatching :occupied to router #{inspect(router_node)}"
          )

          dispatch_rpc(:occupied, group, router_node, state)
          {:noreply, put_group_state(state, group, {:occupied_pending, [{from, pid}]})}
        end
    end
  end

  # Register a (now-claimed) first local member from inside the shard. Doing the
  # Partition.join here — rather than in the caller after `claim` returns —
  # guarantees the monitored entry is installed as part of resolving the claim,
  # so the router is never left believing we hold a group that has no live local
  # member (e.g. if the caller dies right after the claim). If `pid` is already
  # dead, Partition.join installs the monitor and the immediate DOWN drives the
  # normal :vacant -> :cooldown retraction.
  defp register_member(state, group, pid) do
    Forum.Partition.join(Forum.Supervisor.partition(state.scope, group), group, pid)
    :ok
  end

  defp handle_local_vacant(group, state) do
    case Map.get(state.group_states, group) do
      :occupied ->
        Logger.debug(
          "Muster[#{node()}|#{state.scope}] #{inspect(group)} vacant locally, entering cooldown (#{state.vacancy_cooldown_ms}ms)"
        )

        ref = Process.send_after(self(), {:vacancy_expired, group}, state.vacancy_cooldown_ms)

        state = %{
          state
          | cooldown_timers: Map.put(state.cooldown_timers, group, ref)
        }

        {:noreply, put_group_state(state, group, :cooldown)}

      _ ->
        # Vacancy telemetry can arrive when group_states is something other than
        # :occupied after a shard restart (the partition still has entries but
        # we have not finished re-adopting) or during transient states.
        # Best-effort: ignore; the next event will bring us back in sync.
        {:noreply, state}
    end
  end

  defp handle_vacancy_expired(group, state) do
    case Map.get(state.group_states, group) do
      :cooldown ->
        partition = Forum.Supervisor.partition(state.scope, group)
        count = Forum.Partition.member_count(partition, group)

        state = %{state | cooldown_timers: Map.delete(state.cooldown_timers, group)}

        if count > 0 do
          # This is the guard that closes the Muster.join fast-path race.
          # Muster.join skips the router claim when the local count is > 0, and a
          # fast re-occupation does not notify this shard (the Partition :occupied
          # telemetry is unhandled). So a member can join while this group sits in
          # :cooldown after its previous occupant left. Rechecking the live count
          # here catches that: count > 0 means someone re-joined during cooldown,
          # so we revert to :occupied and never tell the router :vacant (its
          # occupancy row for us was never removed).
          Logger.debug(
            "Muster[#{node()}|#{state.scope}] cooldown expired for #{inspect(group)} but #{count} local member(s) present, reclaiming"
          )

          {:noreply, put_group_state(state, group, :occupied)}
        else
          # Cooldown elapsed and still empty. Queue the vacancy; the periodic
          # flush groups all queued vacancies by current router, sends one
          # batched RPC per router, and re-queues any that fail.
          Logger.debug(
            "Muster[#{node()}|#{state.scope}] cooldown expired for #{inspect(group)}, queued for vacant flush"
          )

          {:noreply, put_group_state(state, group, :vacant_queued)}
        end

      _ ->
        {:noreply, state}
    end
  end

  defp handle_occupied_done(group, result, state) do
    case Map.get(state.group_states, group) do
      {:occupied_pending, waiters} ->
        case result do
          :ok ->
            Logger.debug(
              "Muster[#{node()}|#{state.scope}] :occupied confirmed for #{inspect(group)}, replying :ok to #{length(waiters)} waiter(s)"
            )

            # Register each waiter's pid only now that the router has been told,
            # then reply. On failure we never register (below), preserving the
            # "pid not registered on rpc_failed" contract.
            Enum.each(waiters, fn {from, pid} ->
              register_member(state, group, pid)
              GenServer.reply(from, :ok)
            end)

            {:noreply, put_group_state(state, group, :occupied)}

          _ ->
            Logger.debug(
              "Muster[#{node()}|#{state.scope}] :occupied RPC failed for #{inspect(group)}: #{inspect(result)}, replying error to #{length(waiters)} waiter(s)"
            )

            Enum.each(waiters, fn {from, _pid} -> GenServer.reply(from, {:error, :rpc_failed}) end)

            {:noreply, delete_group_state(state, group)}
        end

      _ ->
        # Out-of-band — e.g. the group was settled by a rebalance (now :occupied)
        # before this old-router worker returned. Drop.
        {:noreply, state}
    end
  end

  # Result of one batched :vacant flush. For each group still in
  # :vacant_flushing: on success drop it; on failure re-queue it so the next
  # flush retries (this is what drains stale router entries). A group that was
  # re-claimed while the batch was in flight is no longer :vacant_flushing
  # (handle_claim moved it straight to :occupied/:occupied_pending), so it falls
  # through the catch-all here — the seq guard already kept the in-flight DELETE
  # from clobbering its fresh :occupied INSERT.
  defp handle_vacant_batch_done(groups, result, state) do
    success? = not match?({:error, _}, result)

    if success? do
      Logger.debug(
        "Muster[#{node()}|#{state.scope}] vacant batch of #{length(groups)} group(s) acknowledged by router"
      )
    else
      Logger.warning(
        "Muster[#{node()}|#{state.scope}] vacant batch RPC failed for #{length(groups)} group(s): #{inspect(result)} — re-queuing"
      )
    end

    Enum.reduce(groups, state, fn group, st ->
      case Map.get(st.group_states, group) do
        :vacant_flushing ->
          if success?,
            do: delete_group_state(st, group),
            else: put_group_state(st, group, :vacant_queued)

        _ ->
          st
      end
    end)
  end

  # Collect every :vacant_queued group, bucket by current router, and send one
  # batched RPC per remote router (self-routed groups are pruned locally). The
  # queued groups stay in :vacant_queued only until a flush moves them to
  # :vacant_flushing; a failed batch returns them to :vacant_queued.
  defp flush_vacant(state) do
    queued = for {group, :vacant_queued} <- state.group_states, do: group

    case queued do
      [] ->
        state

      _ ->
        by_router = Enum.group_by(queued, &router_from_state(state, &1))

        Logger.debug(
          "Muster[#{node()}|#{state.scope}] flushing #{length(queued)} vacant group(s) across #{map_size(by_router)} router(s)"
        )

        by_router
        |> Enum.reduce(state, fn {router_node, groups}, st ->
          if router_node == node() do
            # Self-routed: delete our own rows directly. flush and any re-claim
            # for the same group both run in THIS shard (same group → same
            # shard), so this delete never races a concurrent local re-insert.
            Enum.each(groups, fn g -> :ets.delete(st.occupancy_table, {g, node()}) end)
            Enum.reduce(groups, st, fn g, s -> delete_group_state(s, g) end)
          else
            dispatch_vacant_batch(groups, router_node, st)
            Enum.reduce(groups, st, fn g, s -> put_group_state(s, g, :vacant_flushing) end)
          end
        end)
    end
  end

  ## Rebalance helpers

  # Run during the coordinator's synchronous {:rebalance} gather.
  #
  # :vacant_queued entries are kept as-is (handled by the catch-all): we don't
  # hold the group, so it is not announced, but the next flush after the ring
  # updates sends the vacant to the group's *current* router — which drains any
  # stale entry the old router still holds.
  #
  # :vacant_flushing (a batch RPC in flight) is rewritten to :vacant_queued so
  # the next flush re-sends to the post-rebalance router; the in-flight worker's
  # result lands in handle_vacant_batch_done's catch-all and is dropped.
  defp normalize_pending_for_rebalance(state) do
    Enum.reduce(state.group_states, state, fn
      {group, :vacant_flushing}, st -> put_group_state(st, group, :vacant_queued)
      _, st -> st
    end)
  end

  # Settle every :occupied_pending group whose router changed: reply :ok to the
  # waiters and move to :occupied. Groups whose router did NOT change are left
  # alone — their original in-flight worker is still talking to the correct
  # router, so handle_occupied_done will settle them normally.
  defp settle_moved_pending(state) do
    Enum.reduce(state.group_states, state, fn
      {group, {:occupied_pending, waiters}}, st ->
        if router_changed?(st, group) do
          Enum.each(waiters, fn {from, pid} ->
            register_member(st, group, pid)
            GenServer.reply(from, :ok)
          end)

          put_group_state(st, group, :occupied)
        else
          st
        end

      _, st ->
        st
    end)
  end

  defp router_changed?(state, group) do
    ring = ring_name(state.scope)
    {:ok, new_dest} = Ring.find_node(ring, group)
    {:ok, old_dest} = Ring.find_historical_node(ring, group, 1)
    new_dest != old_dest
  end

  ## RPC dispatch

  defp dispatch_rpc(:occupied, group, router_node, state) do
    spawn_rpc_worker(
      state,
      router_node,
      :occupied,
      [state.scope, group, node(), next_seq()],
      {:occupied_done, group}
    )
  end

  defp dispatch_vacant_batch(groups, router_node, state) do
    spawn_rpc_worker(
      state,
      router_node,
      :vacant_batch,
      [state.scope, groups, node(), next_seq()],
      {:vacant_batch_done, groups}
    )
  end

  # spawn_opt with monitor + tag gives us atomic spawn+monitor and uses the
  # worker's exit reason as the result channel, so any termination surfaces as a
  # single tagged DOWN message. The RPC targets Forum.Muster.Scope on the remote
  # router (occupied/4 and vacant_batch/4 are the router-role entry points there;
  # they write the :public occupancy table directly, bypassing the coordinator
  # mailbox). Mirrors gen_rpc's async_call pattern.
  defp spawn_rpc_worker(state, router_node, function, args, tag) do
    message_module = state.message_module
    scope = state.scope
    rpc_timeout = state.rpc_timeout_ms

    {_pid, _ref} =
      :erlang.spawn_opt(
        fn ->
          result =
            try do
              message_module.call(scope, router_node, Scope, function, args, rpc_timeout)
            catch
              kind, reason -> {:error, {kind, reason}}
            end

          exit({:rpc_result, result})
        end,
        [{:monitor, [{:tag, tag}]}]
      )

    :ok
  end

  defp worker_result({:rpc_result, r}), do: r
  defp worker_result(:noproc), do: {:error, :worker_noproc}
  defp worker_result(other), do: {:error, {:worker_exit, other}}

  ## Misc

  defp schedule_vacant_flush(state) do
    Process.send_after(self(), :flush_vacant, state.vacant_flush_interval_ms)
    :ok
  end

  defp cancel_cooldown(state, group) do
    {timer_ref, new_timers} = Map.pop(state.cooldown_timers, group)
    if timer_ref, do: Process.cancel_timer(timer_ref)
    %{state | cooldown_timers: new_timers}
  end

  # Emits :muster_group_state so trace-based tests can synchronize on per-group
  # state-machine transitions (state: nil = forgotten) instead of polling.
  defp put_group_state(state, group, value) do
    tp(:muster_group_state, %{scope: state.scope, node: node(), group: group, state: value})
    %{state | group_states: Map.put(state.group_states, group, value)}
  end

  defp delete_group_state(state, group) do
    tp(:muster_group_state, %{scope: state.scope, node: node(), group: group, state: nil})
    %{state | group_states: Map.delete(state.group_states, group)}
  end

  defp router_from_state(state, group) do
    {:ok, n} = Ring.find_node(ring_name(state.scope), group)
    n
  end

  # Per-source monotonic occupancy stamp. VM-global and strictly increasing, so
  # it reflects dispatch order on this node and survives restarts. Only ever
  # compared at a router for the same {group, source} key, all of whose writes
  # originate on this node — so the comparison is always within one VM's
  # sequence. See the occupancy-row versioning note above Scope.occupied/4.
  defp next_seq, do: :erlang.unique_integer([:monotonic])

  defp ring_name(scope), do: :"#{scope}_muster_ring"
end
