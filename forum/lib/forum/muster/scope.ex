defmodule Forum.Muster.Scope do
  @moduledoc false
  # Per-node coordinator for Forum.Muster.
  #
  # Owns:
  #   * Cluster view (sorted node list) via persistent_term.
  #   * Per-group state machine for the "have I told the router about
  #     this group?" question. RPCs are dispatched to short-lived worker
  #     processes so the Scope mailbox stays responsive.
  #   * Router-role occupancy table — when this node is the router
  #     for a group, the set of source nodes that hold it.
  #   * Cooldown bookkeeping for the "recently vacant" suppression.
  #   * A queue of vacated groups (group_state :vacant_queued) flushed
  #     periodically in per-router batches. A failed batch re-queues its
  #     groups, so the flush doubles as a self-draining retry that keeps the
  #     router's occupancy table from accumulating stale entries.
  use GenServer
  require Logger

  alias ExHashRing.Ring

  @default_vacancy_cooldown_ms 30_000
  @default_vacant_flush_interval_ms 5_000
  @default_rpc_timeout_ms 5_000
  @default_view_heartbeat_interval_ms 10_000
  @default_ring_replicas 128
  @ring_depth 2

  defmodule State do
    @moduledoc false
    @type group_state ::
            :occupied
            | :cooldown
            | :vacant_queued
            | {:occupied_pending, [GenServer.from()]}
            | {:vacant_flushing, [GenServer.from()]}

    @type t :: %__MODULE__{
            scope: atom,
            message_module: module,
            vacancy_cooldown_ms: non_neg_integer,
            vacant_flush_interval_ms: pos_integer,
            view_heartbeat_interval_ms: pos_integer,
            rpc_timeout_ms: timeout,
            recently_vacant_table: atom,
            occupancy_table: atom,
            members: [node],
            peers: %{pid => reference},
            cooldown_timers: %{Forum.group() => reference},
            group_states: %{Forum.group() => group_state},
            member_views: %{node => non_neg_integer},
            telemetry_handler_id: term
          }
    defstruct [
      :scope,
      :message_module,
      :vacancy_cooldown_ms,
      :vacant_flush_interval_ms,
      :view_heartbeat_interval_ms,
      :rpc_timeout_ms,
      :recently_vacant_table,
      :occupancy_table,
      :telemetry_handler_id,
      members: [],
      peers: %{},
      cooldown_timers: %{},
      group_states: %{},
      # Barrier bookkeeping: each peer's most-recently-announced cluster-view
      # hash (via a :rebalance_marker, or seeded on the discovery handshake).
      # Latest-wins, never reset — so an announcement that arrives before we
      # adopt that view is retained, not discarded. We are "ready" — and our
      # occupancy table can be trusted as a router — once every member's
      # latest view agrees with ours.
      member_views: %{}
    ]
  end

  ## Public helpers (read paths used by Forum.Muster from the caller's process)

  @doc "Returns the list of nodes (as known by the local router state) holding `group`."
  @spec occupancy(atom, Forum.group()) :: [node]
  def occupancy(scope, group) do
    :ets.select(occupancy_table_name(scope), [{{{group, :"$1"}}, [], [:"$1"]}])
  end

  ## Remote entry points
  #
  # These are invoked on the *router* / receiver node by remote nodes
  # via the configured Forum.Adapter (default: :erpc.call). They run inside
  # whatever process the adapter spawns to handle the RPC — typically an
  # :erpc worker — and write directly to the :public occupancy_table.
  #
  # Bypassing Scope's mailbox here means a busy router can absorb many
  # concurrent updates from many source nodes in parallel. Correctness is
  # preserved because each occupancy key is {group, source_node}: different
  # sources own disjoint keys, and the source's own Scope serializes
  # :occupied vs. :vacant_batch per group.

  @doc "Remote: source_node tells us it now holds local members of `group`."
  @spec occupied(atom, Forum.group(), node) :: :ok
  def occupied(scope, group, source_node) do
    :ets.insert(occupancy_table_name(scope), {{group, source_node}})
    :ok
  end

  @doc "Remote: source_node tells us its last local members of `groups` left."
  @spec vacant_batch(atom, [Forum.group()], node) :: :ok
  def vacant_batch(scope, groups, source_node) do
    table = occupancy_table_name(scope)
    Enum.each(groups, fn group -> :ets.delete(table, {group, source_node}) end)
    :ok
  end

  @doc """
  Remote: source_node gives us a full-state snapshot of its groups for the
  cluster view identified by `view_hash`.

  The snapshot doubles as source_node's rebalance marker for that view: after
  committing the occupancy data we notify the local Scope so its readiness
  barrier counts this source. Because the data is written to ETS *before* the
  marker is sent, a router that later observes `:ready` has this source's
  occupancy in place. We run in the adapter's RPC worker (not in Scope), so the
  marker is sent to Scope by its registered name.
  """
  @spec receive_node_state(atom, node, [Forum.group()], non_neg_integer) :: :ok
  def receive_node_state(scope, source_node, groups, view_hash) do
    table = occupancy_table_name(scope)
    # match_delete + inserts are not atomic with respect to readers; a
    # concurrent :fanout_request scan during this window could miss some
    # groups for this source. Muster broadcasts are best-effort, so a single
    # missed delivery is acceptable. Subsequent broadcasts use the fresh
    # state.
    :ets.match_delete(table, {{:_, source_node}})
    Enum.each(groups, fn group -> :ets.insert(table, {{group, source_node}}) end)
    Kernel.send(Forum.Supervisor.name(scope), {:rebalance_marker, source_node, view_hash})
    :ok
  end

  ## GenServer lifecycle

  @spec start_link(atom, Keyword.t()) :: GenServer.on_start()
  def start_link(scope, opts \\ []), do: GenServer.start_link(__MODULE__, [scope, opts])

  @impl true
  def init([scope, opts]) do
    vacancy_cooldown_ms = Keyword.get(opts, :vacancy_cooldown_ms, @default_vacancy_cooldown_ms)

    vacant_flush_interval_ms =
      Keyword.get(opts, :vacant_flush_interval_ms, @default_vacant_flush_interval_ms)

    view_heartbeat_interval_ms =
      Keyword.get(opts, :view_heartbeat_interval_ms, @default_view_heartbeat_interval_ms)

    rpc_timeout_ms = Keyword.get(opts, :rpc_timeout_ms, @default_rpc_timeout_ms)
    message_module = Keyword.get(opts, :message_module, Forum.Adapter.ErlDist)

    if not (is_integer(vacancy_cooldown_ms) and vacancy_cooldown_ms >= 0) do
      raise ArgumentError,
            "expected :vacancy_cooldown_ms to be a non-negative integer, got: #{inspect(vacancy_cooldown_ms)}"
    end

    if not (is_integer(vacant_flush_interval_ms) and vacant_flush_interval_ms > 0) do
      raise ArgumentError,
            "expected :vacant_flush_interval_ms to be a positive integer, got: #{inspect(vacant_flush_interval_ms)}"
    end

    if not (is_integer(view_heartbeat_interval_ms) and view_heartbeat_interval_ms > 0) do
      raise ArgumentError,
            "expected :view_heartbeat_interval_ms to be a positive integer, got: #{inspect(view_heartbeat_interval_ms)}"
    end

    :ok = :net_kernel.monitor_nodes(true)

    recently_vacant_table =
      :ets.new(recently_vacant_table_name(scope), [
        :set,
        :protected,
        :named_table,
        read_concurrency: true
      ])

    # :public so :erpc workers running our remote entry points
    # (occupied/3, vacant_batch/3, receive_node_state/3) can write directly,
    # bypassing Scope's mailbox. write_concurrency: true makes those
    # concurrent writes scale across schedulers.
    occupancy_table =
      :ets.new(occupancy_table_name(scope), [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

    :ok = message_module.register(scope)

    # Linked ring process; lives and dies with this Scope.
    {:ok, _ring_pid} =
      Ring.start_link(
        name: ring_name(scope),
        depth: @ring_depth,
        replicas: @default_ring_replicas
      )

    {:ok, _} = Ring.set_nodes(ring_name(scope), [node()])

    # Lifecycle tri-state: :rebalancing (my ring is in flux — senders flood) →
    # :converging (ring adopted, still waiting for peers to agree on my view) →
    # :ready (all peers agree; my occupancy table can be trusted as a router).
    # A single-node cluster has no peers to hear from, so it starts :ready.
    :persistent_term.put({Forum.Muster, scope, :status}, :ready)
    # Cluster-view hash senders tag broadcasts with; router compares against its own.
    :persistent_term.put({Forum.Muster, scope, :view_hash}, :erlang.phash2([node()]))

    telemetry_handler_id = {__MODULE__, scope, self()}

    :ok =
      :telemetry.attach(
        telemetry_handler_id,
        [:forum, scope, :group, :vacant],
        &__MODULE__.handle_vacant_telemetry/4,
        %{scope_pid: self()}
      )

    Logger.info("Muster[#{node()}|#{scope}] Starting")

    state = %State{
      scope: scope,
      message_module: message_module,
      vacancy_cooldown_ms: vacancy_cooldown_ms,
      vacant_flush_interval_ms: vacant_flush_interval_ms,
      view_heartbeat_interval_ms: view_heartbeat_interval_ms,
      rpc_timeout_ms: rpc_timeout_ms,
      recently_vacant_table: recently_vacant_table,
      occupancy_table: occupancy_table,
      telemetry_handler_id: telemetry_handler_id,
      members: [node()]
    }

    state = reannounce_local_groups_at_init(state)

    {:ok, state, {:continue, :discover}}
  end

  @impl true
  def handle_continue(:discover, state) do
    state.message_module.broadcast(state.scope, {:muster_discover, self(), own_view_hash(state)})
    schedule_vacant_flush(state)
    schedule_view_heartbeat(state)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.telemetry_handler_id do
      _ = :telemetry.detach(state.telemetry_handler_id)
    end

    :ok
  end

  ## handle_call

  # Local source — Muster.join asking us to claim this group on the router.
  # Remote occupancy updates (:occupied, :vacant_batch, :receive_node_state)
  # write directly to the :public occupancy_table from their :erpc worker —
  # they no longer bounce through this mailbox. See the "Remote entry points"
  # section above.
  @impl true
  def handle_call({:claim, group}, from, state) do
    handle_claim(group, from, state)
  end

  # For tests / introspection
  def handle_call(:status, _from, state) do
    reply = %{
      members: state.members,
      peers: Map.keys(state.peers) |> Enum.map(&node/1),
      group_states: state.group_states,
      cooldown: :ets.tab2list(state.recently_vacant_table) |> Enum.map(&elem(&1, 0))
    }

    {:reply, reply, state}
  end

  ## handle_info

  # Peer discovery (the receiver of a discover replies with an ack and registers the peer).
  # The handshake piggybacks each side's current view hash so member_views is
  # seeded immediately — important after a Scope restart, where it would
  # otherwise be empty until the next membership change.
  @impl true
  def handle_info({:muster_discover, peer, view_hash}, %State{} = state) do
    state.message_module.send(
      state.scope,
      node(peer),
      {:muster_discover_ack, self(), own_view_hash(state)}
    )

    state = put_member_view(state, node(peer), view_hash)
    {:noreply, register_peer(state, peer)}
  end

  def handle_info({:muster_discover_ack, peer, view_hash}, %State{} = state) do
    state = put_member_view(state, node(peer), view_hash)
    {:noreply, register_peer(state, peer)}
  end

  # A new node connected. Reach out so they can pair.
  def handle_info({:nodeup, node}, state) when node == node(), do: {:noreply, state}

  def handle_info({:nodeup, node}, state) do
    :telemetry.execute([:forum, state.scope, :node, :up], %{}, %{node: node})
    state.message_module.send(state.scope, node, {:muster_discover, self(), own_view_hash(state)})
    {:noreply, state}
  end

  # Net split / disconnect — wait for the peer's monitor DOWN.
  def handle_info({:nodedown, _node}, state), do: {:noreply, state}

  # A peer announced the cluster view it has finished rebalancing into. Record
  # it as that peer's latest view (latest-wins). We do NOT gate on it matching
  # our current view: storing it means an announcement that arrives before we
  # adopt that view is retained, so once we catch up the agreement check in
  # ready?/1 sees it. Readiness is then "every member's latest view == ours".
  def handle_info({:rebalance_marker, source, view_hash}, %State{} = state) do
    {:noreply, update_status(put_member_view(state, source, view_hash))}
  end

  # Peer scope crashed/disconnected — drop occupancy entries owned by that node
  # and rebalance.
  def handle_info({:DOWN, ref, :process, pid, _reason}, %State{} = state) do
    case Map.pop(state.peers, pid) do
      {^ref, new_peers} ->
        :ets.match_delete(state.occupancy_table, {{:_, node(pid)}})
        :telemetry.execute([:forum, state.scope, :node, :down], %{}, %{node: node(pid)})

        state = %{state | peers: new_peers}
        {:noreply, recompute_members(state)}

      _ ->
        {:noreply, state}
    end
  end

  # Telemetry handler delivers this when the last local member of `group` leaves.
  def handle_info({:local_vacant, group}, state) do
    handle_local_vacant(group, state)
  end

  # Cooldown timer fired for `group`.
  def handle_info({:vacancy_expired, group}, state) do
    handle_vacancy_expired(group, state)
  end

  # Worker reported back the result of a claim (:occupied) RPC.
  #
  # The worker process is spawned via `spawn_opt(fn -> exit({:rpc_result, r}) end,
  # [{:monitor, [{:tag, {:occupied_done, group}}]}])`. Whatever termination path the
  # worker takes — normal exit with the result, raise, hard kill, OOM — we get
  # exactly one tagged DOWN with the exit reason.
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

  # Periodic re-announce of our current view to every member. The event-driven
  # path (rebalance announcements + the discovery handshake) normally converges
  # member_views in milliseconds; this heartbeat is the backstop that heals a
  # dropped announcement without needing a membership change, bounding the
  # worst-case "stuck flooding as a router" window to one interval. Idempotent
  # with member_views (latest-wins), so a redundant heartbeat is harmless.
  def handle_info(:view_heartbeat, state) do
    announce_view(state)
    schedule_view_heartbeat(state)
    {:noreply, state}
  end

  # Test-only — drives the rebalance path with a synthetic members list.
  # Locally-spawned pids can't masquerade as remote peers (`node/1` returns
  # the local node), so triggering rebalance through the normal discovery
  # path with a fake remote isn't possible in single-node tests. This hook
  # is the unlock.
  def handle_info({:__rebalance_for_test, new_members}, state) when is_list(new_members) do
    new_members_sorted = Enum.sort(new_members)
    state = do_rebalance(state, new_members_sorted)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Telemetry handler

  @doc false
  def handle_vacant_telemetry(_event, _measurements, %{group: group}, %{scope_pid: pid}) do
    Kernel.send(pid, {:local_vacant, group})
  end

  ## State machine — claim

  defp handle_claim(group, from, state) do
    case Map.get(state.group_states, group) do
      nil ->
        router_node = router_from_state(state, group)

        if router_node == node() do
          :ets.insert(state.occupancy_table, {{group, node()}})
          {:reply, :ok, put_group_state(state, group, :occupied)}
        else
          dispatch_rpc(:occupied, group, router_node, state)
          {:noreply, put_group_state(state, group, {:occupied_pending, [from]})}
        end

      :occupied ->
        {:reply, :ok, state}

      :cooldown ->
        state = cancel_cooldown(state, group)
        {:reply, :ok, put_group_state(state, group, :occupied)}

      {:occupied_pending, waiters} ->
        {:noreply, put_group_state(state, group, {:occupied_pending, [from | waiters]})}

      :vacant_queued ->
        # Queued for a vacant flush but nothing is in flight yet. Reclaim now,
        # with no risk of racing a vacant RPC against this :occupied.
        router_node = router_from_state(state, group)

        if router_node == node() do
          :ets.insert(state.occupancy_table, {{group, node()}})
          {:reply, :ok, put_group_state(state, group, :occupied)}
        else
          dispatch_rpc(:occupied, group, router_node, state)
          {:noreply, put_group_state(state, group, {:occupied_pending, [from]})}
        end

      {:vacant_flushing, waiters} ->
        # A batch vacant RPC covering this group is in flight. Park the caller;
        # handle_vacant_batch_done re-claims the group once the batch settles.
        {:noreply, put_group_state(state, group, {:vacant_flushing, [from | waiters]})}
    end
  end

  defp handle_local_vacant(group, state) do
    case Map.get(state.group_states, group) do
      :occupied ->
        :ets.insert(state.recently_vacant_table, {group})
        ref = Process.send_after(self(), {:vacancy_expired, group}, state.vacancy_cooldown_ms)

        state = %{
          state
          | cooldown_timers: Map.put(state.cooldown_timers, group, ref)
        }

        {:noreply, put_group_state(state, group, :cooldown)}

      _ ->
        # Vacancy telemetry can arrive when group_states is something other than
        # :occupied after a Scope restart (the partition still has entries but
        # we have not finished re-announcing) or during transient states.
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
        :ets.delete(state.recently_vacant_table, group)

        if count > 0 do
          # FIXME This should not happen. We should probably raise
          # Defensive — a claim should have moved us out of :cooldown already.
          {:noreply, put_group_state(state, group, :occupied)}
        else
          # Cooldown elapsed and still empty. Queue the vacancy; the periodic
          # flush groups all queued vacancies by current router, sends one
          # batched RPC per router, and re-queues any that fail.
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
            Enum.each(waiters, fn from -> GenServer.reply(from, :ok) end)
            {:noreply, put_group_state(state, group, :occupied)}

          _ ->
            Enum.each(waiters, fn from -> GenServer.reply(from, {:error, :rpc_failed}) end)
            {:noreply, delete_group_state(state, group)}
        end

      _ ->
        # Out-of-band — e.g., state was reset by rebalance crash. Drop.
        {:noreply, state}
    end
  end

  # Result of one batched :vacant flush. For each group still in
  # :vacant_flushing: on success drop it; on failure re-queue it so the next
  # flush retries (this is what drains stale router entries). If claims
  # arrived during the batch (waiters present), re-claim the group regardless
  # of the vacant result — we hold local members again.
  defp handle_vacant_batch_done(groups, result, state) do
    success? = not match?({:error, _}, result)

    if not success? do
      Logger.warning(
        "Muster[#{node()}|#{state.scope}] vacant batch RPC failed for #{length(groups)} group(s): #{inspect(result)} — re-queuing"
      )
    end

    Enum.reduce(groups, state, fn group, st ->
      case Map.get(st.group_states, group) do
        {:vacant_flushing, []} ->
          if success?,
            do: delete_group_state(st, group),
            else: put_group_state(st, group, :vacant_queued)

        {:vacant_flushing, waiters} ->
          router_node = router_from_state(st, group)

          if router_node == node() do
            :ets.insert(st.occupancy_table, {{group, node()}})
            Enum.each(waiters, fn from -> GenServer.reply(from, :ok) end)
            put_group_state(st, group, :occupied)
          else
            dispatch_rpc(:occupied, group, router_node, st)
            put_group_state(st, group, {:occupied_pending, waiters})
          end

        _ ->
          # Out-of-band (rebalance moved this group out of :vacant_flushing). Drop.
          st
      end
    end)
  end

  # Collect every :vacant_queued group, bucket by current router, and send
  # one batched RPC per remote router (self-routed groups are pruned
  # locally). The queued groups stay in :vacant_queued only until a flush moves
  # them to :vacant_flushing; a failed batch returns them to :vacant_queued.
  defp flush_vacant(state) do
    queued = for {group, :vacant_queued} <- state.group_states, do: group

    case queued do
      [] ->
        state

      _ ->
        queued
        |> Enum.group_by(&router_from_state(state, &1))
        |> Enum.reduce(state, fn {router_node, groups}, st ->
          if router_node == node() do
            Enum.each(groups, fn g -> :ets.delete(st.occupancy_table, {g, node()}) end)
            Enum.reduce(groups, st, fn g, s -> delete_group_state(s, g) end)
          else
            dispatch_vacant_batch(groups, router_node, st)
            Enum.reduce(groups, st, fn g, s -> put_group_state(s, g, {:vacant_flushing, []}) end)
          end
        end)
    end
  end

  defp dispatch_rpc(:occupied, group, router_node, state) do
    spawn_rpc_worker(
      state,
      router_node,
      :occupied,
      [state.scope, group, node()],
      {:occupied_done, group}
    )
  end

  defp dispatch_vacant_batch(groups, router_node, state) do
    spawn_rpc_worker(
      state,
      router_node,
      :vacant_batch,
      [state.scope, groups, node()],
      {:vacant_batch_done, groups}
    )
  end

  # spawn_opt with monitor + tag gives us:
  #   (a) atomic spawn+monitor — no race where a fast worker exits before
  #       we install the monitor (a plain Process.monitor/2 after spawn
  #       would see :noproc and lose the real exit reason).
  #   (b) the worker uses its exit reason as the result channel, so any
  #       termination — clean return, raise, hard kill, OOM — surfaces
  #       as a single tagged DOWN message Scope is guaranteed to receive.
  #
  # This mirrors gen_rpc's async_call pattern.
  defp spawn_rpc_worker(state, router_node, function, args, tag) do
    message_module = state.message_module
    scope = state.scope
    rpc_timeout = state.rpc_timeout_ms

    {_pid, _ref} =
      :erlang.spawn_opt(
        fn ->
          result =
            try do
              message_module.call(scope, router_node, __MODULE__, function, args, rpc_timeout)
            catch
              kind, reason -> {:error, {kind, reason}}
            end

          exit({:rpc_result, result})
        end,
        [{:monitor, [{:tag, tag}]}]
      )

    :ok
  end

  # Decode a worker's monitor DOWN exit reason into an RPC result.
  defp worker_result({:rpc_result, r}), do: r
  defp worker_result(:noproc), do: {:error, :worker_noproc}
  defp worker_result(other), do: {:error, {:worker_exit, other}}

  defp schedule_vacant_flush(state) do
    Process.send_after(self(), :flush_vacant, state.vacant_flush_interval_ms)
    :ok
  end

  defp schedule_view_heartbeat(state) do
    Process.send_after(self(), :view_heartbeat, state.view_heartbeat_interval_ms)
    :ok
  end

  # Re-announce our current view to every other member (latest-wins on their
  # side). Sent even when we're already :ready, because a peer may be the one
  # missing our announcement.
  defp announce_view(state) do
    view_hash = own_view_hash(state)

    Enum.each(state.members, fn member ->
      if member != node() do
        state.message_module.send(state.scope, member, {:rebalance_marker, node(), view_hash})
      end
    end)

    :ok
  end

  defp cancel_cooldown(state, group) do
    {timer_ref, new_timers} = Map.pop(state.cooldown_timers, group)
    if timer_ref, do: Process.cancel_timer(timer_ref)
    :ets.delete(state.recently_vacant_table, group)
    %{state | cooldown_timers: new_timers}
  end

  defp put_group_state(state, group, value) do
    %{state | group_states: Map.put(state.group_states, group, value)}
  end

  defp delete_group_state(state, group) do
    %{state | group_states: Map.delete(state.group_states, group)}
  end

  defp router_from_state(state, group) do
    {:ok, n} = Ring.find_node(ring_name(state.scope), group)
    n
  end

  ## Peer/membership

  defp register_peer(state, peer) when is_pid(peer) do
    cond do
      node(peer) == node() ->
        # Ignore self-discovery (loopback from our own broadcast).
        state

      Map.has_key?(state.peers, peer) ->
        state

      true ->
        ref = Process.monitor(peer)
        peers = Map.put(state.peers, peer, ref)
        recompute_members(%{state | peers: peers})
    end
  end

  defp recompute_members(state) do
    new_members =
      [node() | Enum.map(Map.keys(state.peers), &node/1)]
      |> Enum.uniq()
      |> Enum.sort()

    if new_members == state.members do
      state
    else
      do_rebalance(state, new_members)
    end
  end

  ## Rebalance

  defp do_rebalance(state, new_members) do
    ring = ring_name(state.scope)

    # 1) Flip status to :rebalancing BEFORE updating the ring. Callers reading
    #    router/2 see :rebalancing and fan out to all members. During the
    #    window, get_nodes/1 returns the current ring (still old generation
    #    until set_nodes returns), which is also fine — fan-out to either
    #    member set is safe.
    # :rebalancing means our ring is in flux; senders fan out to all members
    # until we settle. Bump the cluster-view hash too. member_views is NOT
    # reset — peers' already-announced views (possibly for this very view, if
    # they got here first) stay and are re-evaluated against the new hash by
    # update_status at the end.
    :persistent_term.put({Forum.Muster, state.scope, :status}, :rebalancing)
    :persistent_term.put({Forum.Muster, state.scope, :view_hash}, :erlang.phash2(new_members))

    # 2) Normalize in-flight pending states (see normalize_pending_for_rebalance):
    #    in-flight vacant batches fall back to :vacant_queued (or :occupied_pending
    #    if claims arrived); plain :vacant_queued is left alone and re-routed by
    #    the next flush.
    state = normalize_pending_for_rebalance(state)

    # 3) Atomically replace the node set; this bumps the ring's generation.
    #    After this call: find_node = NEW routers; find_historical_node
    #    (back: 1) = OLD routers.
    {:ok, _} = Ring.set_nodes(ring, new_members)

    # 4) Announce-set. Candidates are groups we hold: :occupied, :cooldown, or
    #    :occupied_pending. :cooldown groups must be included even though the
    #    Partition count is 0, because the old router still believes we hold
    #    them and the new router needs to know to expect a future :vacant.
    #    :occupied_pending must be included so callers parked on Scope's
    #    GenServer.call get :ok once the new router has been told — instead of
    #    being cancelled with :rebalance_in_progress.
    candidates =
      for {group, gs} <- state.group_states,
          gs in [:occupied, :cooldown] or match?({:occupied_pending, _}, gs),
          do: group

    new_router =
      Map.new(candidates, fn group ->
        {:ok, n} = Ring.find_node(ring, group)
        {group, n}
      end)

    # Groups whose router actually changed. Used to settle parked claims, and
    # to decide which routers need a refreshed snapshot at all.
    groups_to_reannounce =
      Enum.filter(candidates, fn group ->
        {:ok, old_dest} = Ring.find_historical_node(ring, group, 1)
        Map.fetch!(new_router, group) != old_dest
      end)

    # Routers that gained at least one moved group. Each gets a FULL snapshot
    # of every group we hold routed to it — not just the moved ones — because
    # receive_node_state wipes all of this source's rows before inserting.
    # Sending only the moved groups would drop unchanged groups that still
    # route there (the entry would never be re-added until natural churn).
    # Routers with no moved group are left untouched: their existing rows for
    # us are still correct, and any group that moved *away* from them is
    # cleared by their own drop_stale_router_entries.
    changed_routers =
      groups_to_reannounce |> Enum.map(&Map.fetch!(new_router, &1)) |> MapSet.new()

    by_router =
      candidates
      |> Enum.group_by(&Map.fetch!(new_router, &1))
      |> Map.take(MapSet.to_list(changed_routers))

    # Local self-target: synchronous ETS inserts in the Scope process.
    # Remote targets: one Task per destination, awaited in parallel so the
    # rebalance window is bounded by ~RTT rather than N × RTT. Tasks link to
    # Scope, so an uncaught raise inside any closure crashes Scope just like
    # a sequential raise would have.
    {local_groups, remote_targets} =
      Enum.split_with(by_router, fn {dest, _} -> dest == node() end)

    Enum.each(local_groups, fn {_, groups} ->
      Enum.each(groups, fn group ->
        :ets.insert(state.occupancy_table, {{group, node()}})
      end)
    end)

    message_module = state.message_module
    scope = state.scope
    rpc_timeout = state.rpc_timeout_ms
    view_hash = :erlang.phash2(new_members)

    tasks =
      Enum.map(remote_targets, fn {router_node, groups} ->
        task =
          Task.async(fn ->
            message_module.call(
              scope,
              router_node,
              __MODULE__,
              :receive_node_state,
              [scope, node(), groups, view_hash],
              rpc_timeout
            )
          end)

        {router_node, task}
      end)

    # Each remote call is already bounded by `rpc_timeout` inside the
    # adapter; add 1s of slack here so a hung Task surfaces via Task.await
    # rather than hanging Scope indefinitely.
    await_timeout = rpc_timeout + 1_000

    Enum.each(tasks, fn {router_node, task} ->
      case Task.await(task, await_timeout) do
        :ok ->
          :ok

        other ->
          raise "Muster rebalance failed: target=#{inspect(router_node)} result=#{inspect(other)}"
      end
    end)

    # Marker hybrid: members that received a data snapshot are marked by the
    # receive_node_state RPC itself (it carries view_hash and notifies the
    # receiver's Scope) — no separate signal, no double-contact. Every other
    # member has nothing to fold a marker into, so it gets a cheap async marker
    # instead; that is how its barrier learns "this source holds nothing for
    # me" rather than "this source has not arrived yet". Self never needs one.
    snapshot_targets = Enum.map(remote_targets, fn {router_node, _} -> router_node end)

    Enum.each(new_members -- [node() | snapshot_targets], fn member ->
      message_module.send(scope, member, {:rebalance_marker, node(), view_hash})
    end)

    # 5) Settle :occupied_pending claims whose router changed. The
    #    rebalance just informed the new router via :receive_node_state,
    #    so the parked callers can be unblocked with :ok. Their original
    #    workers (targeting the old router) may still complete later;
    #    the resulting :occupied_done lands in handle_occupied_done's _other
    #    clause and is dropped because group_states[group] will be :occupied by
    #    then.
    state = settle_pending_after_rebalance(state, MapSet.new(groups_to_reannounce))

    drop_stale_router_entries(state)

    state = %{state | members: new_members}

    # 6) Leave :rebalancing for :ready or :converging based on peer agreement.
    #    A single-node cluster has no peers to hear from, so it lands on :ready
    #    immediately; a multi-node cluster stays :converging until peer
    #    announcements arrive (handle_info({:rebalance_marker, ...})). If
    #    rebalance raised above we skip this and supervisor restart
    #    re-initializes :status — until then callers observing :rebalancing fan
    #    out to every member, which is safe.
    update_status(state)
  end

  # Recompute the lifecycle status from member_views vs. current membership and
  # publish it (only when it actually changes, to avoid redundant
  # persistent_term writes during a burst of announcements). Only ever sets
  # :ready or :converging — :rebalancing is owned by do_rebalance.
  defp update_status(state) do
    status = if ready?(state), do: :ready, else: :converging
    key = {Forum.Muster, state.scope, :status}
    if :persistent_term.get(key, nil) != status, do: :persistent_term.put(key, status)
    state
  end

  # Ready once every member (other than ourselves) has announced a view that
  # agrees with ours. A member with no entry yet, or one whose latest view
  # differs, keeps us not-ready — the safe direction (the router floods).
  defp ready?(state) do
    own = own_view_hash(state)

    Enum.all?(state.members, fn member ->
      member == node() or Map.get(state.member_views, member) == own
    end)
  end

  defp own_view_hash(state), do: :erlang.phash2(state.members)

  defp put_member_view(state, source, view_hash) do
    %{state | member_views: Map.put(state.member_views, source, view_hash)}
  end

  defp drop_stale_router_entries(state) do
    ring = ring_name(state.scope)

    state.occupancy_table
    |> :ets.select([{{{:"$1", :"$2"}}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.each(fn {group, n} ->
      {:ok, current} = Ring.find_node(ring, group)

      if current != node() do
        :ets.delete(state.occupancy_table, {group, n})
      end
    end)
  end

  defp local_groups(state) do
    state.scope
    |> Forum.Supervisor.partitions()
    |> Enum.flat_map(&Forum.Partition.groups/1)
  end

  # Run at the start of rebalance.
  #
  # :vacant_queued entries are kept as-is (handled by the catch-all): we don't
  # hold the group, so it is not announced via :receive_node_state, but the
  # next flush after the ring updates will send the vacant to the group's
  # *current* router — which drains any stale entry the old router
  # still holds.
  #
  # {:vacant_flushing, []} (a batch RPC in flight, no waiters) is rewritten to
  # :vacant_queued so the next flush re-sends to the post-rebalance router;
  # the in-flight worker's result lands in handle_vacant_batch_done's catch-all
  # and is dropped.
  #
  # {:vacant_flushing, waiters} (a claim arrived while the batch was in flight)
  # is rewritten to :occupied_pending so the rebalance announces + settles it
  # like any other pending claim — we hold local members again.
  defp normalize_pending_for_rebalance(state) do
    Enum.reduce(state.group_states, state, fn
      {group, {:vacant_flushing, []}}, st ->
        put_group_state(st, group, :vacant_queued)

      {group, {:vacant_flushing, waiters}}, st ->
        put_group_state(st, group, {:occupied_pending, waiters})

      _, st ->
        st
    end)
  end

  # Run at the end of rebalance, once :receive_node_state RPCs have informed
  # the new router about every group whose router changed. For each
  # :occupied_pending entry in that settled set, reply :ok to the waiters
  # and transition to :occupied. Entries not in the settled set are left
  # alone — their router did not change, so the original in-flight
  # worker is still talking to the correct router.
  defp settle_pending_after_rebalance(state, settled_groups) do
    Enum.reduce(state.group_states, state, fn
      {group, {:occupied_pending, waiters}}, st ->
        if MapSet.member?(settled_groups, group) do
          Enum.each(waiters, fn from -> GenServer.reply(from, :ok) end)
          put_group_state(st, group, :occupied)
        else
          st
        end

      _, st ->
        st
    end)
  end

  defp reannounce_local_groups_at_init(state) do
    # At init, members is just [node()], so the router for every group is
    # ourselves. Walk the partitions (which may have entries left over from a
    # previous incarnation of Scope) and mark them :occupied locally.
    Enum.reduce(local_groups(state), state, fn group, st ->
      :ets.insert(st.occupancy_table, {{group, node()}})
      put_group_state(st, group, :occupied)
    end)
  end

  ## Names

  defp recently_vacant_table_name(scope), do: :"#{scope}_muster_recently_vacant"
  defp occupancy_table_name(scope), do: :"#{scope}_muster_occupancy"
  defp ring_name(scope), do: :"#{scope}_muster_ring"
end
