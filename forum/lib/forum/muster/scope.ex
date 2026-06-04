defmodule Forum.Muster.Scope do
  @moduledoc false
  # Per-node coordinator for Forum.Muster.
  #
  # Owns:
  #   * Cluster view (sorted node list) via persistent_term.
  #   * Per-group state machine for the "have I told the designated about
  #     this group?" question. RPCs are dispatched to short-lived worker
  #     processes so the Scope mailbox stays responsive.
  #   * Designated-role occupancy table — when this node is designated
  #     for a group, the set of source nodes that hold it.
  #   * Cooldown bookkeeping for the "recently vacant" suppression.
  use GenServer
  require Logger

  alias ExHashRing.Ring

  @default_vacancy_cooldown_ms 30_000
  @default_rpc_timeout_ms 5_000
  @default_ring_replicas 128
  @ring_depth 2

  defmodule State do
    @moduledoc false
    @type group_state ::
            :occupied
            | :cooldown
            | {:occupied_pending, [GenServer.from()]}
            | {:vacant_pending, [GenServer.from()]}

    @type t :: %__MODULE__{
            scope: atom,
            message_module: module,
            vacancy_cooldown_ms: non_neg_integer,
            rpc_timeout_ms: timeout,
            recently_vacant_table: atom,
            occupancy_table: atom,
            members: [node],
            peers: %{pid => reference},
            cooldown_timers: %{Forum.group() => reference},
            group_states: %{Forum.group() => group_state},
            telemetry_handler_id: term
          }
    defstruct [
      :scope,
      :message_module,
      :vacancy_cooldown_ms,
      :rpc_timeout_ms,
      :recently_vacant_table,
      :occupancy_table,
      :telemetry_handler_id,
      members: [],
      peers: %{},
      cooldown_timers: %{},
      group_states: %{}
    ]
  end

  ## Public helpers (read paths used by Forum.Muster from the caller's process)

  @doc "Returns the list of nodes (as known by the local designated state) holding `group`."
  @spec occupancy(atom, Forum.group()) :: [node]
  def occupancy(scope, group) do
    :ets.select(occupancy_table_name(scope), [{{{group, :"$1"}}, [], [:"$1"]}])
  end

  ## Remote entry points
  #
  # These are invoked on the *designated* / receiver node by remote nodes
  # via the configured Forum.Adapter (default: :erpc.call). They run inside
  # whatever process the adapter spawns to handle the RPC — typically an
  # :erpc worker — and write directly to the :public occupancy_table.
  #
  # Bypassing Scope's mailbox here means a busy designated can absorb many
  # concurrent updates from many source nodes in parallel. Correctness is
  # preserved because each occupancy key is {group, source_node}: different
  # sources own disjoint keys, and the source's own Scope serializes
  # :occupied/:vacant per group.

  @doc "Remote: source_node tells us it now holds local members of `group`."
  @spec occupied(atom, Forum.group(), node) :: :ok
  def occupied(scope, group, source_node) do
    :ets.insert(occupancy_table_name(scope), {{group, source_node}})
    :ok
  end

  @doc "Remote: source_node tells us its last local member of `group` left."
  @spec vacant(atom, Forum.group(), node) :: :ok
  def vacant(scope, group, source_node) do
    :ets.delete(occupancy_table_name(scope), {group, source_node})
    :ok
  end

  @doc "Remote: source_node gives us a full-state snapshot of its groups."
  @spec receive_node_state(atom, node, [Forum.group()]) :: :ok
  def receive_node_state(scope, source_node, groups) do
    table = occupancy_table_name(scope)
    # match_delete + inserts are not atomic with respect to readers; a
    # concurrent :fanout_request scan during this window could miss some
    # groups for this source. Muster broadcasts are best-effort, so a single
    # missed delivery is acceptable. Subsequent broadcasts use the fresh
    # state.
    :ets.match_delete(table, {{:_, source_node}})
    Enum.each(groups, fn group -> :ets.insert(table, {{group, source_node}}) end)
    :ok
  end

  ## GenServer lifecycle

  @spec start_link(atom, Keyword.t()) :: GenServer.on_start()
  def start_link(scope, opts \\ []), do: GenServer.start_link(__MODULE__, [scope, opts])

  @impl true
  def init([scope, opts]) do
    vacancy_cooldown_ms = Keyword.get(opts, :vacancy_cooldown_ms, @default_vacancy_cooldown_ms)
    rpc_timeout_ms = Keyword.get(opts, :rpc_timeout_ms, @default_rpc_timeout_ms)
    message_module = Keyword.get(opts, :message_module, Forum.Adapter.ErlDist)

    if not (is_integer(vacancy_cooldown_ms) and vacancy_cooldown_ms >= 0) do
      raise ArgumentError,
            "expected :vacancy_cooldown_ms to be a non-negative integer, got: #{inspect(vacancy_cooldown_ms)}"
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
    # (occupied/3, vacant/3, receive_node_state/3) can write directly,
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

    :persistent_term.put({Forum.Muster, scope, :status}, :stable)

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
    state.message_module.broadcast(state.scope, {:muster_discover, self()})
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

  # Local source — Muster.join asking us to claim this group on the designated.
  # Remote occupancy updates (:occupied, :vacant, :receive_node_state) write
  # directly to the :public occupancy_table from their :erpc worker — they no
  # longer bounce through this mailbox. See the "Remote entry points" section
  # above.
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
  @impl true
  def handle_info({:muster_discover, peer}, %State{} = state) do
    state.message_module.send(state.scope, node(peer), {:muster_discover_ack, self()})
    {:noreply, register_peer(state, peer)}
  end

  def handle_info({:muster_discover_ack, peer}, %State{} = state) do
    {:noreply, register_peer(state, peer)}
  end

  # A new node connected. Reach out so they can pair.
  def handle_info({:nodeup, node}, state) when node == node(), do: {:noreply, state}

  def handle_info({:nodeup, node}, state) do
    :telemetry.execute([:forum, state.scope, :node, :up], %{}, %{node: node})
    state.message_module.send(state.scope, node, {:muster_discover, self()})
    {:noreply, state}
  end

  # Net split / disconnect — wait for the peer's monitor DOWN.
  def handle_info({:nodedown, _node}, state), do: {:noreply, state}

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

  # Worker reported back the result of a claim/vacant RPC.
  #
  # The worker process is spawned via `spawn_opt(fn -> exit({:rpc_result, r}) end,
  # [{:monitor, [{:tag, {:rpc_done, op, group}}]}])`. Whatever termination path the
  # worker takes — normal exit with the result, raise, hard kill, OOM — we get
  # exactly one tagged DOWN with the exit reason.
  def handle_info({{:rpc_done, op, group}, _ref, :process, _pid, exit_reason}, state) do
    result =
      case exit_reason do
        {:rpc_result, r} -> r
        :noproc -> {:error, :worker_noproc}
        other -> {:error, {:worker_exit, other}}
      end

    handle_rpc_done(op, group, result, state)
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
        designated_node = designated_from_state(state, group)

        if designated_node == node() do
          :ets.insert(state.occupancy_table, {{group, node()}})
          {:reply, :ok, put_group_state(state, group, :occupied)}
        else
          dispatch_rpc(:occupied, group, designated_node, state)
          {:noreply, put_group_state(state, group, {:occupied_pending, [from]})}
        end

      :occupied ->
        {:reply, :ok, state}

      :cooldown ->
        state = cancel_cooldown(state, group)
        {:reply, :ok, put_group_state(state, group, :occupied)}

      {:occupied_pending, waiters} ->
        {:noreply, put_group_state(state, group, {:occupied_pending, [from | waiters]})}

      {:vacant_pending, waiters} ->
        {:noreply, put_group_state(state, group, {:vacant_pending, [from | waiters]})}
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
          designated_node = designated_from_state(state, group)

          if designated_node == node() do
            :ets.delete(state.occupancy_table, {group, node()})
            {:noreply, delete_group_state(state, group)}
          else
            dispatch_rpc(:vacant, group, designated_node, state)
            {:noreply, put_group_state(state, group, {:vacant_pending, []})}
          end
        end

      _ ->
        {:noreply, state}
    end
  end

  defp handle_rpc_done(:occupied, group, result, state) do
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

  defp handle_rpc_done(:vacant, group, result, state) do
    case Map.get(state.group_states, group) do
      {:vacant_pending, []} ->
        if match?({:error, _}, result) do
          Logger.warning(
            "Muster[#{node()}|#{state.scope}] vacant RPC failed for group=#{inspect(group)}: #{inspect(result)}"
          )
        end

        {:noreply, delete_group_state(state, group)}

      {:vacant_pending, waiters} ->
        # Claims arrived during the vacant RPC. Whether vacant succeeded or
        # failed, we now need to re-claim the group on the designated.
        designated_node = designated_from_state(state, group)

        if designated_node == node() do
          :ets.insert(state.occupancy_table, {{group, node()}})
          Enum.each(waiters, fn from -> GenServer.reply(from, :ok) end)
          {:noreply, put_group_state(state, group, :occupied)}
        else
          dispatch_rpc(:occupied, group, designated_node, state)
          {:noreply, put_group_state(state, group, {:occupied_pending, waiters})}
        end

      _ ->
        {:noreply, state}
    end
  end

  defp dispatch_rpc(op, group, designated_node, state) do
    message_module = state.message_module
    scope = state.scope
    rpc_timeout = state.rpc_timeout_ms

    function =
      case op do
        :occupied -> :occupied
        :vacant -> :vacant
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
    {_pid, _ref} =
      :erlang.spawn_opt(
        fn ->
          result =
            try do
              message_module.call(
                scope,
                designated_node,
                __MODULE__,
                function,
                [scope, group, node()],
                rpc_timeout
              )
            catch
              kind, reason -> {:error, {kind, reason}}
            end

          exit({:rpc_result, result})
        end,
        [{:monitor, [{:tag, {:rpc_done, op, group}}]}]
      )

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

  defp designated_from_state(state, group) do
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
    #    designated/2 see :rebalancing and fan out to all members. During the
    #    window, get_nodes/1 returns the current ring (still old generation
    #    until set_nodes returns), which is also fine — fan-out to either
    #    member set is safe.
    :persistent_term.put({Forum.Muster, state.scope, :status}, :rebalancing)

    # 2) Normalize in-flight pending states. :vacant_pending [] is dropped
    #    (we don't hold the group; no need to announce it). :vacant_pending
    #    with waiters is rewritten to :occupied_pending so the rebalance
    #    re-announces it to the new designated and settles the waiters.
    state = normalize_pending_for_rebalance(state)

    # 3) Atomically replace the node set; this bumps the ring's generation.
    #    After this call: find_node = NEW designations; find_historical_node
    #    (back: 1) = OLD designations.
    {:ok, _} = Ring.set_nodes(ring, new_members)

    # 4) Delta announce-set: groups in :occupied, :cooldown, or
    #    :occupied_pending whose designated actually changed. :cooldown
    #    groups must be included even though the Partition count is 0,
    #    because the old designated still believes we hold them and the new
    #    designated needs to know to expect a future :vacant.
    #    :occupied_pending must be included so callers parked on Scope's
    #    GenServer.call get :ok once the new designated has been told —
    #    instead of being cancelled with :rebalance_in_progress.
    candidates =
      for {group, gs} <- state.group_states,
          gs in [:occupied, :cooldown] or match?({:occupied_pending, _}, gs),
          do: group

    groups_to_reannounce =
      Enum.filter(candidates, fn group ->
        {:ok, new_dest} = Ring.find_node(ring, group)
        {:ok, old_dest} = Ring.find_historical_node(ring, group, 1)
        new_dest != old_dest
      end)

    by_designated =
      Enum.group_by(groups_to_reannounce, fn group ->
        {:ok, n} = Ring.find_node(ring, group)
        n
      end)

    # Local self-target: synchronous ETS inserts in the Scope process.
    # Remote targets: one Task per destination, awaited in parallel so the
    # rebalance window is bounded by ~RTT rather than N × RTT. Tasks link to
    # Scope, so an uncaught raise inside any closure crashes Scope just like
    # a sequential raise would have.
    {local_groups, remote_targets} =
      Enum.split_with(by_designated, fn {dest, _} -> dest == node() end)

    Enum.each(local_groups, fn {_, groups} ->
      Enum.each(groups, fn group ->
        :ets.insert(state.occupancy_table, {{group, node()}})
      end)
    end)

    message_module = state.message_module
    scope = state.scope
    rpc_timeout = state.rpc_timeout_ms

    tasks =
      Enum.map(remote_targets, fn {designated_node, groups} ->
        task =
          Task.async(fn ->
            message_module.call(
              scope,
              designated_node,
              __MODULE__,
              :receive_node_state,
              [scope, node(), groups],
              rpc_timeout
            )
          end)

        {designated_node, task}
      end)

    # Each remote call is already bounded by `rpc_timeout` inside the
    # adapter; add 1s of slack here so a hung Task surfaces via Task.await
    # rather than hanging Scope indefinitely.
    await_timeout = rpc_timeout + 1_000

    Enum.each(tasks, fn {designated_node, task} ->
      case Task.await(task, await_timeout) do
        :ok ->
          :ok

        other ->
          raise "Muster rebalance failed: target=#{inspect(designated_node)} result=#{inspect(other)}"
      end
    end)

    # 5) Settle :occupied_pending claims whose designation changed. The
    #    rebalance just informed the new designated via :receive_node_state,
    #    so the parked callers can be unblocked with :ok. Their original
    #    workers (targeting the old designated) may still complete later;
    #    the resulting :rpc_done lands in handle_rpc_done's _other clause
    #    and is dropped because group_states[group] will be :occupied by
    #    then.
    state = settle_pending_after_rebalance(state, MapSet.new(groups_to_reannounce))

    drop_stale_designated_entries(state)

    # 6) Flip back to :stable. If rebalance raised above, we skip this and
    #    supervisor restart re-initializes :status to :stable. Until restart,
    #    callers observing :rebalancing fan out to every member — safe.
    :persistent_term.put({Forum.Muster, state.scope, :status}, :stable)

    %{state | members: new_members}
  end

  defp drop_stale_designated_entries(state) do
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

  # Run at the start of rebalance. :vacant_pending [] entries are dropped
  # outright — we don't hold the group anymore and the new designated does
  # not need to know about it. :vacant_pending with waiters means a claim
  # arrived while a vacant RPC was in flight; we rewrite to :occupied_pending
  # so the rebalance handles announcing + settling like any other pending
  # claim.
  defp normalize_pending_for_rebalance(state) do
    Enum.reduce(state.group_states, state, fn
      {group, {:vacant_pending, []}}, st ->
        delete_group_state(st, group)

      {group, {:vacant_pending, waiters}}, st ->
        put_group_state(st, group, {:occupied_pending, waiters})

      _, st ->
        st
    end)
  end

  # Run at the end of rebalance, once :receive_node_state RPCs have informed
  # the new designated about every group whose designation changed. For each
  # :occupied_pending entry in that settled set, reply :ok to the waiters
  # and transition to :occupied. Entries not in the settled set are left
  # alone — their designation did not change, so the original in-flight
  # worker is still talking to the correct designated.
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
    # At init, members is just [node()], so the designated for every group is
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
