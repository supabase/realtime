defmodule Forum.Muster.Scope do
  @moduledoc false
  # Per-node cluster coordinator for Forum.Muster.
  #
  # The per-group claim state machine lives in the N Forum.Muster.Shard
  # processes (one per partition index). This process owns only the rare,
  # node-wide cluster-coordination concerns:
  #
  #   * Cluster view (sorted node list) + the :status / :view_hash
  #     persistent_terms read by Forum.Muster.router/2 and can_decide?/2.
  #     This process is the SOLE writer of those terms and of the ring's node
  #     set, which is exactly why sharding the claim path cannot weaken those
  #     two guarantees.
  #   * Router-role occupancy table — when this node is the router for a group,
  #     the set of source nodes that hold it. :public so :erpc workers running
  #     the remote entry points (occupied/4, vacant_batch/4) and the local
  #     shards write it directly.
  #   * The readiness barrier: member_views, owed_snapshots, applied_snapshot_seq.
  #   * Snapshot apply ({:apply_snapshot}) — serialized through this one process.
  #   * Rebalance orchestration (do_rebalance), the view heartbeat, and the
  #     stale-router-entry sweep.
  #
  # Rebalance gathers each shard's held groups with a SYNCHRONOUS GenServer.call
  # ({:rebalance, ...}); the slow snapshot RPCs it then dispatches stay
  # fire-and-forget, so this loop never blocks on a remote RPC. Shards never call
  # back into this process, so the synchronous gather cannot deadlock.
  use GenServer
  require Logger
  use Snabbkaffe

  alias ExHashRing.Ring

  @default_rpc_timeout_ms 5_000
  @default_view_heartbeat_interval_ms 10_000
  @default_rebalance_gather_timeout_ms 15_000
  @ring_replicas 128
  @ring_depth 2

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            scope: atom,
            message_module: module,
            view_heartbeat_interval_ms: pos_integer,
            rpc_timeout_ms: timeout,
            rebalance_gather_timeout_ms: timeout,
            occupancy_table: atom,
            members: [node],
            peers: %{pid => reference},
            member_views: %{node => {non_neg_integer, integer}},
            owed_snapshots: %{node => integer},
            applied_snapshot_seq: %{node => integer},
            view_seq: integer,
            telemetry_handler_id: term
          }
    defstruct [
      :scope,
      :message_module,
      :view_heartbeat_interval_ms,
      :rpc_timeout_ms,
      :rebalance_gather_timeout_ms,
      :occupancy_table,
      :telemetry_handler_id,
      members: [],
      peers: %{},
      # Barrier bookkeeping: each peer's most-recently-announced
      # {cluster-view hash, seq watermark} (via a :rebalance_marker, or seeded
      # on the discovery handshake). Newest-seq-wins, never reset — so an
      # announcement that arrives before we adopt that view is retained, and a
      # stale announcement arriving late (markers travel on more than one
      # channel) cannot regress a newer one. We are "ready" — and our occupancy
      # table can be trusted as a router — once every member's latest view agrees
      # with ours. The watermark is the seq of the peer's last announce round.
      member_views: %{},
      # Our own announce watermark, sent alongside every view announcement: the
      # seq of our last snapshot round (or of init's re-announce).
      view_seq: 0,
      # Routers we have an in-flight, fire-and-forget :receive_node_state
      # snapshot to, each stamped with the snapshot_seq of the round that
      # dispatched it. While a node is in here, announce_view must NOT send it a
      # bare view marker: the marker for an owed node is carried by the snapshot
      # itself, after its data is applied. A bare marker arriving first would let
      # the node count us as "agreed" before our occupancy data lands. Cleared by
      # the snapshot worker's :node_state_done on success; the seq stamp lets a
      # later rebalance that re-owes the same node keep the obligation even if an
      # earlier round's acknowledgement arrives afterwards.
      owed_snapshots: %{},
      # Router-role bookkeeping: the highest snapshot seq we have applied from
      # each source node (see handle_call({:apply_snapshot, ...})). A snapshot
      # whose seq is not strictly greater is a stale, reordered round and is
      # dropped wholesale — this is what makes a *sequence* of overlapping
      # rebalances safe, since the apply is serialized through this process and a
      # late round can never resurrect a group a newer round already dropped.
      applied_snapshot_seq: %{}
    ]
  end

  ## Public helpers (read paths used by Forum.Muster from the caller's process)

  @doc "Returns the list of nodes (as known by the local router state) holding `group`."
  @spec occupancy(atom, Forum.group()) :: [node]
  def occupancy(scope, group) do
    :ets.select(occupancy_table_name(scope), [{{{group, :"$1"}, :_}, [], [:"$1"]}])
  end

  @doc false
  # Occupancy ETS table name. Public so Forum.Muster.Shard can write it directly.
  @spec occupancy_table_name(atom) :: atom
  def occupancy_table_name(scope), do: :"#{scope}_muster_occupancy"

  @doc false
  # Insert/raise an occupancy row to `seq`, but never lower a row already stamped
  # at or above `seq`. Makes the occupancy table a uniform last-writer-wins-by-seq
  # register so a snapshot (dispatched by this coordinator) and an :occupied
  # (dispatched by a shard) writing the same {group, source} key concurrently can
  # never clobber the newer of the two. Atomic against concurrent writers via
  # select_replace (update branch) + insert_new (absent branch), retried on the
  # rare interleaving where a strictly-older row appears in between.
  @spec upsert_if_newer(atom, {Forum.group(), node}, integer) :: :ok
  def upsert_if_newer(table, key, seq) do
    # Keyed (literal key → set-table key lookup, not a scan) seq-guarded replace.
    # The replacement object must reconstruct the row; the key tuple is injected
    # as a {:const, _} literal (a bare tuple in a match-spec body is read as a
    # construction form, not a value) and `seq` is a bare integer literal.
    spec = [{{key, :"$1"}, [{:<, :"$1", seq}], [{{{:const, key}, seq}}]}]

    case :ets.select_replace(table, spec) do
      1 ->
        :ok

      0 ->
        if :ets.insert_new(table, {key, seq}) do
          :ok
        else
          case :ets.lookup(table, key) do
            [{^key, existing}] when existing < seq -> upsert_if_newer(table, key, seq)
            _ -> :ok
          end
        end
    end
  end

  ## Remote entry points
  #
  # These are invoked on the *router* / receiver node by remote nodes' shards
  # (occupied/4, vacant_batch/4) or coordinator (receive_node_state/5) via the
  # configured Forum.Adapter (default: :erpc.call). occupied/4 and vacant_batch/4
  # run inside the :erpc worker and write directly to the :public occupancy_table,
  # bypassing this coordinator's mailbox, so a busy router absorbs many concurrent
  # updates in parallel. Correctness holds because each occupancy key is
  # {group, source_node}: different sources own disjoint keys, and the source's
  # own shard serializes :occupied vs. :vacant_batch per group.

  # Occupancy rows are versioned: each row is {{group, source_node}, seq} where
  # `seq` is a per-source monotonic stamp (:erlang.unique_integer([:monotonic]))
  # assigned by the source at *dispatch* time. Seqs are only ever compared for
  # the same {group, source} key, so they always come from one source's VM and
  # are totally ordered there. The versioning closes a race that bare
  # delete/insert could not: a `vacant_batch` whose RPC timed out is not cancelled
  # by :erpc, so its DELETE may land on the router *after* the source re-claimed
  # with a fresh `occupied` INSERT. Because the re-claim is dispatched after the
  # vacant worker exited, its seq is strictly higher, and `vacant_batch` refuses to
  # delete a row stamped newer than itself.

  @doc "Remote: source_node tells us it now holds local members of `group`."
  @spec occupied(atom, Forum.group(), node, integer) :: :ok
  def occupied(scope, group, source_node, seq) do
    # Seq-guarded upsert (not an unconditional insert): a snapshot for this same
    # {group, source} may be applied concurrently by this coordinator during a
    # rebalance, and we must not let an older write clobber a newer one. See
    # upsert_if_newer/3.
    upsert_if_newer(occupancy_table_name(scope), {group, source_node}, seq)

    # Emitted AFTER the insert, so a forced ordering on this event implies the
    # row is committed (muster_distributed_test.exs races it against a stale
    # vacant DELETE).
    tp(:muster_occupied, %{
      scope: scope,
      node: node(),
      group: group,
      source: source_node,
      seq: seq
    })

    :ok
  end

  @doc "Remote: source_node tells us its last local members of `groups` left."
  @spec vacant_batch(atom, [Forum.group()], node, integer) :: :ok
  def vacant_batch(scope, groups, source_node, seq) do
    table = occupancy_table_name(scope)

    # Delete each row only if it is stamped no newer than this batch — i.e. a
    # later `occupied`/snapshot for the same key (higher seq) survives a stale,
    # late-arriving vacant DELETE. Atomic per row via select_delete's guard.
    tp_span(:muster_vacant_batch, %{
      scope: scope,
      node: node(),
      groups: groups,
      source: source_node,
      seq: seq
    }) do
      Enum.each(groups, fn group ->
        :ets.select_delete(table, [
          {{{group, source_node}, :"$1"}, [{:"=<", :"$1", seq}], [true]}
        ])
      end)
    end

    :ok
  end

  @doc """
  Remote: source_node gives us a full-state snapshot of its groups for the
  cluster view identified by `view_hash`.

  Unlike `occupied`/`vacant_batch`, this does **not** write the occupancy table
  from the RPC worker. It applies the snapshot via a synchronous
  `{:apply_snapshot, ...}` call into the receiver's coordinator and returns its
  reply. Serializing the apply through the single coordinator is what makes a
  *sequence* of overlapping rebalances safe: the coordinator applies a source's
  snapshots in mailbox order under a per-source seq guard, so a late or reordered
  round is dropped wholesale and can never resurrect a group a newer round already
  dropped — a guarantee that concurrent direct ETS writes from parallel RPC
  workers cannot give (the multi-row insert+delete is not atomic across workers).

  The snapshot still doubles as source_node's rebalance marker: the apply folds
  the occupancy write and the `member_views` update into one indivisible step
  (data first, then readiness). Because the call only returns once it has been
  applied, "RPC returned ⟹ applied" — so when the sender clears `owed_snapshots`
  and resumes its view heartbeat to us, our data and marker are already in place.
  We pass `:infinity` for the inner call (it is a few ETS ops that never block);
  the sender's `:erpc` `:rpc_timeout_ms` is the real bound.
  """
  @spec receive_node_state(atom, node, [Forum.group()], non_neg_integer, integer) :: :ok
  def receive_node_state(scope, source_node, groups, view_hash, seq) do
    GenServer.call(
      Forum.Supervisor.name(scope),
      {:apply_snapshot, source_node, groups, view_hash, seq},
      :infinity
    )
  end

  ## GenServer lifecycle

  @spec start_link(atom, Keyword.t()) :: GenServer.on_start()
  def start_link(scope, opts \\ []),
    do: GenServer.start_link(__MODULE__, [scope, opts], name: Forum.Supervisor.name(scope))

  @doc false
  # Child spec for the scope's shared ring. Started as a supervised sibling by
  # Forum.Supervisor (NOT linked to this coordinator) so a coordinator restart
  # does not take the ring down under the shards that read it directly.
  def ring_child_spec(scope) do
    %{
      id: :muster_ring,
      start:
        {Ring, :start_link,
         [[name: ring_name(scope), depth: @ring_depth, replicas: @ring_replicas]]}
    }
  end

  @impl true
  def init([scope, opts]) do
    view_heartbeat_interval_ms =
      Keyword.get(opts, :view_heartbeat_interval_ms, @default_view_heartbeat_interval_ms)

    rpc_timeout_ms = Keyword.get(opts, :rpc_timeout_ms, @default_rpc_timeout_ms)

    rebalance_gather_timeout_ms =
      Keyword.get(opts, :rebalance_gather_timeout_ms, @default_rebalance_gather_timeout_ms)

    message_module = Keyword.get(opts, :message_module, Forum.Adapter.ErlDist)

    if not (is_integer(view_heartbeat_interval_ms) and view_heartbeat_interval_ms > 0) do
      raise ArgumentError,
            "expected :view_heartbeat_interval_ms to be a positive integer, got: #{inspect(view_heartbeat_interval_ms)}"
    end

    :ok = :net_kernel.monitor_nodes(true)

    # The occupancy table is created and OWNED by Forum.Supervisor (a long-lived
    # sibling), not by us — so it survives a coordinator restart under the live
    # shards that write it directly. We only reference it by name. On our restart
    # the table retains the previous incarnation's rows; that is safe: members
    # resets to [node()] below so our view_hash mismatches every sender and
    # can_decide?/2 is false (callers flood, never trusting occupancy), each
    # remote source's next snapshot replaces its rows wholesale, and
    # drop_stale_router_entries prunes the rest on the :ready transition. Our own
    # self rows are re-asserted (monotonically) by reannounce_local_groups_at_init.
    occupancy_table = occupancy_table_name(scope)

    :ok = message_module.register(scope)

    # The ring is a supervised sibling (Forum.Supervisor starts it before us).
    # Reset its node set to just us — on a coordinator restart members shrinks
    # back to [node()] until peers re-discover us.
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
        %{scope: scope}
      )

    Logger.info("Muster[#{node()}|#{scope}] Starting")

    state = %State{
      scope: scope,
      message_module: message_module,
      view_heartbeat_interval_ms: view_heartbeat_interval_ms,
      rpc_timeout_ms: rpc_timeout_ms,
      rebalance_gather_timeout_ms: rebalance_gather_timeout_ms,
      occupancy_table: occupancy_table,
      telemetry_handler_id: telemetry_handler_id,
      members: [node()]
    }

    state = reannounce_local_groups_at_init(state)
    # Above the seqs of the rows just re-announced, so receivers may judge them
    # once this watermark is announced.
    state = %{state | view_seq: next_seq()}

    {:ok, state, {:continue, :discover}}
  end

  @impl true
  def handle_continue(:discover, state) do
    state.message_module.broadcast(
      state.scope,
      {:muster_discover, self(), own_view_hash(state), state.view_seq}
    )

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

  # Apply a full-state snapshot from `source` (dispatched by its rebalance, via
  # the receive_node_state RPC, which calls in here and waits for the reply).
  # Serializing the apply through this one process is what makes a *sequence* of
  # overlapping rebalances safe: the per-source seq guard is atomic because this
  # is one process.
  #
  # A snapshot whose seq is not strictly greater than the highest already applied
  # from this source is a stale, reordered round (the RPC that carried it may have
  # been delayed past a newer round, or executed late after an erpc timeout). We
  # drop it wholesale, so it can never resurrect a group a newer round already
  # dropped, and still reply :ok.
  #
  # Upsert the snapshot rows at `seq` (never lowering a newer racing re-claim),
  # then delete only this source's older rows (strict `<`). We then advance the
  # watermark and fold in the carried view marker (member_views + update_status).
  # Data first, then readiness, in one indivisible step.
  @impl true
  def handle_call({:apply_snapshot, source, groups, view_hash, seq}, _from, %State{} = state) do
    applied = Map.get(state.applied_snapshot_seq, source)

    if applied != nil and seq <= applied do
      {:reply, :ok, state}
    else
      table = state.occupancy_table
      Enum.each(groups, fn group -> upsert_if_newer(table, {group, source}, seq) end)
      :ets.select_delete(table, [{{{:_, source}, :"$1"}, [{:<, :"$1", seq}], [true]}])

      tp(:muster_node_state_received, %{
        scope: state.scope,
        node: node(),
        source: source,
        view_hash: view_hash,
        groups: groups
      })

      state = %{
        state
        | applied_snapshot_seq: Map.put(state.applied_snapshot_seq, source, seq)
      }

      {:reply, :ok, update_status(put_member_view(state, source, view_hash, seq))}
    end
  end

  # For tests / introspection — group_states + cooldown are gathered from the
  # shards (they own the per-group state machine now).
  def handle_call(:status, _from, state) do
    group_states = gather_group_states(state.scope)

    reply = %{
      members: state.members,
      peers: Map.keys(state.peers) |> Enum.map(&node/1),
      group_states: group_states,
      cooldown: for({g, :cooldown} <- group_states, do: g)
    }

    {:reply, reply, state}
  end

  # Full snapshot for `Forum.Muster.dump/1` — everything :status returns plus the
  # persistent_term lifecycle fields, the per-peer view bookkeeping, the ring's
  # current node set, and the router-role occupancy table folded into
  # %{group => [source_node]}.
  def handle_call(:dump, _from, state) do
    occupancy =
      state.occupancy_table
      |> :ets.tab2list()
      |> Enum.reduce(%{}, fn {{group, src}, _seq}, acc ->
        Map.update(acc, group, [src], &[src | &1])
      end)

    {:ok, ring_nodes} = Ring.get_nodes(ring_name(state.scope))
    group_states = gather_group_states(state.scope)

    reply = %{
      scope: state.scope,
      status: :persistent_term.get({Forum.Muster, state.scope, :status}, nil),
      view_hash: :persistent_term.get({Forum.Muster, state.scope, :view_hash}, nil),
      members: state.members,
      ring_nodes: ring_nodes,
      peers: Map.keys(state.peers) |> Enum.map(&node/1),
      member_views: state.member_views,
      owed_snapshots: state.owed_snapshots,
      applied_snapshot_seq: state.applied_snapshot_seq,
      group_states: group_states,
      cooldown: for({g, :cooldown} <- group_states, do: g),
      occupancy: occupancy
    }

    {:reply, reply, state}
  end

  ## handle_info

  # Peer discovery (the receiver of a discover replies with an ack and registers
  # the peer). The handshake piggybacks each side's current view hash and announce
  # watermark so member_views is seeded immediately — important after a coordinator
  # restart, where it would otherwise be empty until the next membership change.
  @impl true
  def handle_info({:muster_discover, peer, view_hash, seq}, %State{} = state) do
    state.message_module.send(
      state.scope,
      node(peer),
      {:muster_discover_ack, self(), own_view_hash(state), state.view_seq}
    )

    state = put_member_view(state, node(peer), view_hash, seq)
    {:noreply, register_peer(state, peer)}
  end

  def handle_info({:muster_discover_ack, peer, view_hash, seq}, %State{} = state) do
    state = put_member_view(state, node(peer), view_hash, seq)
    {:noreply, register_peer(state, peer)}
  end

  # A new node connected. Reach out so they can pair.
  def handle_info({:nodeup, node}, state) when node == node(), do: {:noreply, state}

  def handle_info({:nodeup, node}, state) do
    Logger.info(
      "Muster[#{node()}|#{state.scope}] node up: #{inspect(node)} — reaching out to pair"
    )

    :telemetry.execute([:forum, state.scope, :node, :up], %{}, %{node: node})

    state.message_module.send(
      state.scope,
      node,
      {:muster_discover, self(), own_view_hash(state), state.view_seq}
    )

    {:noreply, state}
  end

  # Net split / disconnect — wait for the peer's monitor DOWN.
  def handle_info({:nodedown, _node}, state), do: {:noreply, state}

  # A peer announced the cluster view it has finished rebalancing into, plus its
  # announce watermark. Record it as that peer's latest view (newest-seq-wins). We
  # do NOT gate on it matching our current view: storing it means an announcement
  # that arrives before we adopt that view is retained, so once we catch up the
  # agreement check in ready?/1 sees it.
  def handle_info({:rebalance_marker, source, view_hash, seq}, %State{} = state) do
    {:noreply, update_status(put_member_view(state, source, view_hash, seq))}
  end

  # Peer coordinator crashed/disconnected — drop occupancy entries owned by that
  # node and rebalance.
  def handle_info({:DOWN, ref, :process, pid, _reason}, %State{} = state) do
    case Map.pop(state.peers, pid) do
      {^ref, new_peers} ->
        Logger.info(
          "Muster[#{node()}|#{state.scope}] peer down: #{inspect(node(pid))} — dropping its occupancy and rebalancing"
        )

        :ets.match_delete(state.occupancy_table, {{:_, node(pid)}, :_})
        :telemetry.execute([:forum, state.scope, :node, :down], %{}, %{node: node(pid)})

        member_views = Map.delete(state.member_views, node(pid))
        applied_snapshot_seq = Map.delete(state.applied_snapshot_seq, node(pid))

        state = %{
          state
          | peers: new_peers,
            member_views: member_views,
            applied_snapshot_seq: applied_snapshot_seq
        }

        {:noreply, recompute_members(state)}

      _ ->
        {:noreply, state}
    end
  end

  # Worker reported back the result of a fire-and-forget :receive_node_state
  # snapshot dispatched during a rebalance.
  #
  # On success the receiver has enqueued (and will FIFO-apply) our snapshot, and
  # the marker it carries, so we stop suppressing the view heartbeat to that node
  # — but only if this is still the round that owes it. A newer rebalance may have
  # re-owed the same router with a higher seq; clearing on a stale (lower-seq)
  # acknowledgement would let the next heartbeat send a bare marker before the
  # newer snapshot lands. The seq stamp guards against that.
  def handle_info(
        {{:node_state_done, router_node, seq}, _ref, :process, _pid, exit_reason},
        state
      ) do
    case worker_result(exit_reason) do
      :ok ->
        owed =
          case Map.get(state.owed_snapshots, router_node) do
            ^seq -> Map.delete(state.owed_snapshots, router_node)
            _ -> state.owed_snapshots
          end

        {:noreply, %{state | owed_snapshots: owed}}

      other ->
        raise "Muster rebalance snapshot to #{inspect(router_node)} failed: #{inspect(other)}"
    end
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
  # Locally-spawned pids can't masquerade as remote peers (`node/1` returns the
  # local node), so triggering rebalance through the normal discovery path with a
  # fake remote isn't possible in single-node tests. This hook is the unlock.
  def handle_info({:__rebalance_for_test, new_members}, state) when is_list(new_members) do
    new_members_sorted = Enum.sort(new_members)
    state = do_rebalance(state, new_members_sorted)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Telemetry handler

  @doc false
  # Runs in the emitting Partition process. Route the vacancy to the shard that
  # owns the group (same phash2(group, N) the claim path uses), guarded so a
  # mid-restart shard never makes the Partition process raise.
  def handle_vacant_telemetry(_event, _measurements, %{group: group}, %{scope: scope}) do
    case Process.whereis(Forum.Supervisor.shard(scope, group)) do
      nil -> :ok
      pid -> Kernel.send(pid, {:local_vacant, group})
    end
  end

  ## Rebalance

  defp do_rebalance(state, new_members) do
    ring = ring_name(state.scope)

    Logger.info(
      "Muster[#{node()}|#{state.scope}] rebalance start: members #{inspect(state.members)} -> #{inspect(new_members)} (view_hash #{:erlang.phash2(new_members)})"
    )

    tp(:muster_rebalance_start, %{
      scope: state.scope,
      node: node(),
      from: state.members,
      to: new_members,
      view_hash: :erlang.phash2(new_members)
    })

    # 1) Flip status to :rebalancing BEFORE updating the ring. Callers reading
    #    router/2 see :rebalancing and fan out to all members. member_views is NOT
    #    reset — peers' already-announced views stay and are re-evaluated against
    #    the new hash by update_status at the end.
    :persistent_term.put({Forum.Muster, state.scope, :status}, :rebalancing)
    :persistent_term.put({Forum.Muster, state.scope, :view_hash}, :erlang.phash2(new_members))

    # 2) Atomically replace the node set; this bumps the ring's generation. After
    #    this call: find_node = NEW routers; find_historical_node(_, _, 1) = OLD.
    {:ok, _} = Ring.set_nodes(ring, new_members)

    # 3) Stamp the snapshot seq for this round NOW — right after the ring swap and
    #    before gathering the shards. This is a clean cut in the VM-global
    #    monotonic sequence: every group held before the rebalance carries an
    #    occupancy seq < snapshot_seq, and every claim a shard processes from here
    #    on carries seq > snapshot_seq — so the wipe below (strict `<`) can never
    #    delete a freshly-claimed group's row.
    snapshot_seq = next_seq()

    # 4) Gather every shard's held groups synchronously. In this same call each
    #    shard also normalizes its in-flight vacant batch and settles its moved
    #    :occupied_pending waiters (see Forum.Muster.Shard). Because each shard's
    #    mailbox is FIFO and the ring is already swapped, the union below is a
    #    COMPLETE held set — the basis for complete-per-router snapshots.
    #    Candidates are the groups we hold (:occupied, :cooldown, :occupied_pending):
    #    :cooldown must be included even though the Partition count is 0, because
    #    the old router still believes we hold them; :occupied_pending so parked
    #    callers get :ok once the new router has been told.
    candidates =
      state.scope
      |> Forum.Supervisor.shards()
      |> Enum.flat_map(fn shard ->
        {:held, groups} =
          GenServer.call(shard, {:rebalance, new_members}, state.rebalance_gather_timeout_ms)

        groups
      end)

    new_router =
      Map.new(candidates, fn group ->
        {:ok, n} = Ring.find_node(ring, group)
        {group, n}
      end)

    # Groups whose router actually changed — used to decide which routers need a
    # refreshed snapshot at all.
    groups_to_reannounce =
      Enum.filter(candidates, fn group ->
        {:ok, old_dest} = Ring.find_historical_node(ring, group, 1)
        Map.fetch!(new_router, group) != old_dest
      end)

    # Routers that gained at least one moved group. Each gets a FULL snapshot of
    # every group we hold routed to it — not just the moved ones — because
    # receive_node_state wipes all of this source's rows before inserting. Sending
    # only the moved groups would drop unchanged groups that still route there.
    # Routers with no moved group are left untouched: their existing rows for us
    # are still correct, and any group that moved *away* is cleared by their own
    # drop_stale_router_entries.
    changed_routers =
      groups_to_reannounce |> Enum.map(&Map.fetch!(new_router, &1)) |> MapSet.new()

    Logger.info(
      "Muster[#{node()}|#{state.scope}] rebalance: #{length(candidates)} group(s) held, #{length(groups_to_reannounce)} moved, snapshotting #{MapSet.size(changed_routers)} router(s): #{inspect(MapSet.to_list(changed_routers))}"
    )

    by_router =
      candidates
      |> Enum.group_by(&Map.fetch!(new_router, &1))
      |> Map.take(MapSet.to_list(changed_routers))

    # Local self-target: synchronous (seq-guarded) ETS inserts. Remote targets:
    # one fire-and-forget worker per destination. We do NOT wait — Scope stays
    # free while the snapshots are in flight; each worker reports via a tagged
    # DOWN ({:node_state_done, ...}); a failure crashes us from that handler.
    {local_groups, remote_targets} =
      Enum.split_with(by_router, fn {dest, _} -> dest == node() end)

    Enum.each(local_groups, fn {_, groups} ->
      Enum.each(groups, fn group ->
        upsert_if_newer(state.occupancy_table, {group, node()}, snapshot_seq)
      end)
    end)

    view_hash = :erlang.phash2(new_members)

    Enum.each(remote_targets, fn {router_node, groups} ->
      spawn_rpc_worker(
        state,
        router_node,
        :receive_node_state,
        [state.scope, node(), groups, view_hash, snapshot_seq],
        {:node_state_done, router_node, snapshot_seq}
      )
    end)

    snapshot_targets = Enum.map(remote_targets, fn {router_node, _} -> router_node end)

    owed_snapshots =
      Enum.reduce(snapshot_targets, state.owed_snapshots, fn router_node, acc ->
        Map.put(acc, router_node, snapshot_seq)
      end)

    # Marker hybrid: members that received a data snapshot are marked by the
    # snapshot itself (its {:apply_snapshot} carries view_hash and is folded into
    # member_views when applied, after the data write). Every other member gets a
    # cheap async marker so its barrier learns "this source holds nothing for me"
    # rather than "this source has not arrived yet". Self never needs one.
    Enum.each(new_members -- [node() | snapshot_targets], fn member ->
      state.message_module.send(
        state.scope,
        member,
        {:rebalance_marker, node(), view_hash, snapshot_seq}
      )
    end)

    # Adopt the new view (and this round's announce watermark) before judging
    # stale entries. Prune owed entries for nodes no longer in the cluster.
    state = %{
      state
      | members: new_members,
        view_seq: snapshot_seq,
        owed_snapshots: Map.take(owed_snapshots, new_members)
    }

    drop_stale_router_entries(state)

    # Leave :rebalancing for :ready or :converging based on peer agreement. A
    # single-node cluster lands on :ready immediately; a multi-node cluster stays
    # :converging until peer announcements arrive. If a snapshot RPC ultimately
    # fails it crashes us from :node_state_done and the restart re-announces every
    # locally-held group from the partition tables, so the optimistic settle that
    # each shard already did self-heals.
    update_status(state)
  end

  # Recompute the lifecycle status from member_views vs. current membership and
  # publish it (only when it actually changes). Only ever sets :ready or
  # :converging — :rebalancing is owned by do_rebalance.
  defp update_status(state) do
    status = if ready?(state), do: :ready, else: :converging
    key = {Forum.Muster, state.scope, :status}
    previous = :persistent_term.get(key, nil)

    if previous != status do
      :persistent_term.put(key, status)

      tp(:muster_status_change, %{
        scope: state.scope,
        node: node(),
        from: previous,
        to: status,
        members: state.members,
        view_hash: own_view_hash(state)
      })

      Logger.info(
        "Muster[#{node()}|#{state.scope}] status #{inspect(previous)} -> #{inspect(status)} (members #{inspect(state.members)})"
      )

      # Most stale rows cannot be GC'd during the rebalance itself: peers have
      # typically not yet announced the new view, so the source-agreement guard in
      # drop_stale_router_entries skips their rows. Re-run the sweep once every
      # member has agreed — now every member's rows are judgeable.
      if status == :ready, do: drop_stale_router_entries(state)
    end

    state
  end

  # Ready once every member (other than ourselves) has announced a view that
  # agrees with ours. A member with no entry yet, or one whose latest view
  # differs, keeps us not-ready — the safe direction (the router floods).
  defp ready?(state) do
    own = own_view_hash(state)

    Enum.all?(state.members, fn member ->
      member == node() or match?({^own, _}, Map.get(state.member_views, member))
    end)
  end

  defp own_view_hash(state), do: :erlang.phash2(state.members)

  # Newest-seq-wins: seqs are per-source monotonic dispatch stamps, so the entry
  # with the highest seq is the source's causally-latest announcement even when
  # markers arrive out of order (they travel both as async dist sends and inside
  # :receive_node_state RPCs).
  defp put_member_view(state, source, view_hash, seq) do
    case Map.get(state.member_views, source) do
      {_hash, newer} when newer > seq ->
        state

      _ ->
        %{state | member_views: Map.put(state.member_views, source, {view_hash, seq})}
    end
  end

  # GC of router-role occupancy rows for groups that no longer route to us.
  #
  # A row may only be judged under our ring if its source demonstrably shares the
  # view the ring implements; otherwise deleting it can lose data. The source's
  # announced view (member_views) must equal ours, and the row's seq must not
  # exceed the watermark carried by that announcement (snapshot data is committed
  # straight to ETS by the RPC worker while the matching marker waits in our
  # mailbox, so the table can be AHEAD of member_views). Skipped rows are harmless
  # and are re-judged on the :ready transition. Our own rows are always judgeable
  # and must stay in the sweep: a group that moved away — or was vacated while
  # routed elsewhere — leaves a self row nothing else cleans up.
  defp drop_stale_router_entries(state) do
    ring = ring_name(state.scope)
    own = own_view_hash(state)

    state.occupancy_table
    |> :ets.select([{{{:"$1", :"$2"}, :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.each(fn {group, n, row_seq} ->
      # Agreement first: it is a map lookup, and at rebalance time most sources
      # have not announced the new view yet — their rows are skipped without
      # paying for the ring lookup.
      if source_agrees?(state, n, row_seq, own) and router_under_ring(ring, group) != node() do
        :ets.delete(state.occupancy_table, {group, n})

        # Emitted AFTER the delete, so a block_until on this event implies the
        # row is gone.
        tp(:muster_drop_stale_entry, %{
          scope: state.scope,
          node: node(),
          group: group,
          source: n
        })
      end
    end)
  end

  defp router_under_ring(ring, group) do
    {:ok, n} = Ring.find_node(ring, group)
    n
  end

  defp source_agrees?(_state, source, _row_seq, _own) when source == node(), do: true

  defp source_agrees?(state, source, row_seq, own) do
    case Map.get(state.member_views, source) do
      {^own, watermark} -> row_seq <= watermark
      _ -> false
    end
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

        tp(:muster_peer_registered, %{
          scope: state.scope,
          node: node(),
          peer: node(peer)
        })

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

  ## Init / introspection helpers

  # At init, members is just [node()], so the router for every group is ourselves.
  # Walk the partitions (which may have entries left over from a previous
  # incarnation) and insert their self occupancy rows. The per-group state machine
  # is rebuilt independently by each shard.
  defp reannounce_local_groups_at_init(state) do
    Enum.each(local_groups(state), fn group ->
      upsert_if_newer(state.occupancy_table, {group, node()}, next_seq())
    end)

    state
  end

  defp local_groups(state) do
    state.scope
    |> Forum.Supervisor.partitions()
    |> Enum.flat_map(&Forum.Partition.groups/1)
  end

  # Fold every shard's per-group state into one map for :status / :dump. A shard
  # that is momentarily down (mid-restart) is skipped rather than crashing this
  # introspection call — the groups it owns simply read as absent until it is
  # back. (do_rebalance's gather is deliberately NOT tolerant: a shard down
  # mid-rebalance should crash us so the restart re-announces from a clean slate.)
  defp gather_group_states(scope) do
    scope
    |> Forum.Supervisor.shards()
    |> Enum.reduce(%{}, fn shard, acc ->
      try do
        Map.merge(acc, GenServer.call(shard, :group_states))
      catch
        :exit, _ -> acc
      end
    end)
  end

  ## View announce / RPC workers

  # Re-announce our current view to every other member (newest-seq-wins on their
  # side). Members we still owe a rebalance snapshot are skipped: their marker is
  # carried by the in-flight snapshot, after its data is applied.
  defp announce_view(state) do
    view_hash = own_view_hash(state)

    Enum.each(state.members, fn member ->
      if member != node() and not Map.has_key?(state.owed_snapshots, member) do
        state.message_module.send(
          state.scope,
          member,
          {:rebalance_marker, node(), view_hash, state.view_seq}
        )
      end
    end)

    :ok
  end

  defp schedule_view_heartbeat(state) do
    Process.send_after(self(), :view_heartbeat, state.view_heartbeat_interval_ms)
    :ok
  end

  # spawn_opt with monitor + tag gives us atomic spawn+monitor and uses the
  # worker's exit reason as the result channel, so any termination surfaces as a
  # single tagged DOWN message. Used here only for the rebalance snapshot RPC
  # (receive_node_state); shards dispatch occupied/vacant_batch.
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

  defp worker_result({:rpc_result, r}), do: r
  defp worker_result(:noproc), do: {:error, :worker_noproc}
  defp worker_result(other), do: {:error, {:worker_exit, other}}

  # Per-source monotonic occupancy stamp. VM-global and strictly increasing.
  defp next_seq, do: :erlang.unique_integer([:monotonic])

  ## Names

  defp ring_name(scope), do: :"#{scope}_muster_ring"
end
