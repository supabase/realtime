# Forum

Forum is a scalable, distributed process-group library for Elixir/OTP. It ships two primitives that share the same supervision/partition machinery but solve different problems:

* **`Forum.Census`** — eventually-consistent counting of group membership across the cluster. Use when you need to know "how many processes are in group X right now" without paying per-join/leave network traffic.
* **`Forum.Muster`** — precise routing for fan-out broadcast. It tracks, for every group, which nodes hold local members, and tells you the single **router** node to route through — so you can send a message to every process in a group, anywhere in the cluster, without blindly broadcasting to nodes that don't care. Muster owns the routing decision; you supply the transport.

Both share the same per-node fundamentals:

* Process pids never leave the node they live on.
* Group membership is partitioned locally for concurrency (one partition GenServer per scheduler by default).
* A cluster forms by all nodes starting the same scope name; nodes discover each other via Erlang distribution.

## Installation

```elixir
def deps do
  [
    {:forum, "~> 1.0"}
  ]
end
```

---

## `Forum.Census` — distributed counts

Each node holds local-only membership and broadcasts its per-group counts to every peer on a fixed interval (default 5 s). Reads aggregate the local count plus the most recent counts received from peers. The view is **eventually consistent** — a join is reflected on remote nodes after at most one broadcast interval — but the cost on the wire is constant in the number of joins/leaves, not proportional.

Start it under your supervision tree:

```elixir
children = [
  {Forum.Census, [:users, partitions: 8, broadcast_interval_in_ms: 5_000]}
]
```

Use it:

```elixir
iex> Forum.Census.join(:users, {:tenant, 123}, self())
:ok
iex> Forum.Census.local_member_count(:users, {:tenant, 123})
1
iex> Forum.Census.member_count(:users, {:tenant, 123})        # cluster-wide
3
iex> Forum.Census.member_counts(:users)
%{{:tenant, 123} => 3, {:tenant, 456} => 1}
```

When to use Census: you want counts, totals, presence-of-anyone signals, dashboards. You don't need precision on the millisecond and you don't want to fan out per-event traffic.

---

## `Forum.Muster` — group-routed fan-out broadcast

Muster answers a different question: *given a group, which nodes have at least one local member of it?* — and uses that to route a broadcast precisely, without blasting every node in the cluster.

### The router node

For each group, exactly one node in the Muster cluster is the **router** node, chosen by **consistent hashing** over the sorted member list (via [`ex_hash_ring`](https://hexdocs.pm/ex_hash_ring), 128 vnodes per node by default). Every node computes the same router independently from the same ring (no consensus needed — the member list is the only input). Consistent hashing matters at rebalance time: when a node joins or leaves a cluster of size *N*, only ~1/*N* of the groups change their router, instead of nearly all groups (as a naive `phash2(group, length(members))` would produce).

The router node owns the authoritative "which nodes hold this group" set. When the first local member of a group joins on node A, A sends a synchronous `:occupied` notification to the router node. When the last local member leaves (after a cooldown — see below), A queues the group and a periodic flush sends a batched `:vacant_batch` to the router. The router keeps a table keyed by `{group, node}` — the set of nodes a broadcast for that group must reach.

To broadcast, a caller asks `router/2` for the group's router node and routes the message there over its own transport; the router then fans out to the member nodes. While the cluster view is in flux, `router/2` returns `{:rebalancing, members}` and the caller fans out to every member instead.

### Public API

```elixir
Forum.Muster.join(scope, group, pid)        # :ok | {:error, :rpc_failed | :not_local | ...}
Forum.Muster.leave(scope, group, pid)       # :ok
Forum.Muster.router(scope, group)           # {:ok, node} | {:rebalancing, [node]}
Forum.Muster.members(scope)                 # [node]
Forum.Muster.local_members(scope, group)    # [pid]
Forum.Muster.local_member?(scope, group, pid)
Forum.Muster.local_member_count(scope, group)
Forum.Muster.dump(scope)                     # prints a state snapshot, returns :ok
```

Start it under supervision with a scope name (use a different scope from any Census on the same node):

```elixir
children = [
  {Forum.Muster,
   [:topics, partitions: 8, vacancy_cooldown_ms: 30_000, vacant_flush_interval_ms: 5_000]}
]
```

### How join works

```
caller                       local Scope                 router Scope (remote)
  |                              |                                    |
  | Partition.member_count > 0?  |                                    |
  | yes  -- Partition.join, :ok  |                                    |
  | no                           |                                    |
  |----- {:claim, group} ------->|                                    |
  |                              | router == self?                    |
  |                              |   yes: write occupancy, reply :ok  |
  |                              |   no: spawn worker --------------->|
  |                              |                                    | insert {{group, A}}
  |                              | <---- :ok ------------------------ |
  |                              | reply :ok to all waiters           |
  | <----- :ok ----------------- |                                    |
  | Partition.join(group, pid)   |                                    |
```

Key invariants:

* The RPC happens **before** `Partition.join`, so an entry in the Partition implies the router has been told.
* If the RPC fails the caller gets `{:error, :rpc_failed}` and the Partition stays empty, so the next `join/3` naturally retries.
* Concurrent `join/3` calls for the same fresh group dedup into **one** RPC; the rest of the callers piggyback on the in-flight `:occupied_pending` state.
* The Scope GenServer never blocks on an RPC — it dispatches the call to a short-lived worker process and parks the waiters in `{:occupied_pending, [from | …]}`. The worker reports back with `{:rpc_done, …}`.

### How leave works (the cooldown, and the batched vacant flush)

`leave/3` just does `Forum.Partition.leave`. When the local count for the group goes 1 → 0, Partition emits a `[:forum, scope, :group, :vacant]` telemetry event. Scope picks this up and enters the **cooldown** state for the group (default 30 s, configurable via `:vacancy_cooldown_ms`). During cooldown:

* The router still believes we hold the group — no RPC has been sent.
* If a new `join/3` arrives, Scope cancels the cooldown timer and goes back to `:occupied` — no network traffic. This is the whole reason cooldown exists: a quick join/leave/join cycle costs zero RPCs.
* If the cooldown expires with the group still empty, the group moves to `:vacant_queued`.

A periodic **vacant flush** (every `:vacant_flush_interval_ms`, default 5 s) then drains the queue: it buckets all `:vacant_queued` groups by their *current* router and sends **one** `:vacant_batch` RPC per router (groups routed to self are pruned locally), moving each group to `:vacant_flushing` until the batch settles. On success the groups are forgotten; **on failure they go back to `:vacant_queued`** and the next flush retries them. The flush is therefore self-draining: a transient RPC failure — or a router that was briefly overloaded — no longer leaves a permanently stale `{group, node}` entry, because the group keeps being re-sent until the router acknowledges it. Because the router computed at flush time is always the current one, a rebalance that moved a queued group's router simply routes the next flush to the right node.

If a `join/3` arrives while a group is `:vacant_flushing` (its vacant batch is mid-flight), Scope does **not** wait for the batch: it re-claims immediately, dispatching `:occupied` straight away and moving the group to `:occupied_pending`. The `:occupied` is dispatched after the in-flight `:vacant_batch`, so it carries a higher occupancy `seq` and the router's guard makes its INSERT win over the racing (lower-`seq`) DELETE regardless of arrival order (see [Occupancy-row versioning](#vacant-time-rpc-failure)). The batch's eventual reply is then dropped — the group is no longer `:vacant_flushing`.

---

## Rebalance — what happens when nodes join or leave

Each Muster scope runs one `ExHashRing.Ring` process (linked to the scope's Scope GenServer). The ring stores the member set and provides ETS-backed lookups; mutations bump a generation counter and keep the previous generation accessible for delta computation.

Two `persistent_term` keys track the cluster view (all cheap, lock-free reads):

```
{Forum.Muster, scope, :status}    = :rebalancing | :converging | :ready
{Forum.Muster, scope, :view_hash} = phash2(sorted member list)
```

`:status` is a lifecycle tri-state: **`:rebalancing`** (our ring is in flux) → **`:converging`** (ring adopted, still waiting for peers to agree on our view) → **`:ready`** (every peer agrees; our occupancy table can be trusted as a router). The three reachable states replace what would otherwise be a `:stable`/`:rebalancing` flag plus a separate `:ready` boolean — since "ready" already implies "not rebalancing," one ordered value captures the lifecycle without a redundant key.

`Muster.router/2` returns the full member list to fan out only while `:rebalancing`; in `:converging`/`:ready` it routes to the ring's node. `Muster.can_decide?/2` (router side) trusts the occupancy table only in `:ready` (which subsumes the ring-settled check) with `:view_hash` agreement. `:view_hash` and `:status` drive the router-readiness barrier (see below).

### Trigger

A rebalance starts on every node whenever its view of the cluster changes:

* `:nodeup` from `:net_kernel` (after libcluster, manual `Node.connect/1`, etc.) → if the new node is also running this scope's Muster, the discovery handshake adds it to `peers` → `recompute_members` runs.
* A peer's Scope process `:DOWN` (crash or disconnect) → peer is removed → `recompute_members` runs. Before rebalancing, the `:DOWN` handler also wipes every occupancy row keyed by the departed node — a dead source can never flush its vacancies, so nothing else would clean them. (`test/forum/muster_distributed_test.exs` kills a whole node and asserts the departure path end-to-end: groups the dead node routed move onto the survivors and are re-announced to their new routers, no survivor's occupancy table still lists the dead node as a source, and the remaining cluster re-converges to `:ready`.)

### What `recompute_members` does

1. Compute the new sorted member list. If unchanged, do nothing.
2. Flip `:status` to `:rebalancing`. From this point, `Muster.router/2` returns `{:rebalancing, members}` for all groups; broadcasters fan out to every member.
3. **Normalize in-flight pending states.** A `:vacant_queued` entry is left untouched — we don't hold the group (so it isn't announced), but the next flush after the ring update re-routes it to the group's *current* router, which drains any stale entry the old router still holds. A `:vacant_flushing` entry (a vacant batch RPC in flight) is likewise rewritten back to `:vacant_queued` so the next flush re-sends to the post-rebalance router; the in-flight worker's late result lands in `handle_vacant_batch_done`'s catch-all and is dropped. (A group whose vacant flush was interrupted by a re-join is no longer `:vacant_flushing` — `join/3` already re-claimed it to `:occupied_pending` — so it is carried through as such.) `:occupied_pending` claims are kept and carried through; they are settled with `:ok` (step 7) once the new router has been told (callers parked on `Muster.join/3` are **not** cancelled).
4. Call `ExHashRing.Ring.set_nodes/2` with the new member list. The ring atomically swaps to a new generation; the prior generation is retained for one cycle.
5. **Find the moved groups and affected routers.** For each `:occupied`, `:cooldown`, or `:occupied_pending` group, ask the ring for both the new router (`find_node/2`) and the previous router (`find_historical_node/3` with `back: 1`). The groups whose router *changed* are the *moved* set; the distinct new routers of those groups are the *affected* routers. With consistent hashing the moved set is typically ~1/N of the candidate groups.
6. **Send each affected router a full snapshot — fire-and-forget.** For every affected router, dispatch **one** `:receive_node_state` RPC carrying *all* groups we hold routed to it — not just the moved ones (groups routed to this node are written to the local occupancy table directly). Each RPC goes to a short-lived monitored worker and **Scope does not wait** — `do_rebalance` returns as soon as the workers are dispatched, so the Scope mailbox keeps servicing `{:claim, …}` throughout the rebalance. Each worker reports back via a tagged `{:node_state_done, router, seq}` DOWN; a failure crashes Scope from that handler (see "Rebalance RPC failure"). The receiver replaces its entries for our node with the list, so the snapshot **must** be complete: a complete snapshot inserts our rows then deletes any older row of ours not in it, so sending only the moved groups would silently drop unchanged groups that still route there. A router that gained nothing is left untouched — its existing rows for us are still correct, and any group that moved *away* from it is cleared by its own `drop_stale_router_entries` (step 9).

    The receiver does **not** apply the snapshot from the RPC worker. `receive_node_state` hands it to the receiver's Scope as a synchronous `{:apply_snapshot, …}` call; Scope applies it under a **per-source seq guard** (it ignores any snapshot whose seq is not strictly greater than the highest already applied from that source). Serializing the apply through the one Scope process is what makes a *sequence* of overlapping rebalances safe: a late or reordered round — including an `:erpc`-timeout RPC that executes on the receiver long after the sender gave up (erpc does not cancel remote execution) — is dropped wholesale and can never resurrect a group a newer round already dropped. (Concurrent direct ETS writes from parallel RPC workers could not give this: the multi-row insert+delete is not atomic across workers.) The insert-then-delete order within an apply still keeps a concurrent reader on the *superset*, so the window over-delivers rather than missing a held group.
7. **Announce our view to every member for the readiness barrier (hybrid).** Each affected router learns our view from the snapshot itself: the `{:apply_snapshot, …}` carries `view_hash` and this round's seq (the *announce watermark*), and Scope folds the occupancy write and the `member_views` update into one indivisible apply — data committed *before* the view is recorded. Members that received *no* snapshot have nothing to fold the announcement into, so they get a cheap async `{:rebalance_marker, node(), view_hash, seq}` send instead — that is how their barrier learns "this source holds nothing for me" vs. "this source has not arrived yet". This keeps the RPC count at ~the announce-set size (not N per node) while still signalling every member. Because the snapshots are fire-and-forget, each affected router is recorded in `owed_snapshots` (stamped with this round's seq) until its worker acknowledges, and the **view heartbeat skips owed nodes**: a bare marker reaching such a node before its snapshot is applied would let it count us as agreed before our data lands (a missed delivery). The marker for an owed node rides the snapshot itself, after the data write. See the readiness barrier below.
8. Settle the `:occupied_pending` claims whose router changed: reply `:ok` to their parked waiters and move them to `:occupied`. This reply is now **optimistic** — it happens as the snapshot is dispatched, not after it is acknowledged. It is safe because while the snapshot is in flight the cluster is `:rebalancing`/`:converging`, so senders flood (`router/2`) rather than target a not-yet-populated occupancy row; no delivery is missed. If a snapshot ultimately fails, Scope crashes and the restart re-announces every locally-held group from the Partition tables, so the optimistic `:ok` self-heals.
9. Walk our own occupancy table and drop entries for groups we are no longer the router for (those entries will be re-announced to us by the original source nodes during their own rebalances). A foreign source's entry is only dropped if that source *demonstrably agrees* with the view being judged under — see "Stale router entries" below; rows that can't be judged yet are left in place and re-swept on the `:converging → :ready` transition, when every member has agreed.
10. Leave `:rebalancing` by recomputing `:status` from peer agreement — `:ready` if every member's latest view already matches ours (single-node clusters land here immediately), otherwise `:converging`.

### What callers see during the rebalance window

`Muster.router/2` returns `{:rebalancing, members}` for the entire duration.

`Muster.join/3`/`claim` is **not** blocked by a rebalance. Because the snapshot RPCs are fire-and-forget (step 6), Scope returns from `do_rebalance` immediately and keeps processing `{:claim, …}` calls throughout — a new claim is answered against the freshly-adopted ring rather than queuing behind the snapshot round. Only callers already parked in `:occupied_pending` for a group whose router changed are affected, and they are settled optimistically as the round dispatches (step 8).

### Router-readiness barrier

The `:rebalancing` status is *local* to each node and only protects senders on that node. It does not cover this ordering: node A finishes its rebalance and goes `:stable` while node B is still mid-rebalance, so a group that re-hashed onto a fresh router C is routed there by A before B has announced it to C. A and C *agree* on membership, and C is `:stable` — yet C's occupancy table is incomplete. Neither a membership-agreement check nor C's own status catches this, because the lag is in a *third* node's announcement.

The barrier closes it. Each broadcast is tagged with the sender's `:view_hash`. On the router, the fan-out path calls `Muster.can_decide?/2` before trusting the occupancy table:

```elixir
Muster.can_decide?(scope, sender_view_hash)
#  status == :ready          — ring settled AND every member agrees with our view
#  and view_hash == sender's — and the sender agrees with us on the node set
```

If either clause is false the router **cannot decide its targets and falls back to fanning out to all nodes** (the real connected cluster, not the ring's member view — a freshly-restarted Scope's ring is just `[node()]`). The two checks are complementary: the `:view_hash` comparison catches sender/router *disagreement* (and the Scope-restart window, where a restarted router's view shrinks to `[node()]` and so mismatches), while `:ready` (vs. `:converging`) catches the *convergence* gap above — membership agreement holds, but not every holder has re-announced yet. `:ready` subsumes the old separate "not rebalancing" check, since the ring is necessarily settled by the time we reach it.

`:status == :ready` is derived from `member_views`, a map of **each peer's most-recently-announced `{view hash, announce watermark}`**. A peer announces its view by finishing its own rebalance — either via its data-carrying `:receive_node_state` RPC (which echoes the sender's view and that round's seq) or, for a member that sent no snapshot, via a cheap async `{:rebalance_marker, source, view_hash, seq}` (step 7). The handshake (`:muster_discover`/`_ack`) also piggybacks each side's view and watermark, so a node seeds `member_views` immediately — important after a Scope restart, where it would otherwise be empty. We are `:ready` once every member's latest view equals ours; otherwise `:converging`.

The map is **newest-seq-wins and never reset across rebalances**, which is what makes the barrier converge. An announcement that arrives *before* the receiver has adopted that view is simply stored as that peer's latest view rather than discarded; the moment the receiver catches up to the same view, the agreement check passes. Picking the newest *seq* rather than the latest *arrival* matters because announcements travel on two channels (async dist sends and `:receive_node_state` RPCs), so an older marker can overtake a newer one — the seq comparison makes that reordering harmless. The degraded state is the safe one: any disagreement or missing entry keeps the node in `:converging`, so it floods (never misses) and self-corrects as announcements arrive.

The one place we **do** drop an entry is when a peer leaves: the `:DOWN` handler deletes that node's `member_views` row alongside its occupancy rows. This is required because the announce watermark is a per-VM `:erlang.unique_integer([:monotonic])` that resets to the same base on every fresh VM — so a node that restarts under the **same node name** (an ordinary pod restart) comes back with a *lower* seq than the entry we still hold from its dead incarnation. Without the delete, newest-seq-wins would permanently reject the restart's announcements (the view heartbeat carries the same low seq too), stranding us in `:converging` for any view that differs from the stale one. Dropping the row on `:DOWN` is safe — the peer is gone, so its prior announcement is moot, and discovery re-seeds a fresh row when it returns; it does not weaken the "never reset across rebalances" invariant, which is only about not discarding a *live* peer's early announcements. (`test/forum/muster_distributed_test.exs` forces the regression deterministically — it burns one incarnation's monotonic counter so its stored watermark is far above any same-named restart's, then asserts the restarted node re-converges anyway.)

When membership changes *cascade* — a second node joins while the cluster is still `:converging` from the first — each node simply rebalances again out of `:converging`, re-handing its groups to the final routers, and only the final view ever fully converges. A *lagging* node may transiently go `:ready` for the already-superseded intermediate view (the stale announcements it processes are mutually consistent, and the occupancy data for that view was committed before they were sent), which is safe: senders already on the newer view carry a mismatching hash — so that router floods for them — and the higher-seq announcements supersede the stale agreement moments later. (`test/forum/muster_distributed_test.exs` forces this cascade with a parked laggard and asserts the holder re-routes its group across both joins, never itself trusts the intermediate view, every superseded router sweeps its stale row, and every node's last status word is `:ready` for the final view.)

There is no readiness *timeout* — `:converging` is a fully-functional safe state (the node still routes as a sender and floods as a router), not a blocking wait, so there's nothing to time out. To bound the worst case, each node re-announces its current view to every member every `:view_heartbeat_interval_ms` (default 10 s). The event-driven path (rebalance announcements + the discovery handshake) normally converges in milliseconds; the heartbeat is the backstop that heals a dropped announcement *without* needing a membership change, turning a theoretical "stuck flooding forever" into "stuck for at most one heartbeat." It's idempotent with `member_views` (newest-seq-wins; the heartbeat re-sends the current watermark), so a redundant heartbeat costs only a small message per member. The heartbeat **skips any node in `owed_snapshots`** (a fire-and-forget snapshot still in flight from this node's last rebalance): that node's marker rides the snapshot, after the data is applied, and a premature bare marker would let it trust an occupancy table we haven't populated yet. The snapshot worker's `:node_state_done` clears the node, so the next heartbeat resumes covering it.

Because `:view_hash` is content-derived (`phash2` of the sorted node set) rather than a counter, it survives Scope restarts unchanged — a restarted router recomputes the same hash once it re-converges, and mismatches in the meantime.


### Cost of a rolling deploy

Because the ring is consistent-hashed, a 100-node rolling deploy that grows the new cluster 1 → 100 moves ~1 group out of every 100 candidates per node-add, on average. Compared to a `phash2`-based scheme — where adding one node remaps ~all groups — this slashes the per-event announce-set and keeps the rebalance window short, which in turn keeps the broadcast-fan-out window short.

---

## Failure scenarios

### Join-time RPC failure

The synchronous `:occupied` call from the source node to the router can fail (network blip, router overloaded, router Scope crashed mid-call). When it does:

* The Scope replies `{:error, :rpc_failed}` to the waiting caller.
* `Muster.join/3` propagates this to its caller.
* **Nothing is inserted into the local Partition.** This is the load-bearing invariant: a row in the Partition means the router has been notified.
* The next `Muster.join/3` for the same group naturally retries — local count is still 0, so it goes through the claim path again.

### Vacant-time RPC failure

`:vacant_batch` RPCs to the router are best-effort but **retried**. A failed batch is logged and its groups are returned to `:vacant_queued`, so the next flush re-sends them. The group keeps being re-sent until the router acknowledges it, which means the router cannot accumulate a permanently stale `{group, source_node}` entry from a transient failure — the flush is a self-draining retry loop. (A failure never crashes the local Scope or fails a `leave/3` call; `leave/3` only touches the Partition.)

In addition to the retry, two event-driven cleanups still apply:

* If the source node leaves the cluster, the router's `:DOWN` handler clears all entries keyed by that node.
* A rebalance that moves a group's routing away from the old router triggers `drop_stale_router_entries` there.

**Occupancy rows are versioned to make this race-free.** A timed-out `:vacant_batch` is a particular hazard: `:erpc.call` does **not** cancel the remote execution on timeout, so a DELETE can still land on the router *after* the source has re-claimed the group (because a join arrived) with a fresh `:occupied` INSERT — silently clobbering a live entry that nothing periodically re-asserts. To prevent this, every occupancy row is stored as `{{group, source_node}, seq}`, where `seq` is a per-source monotonic stamp (`:erlang.unique_integer([:monotonic])`) assigned by the source **at dispatch time**. A re-claim's `:occupied` is dispatched *after* the `vacant_batch` it races (the join arrives later), so `next_seq` gives it a strictly higher `seq`; the router's `vacant_batch` deletes a row only if its `seq` is **no newer** than the row's (an atomic `select_delete` guard), so the stale, lower-`seq` DELETE is ignored. Seqs are only ever compared for the same `{group, source}` key — whose writes all originate on one node — so the comparison is always within a single VM's monotonic sequence and survives Scope restarts. (`test/forum/muster_distributed_test.exs` forces exactly this arrival order on a real router with snabbkaffe — the stale DELETE applied strictly after the re-claim's INSERT — and asserts the row survives.)

### Rebalance RPC failure

Snapshot dispatch is fire-and-forget on the sender (Scope does not wait), but the receiver-side apply is a synchronous call (`receive_node_state` calls `{:apply_snapshot, …}` into the receiver's Scope and waits for the reply), so any failure ultimately fails the snapshot's `:erpc` and crashes the **sender** via the `:node_state_done` handler:

* **Transport failure.** If a snapshot's `:erpc` cannot reach the router — node down, etc. — the monitored worker reports `{:error, _}` and the `:node_state_done` handler **re-raises. The sender's Scope crashes.**
* **Apply failure.** If applying the snapshot raises, the **receiver's** Scope crashes mid-call — so the caller's `GenServer.call` exits, the `:erpc` returns an error, and the sender crashes too (exactly the transport-failure path). Both restart. (A late or stale apply can't corrupt anything — the per-source seq guard drops it and still replies `:ok`.)

After a crash the supervisor restarts the Scope, whose `init/1`:

* Resets the member list to `[node()]`, the `:status` persistent_term to `:ready`, and `:view_hash` to `phash2([node()])` (forgetting the cluster view). A sender that still holds the pre-crash multi-node `:view_hash` will mismatch this single-node hash, so `can_decide?/2` returns false and broadcasts to the restarted router fan out to all nodes until it re-converges.
* Walks the Partition entries (which survive Scope's death because they live in `:public, :named_table` ETS owned by the Supervisor) and rebuilds `group_states` by marking every locally-held group as `:occupied`.
* Re-broadcasts the discovery message; peers respond; `recompute_members` runs again.

The supervisor restart strategy ensures the cluster eventually re-converges. During the restart window — between the crash and `init/1` running — the `:status` persistent_term is left at `:rebalancing`, so `Muster.router/2` returns `{:rebalancing, members}` and callers correctly fan out. (`test/forum/muster_distributed_test.exs` exercises this by `inject_crash`ing the first snapshot apply on a fresh router: that crashes the router's Scope, which fails the source's RPC and crashes the source too — both restart, the source re-snapshots once the router is back, and the cluster converges with the row in place.)

### Scope crash for other reasons

Same recovery path: Partition data is preserved (ETS is owned by the Supervisor, not Scope), `init/1` walks it to rebuild `group_states`, discovery and rebalance run, peers learn about us anew.

### Stale router entries

Whenever cluster membership changes and a group's router shifts from B to C, B briefly holds a stale `{group, source}` entry. Three things clean it up:

* B's own `drop_stale_router_entries` sweep — run at each rebalance and again on the `:converging → :ready` transition — removes entries whose group is no longer routed to B.
* If B is removed from the cluster (the cause of the rebalance), the entries die with B's Scope process.
* The source node's periodic vacant flush re-sends queued vacancies to the *current* router, so a vacancy that was never delivered (or was delivered to a node that has since stopped being the router) is eventually applied where it matters.

Stale entries do not cause incorrect broadcasts because broadcasters always route via the *current* router.

**The sweep is guarded — a row is only judged under a view its source has agreed to.** `drop_stale_router_entries` deletes a foreign source's row only when (a) that source's last-announced view (`member_views`) equals the view our ring currently implements, and (b) the row's seq is at or below that announcement's watermark. Without the guard, two ordering races lose data permanently:

* *Asymmetric views.* Our ring can transiently contain a node the source never saw (e.g. an ephemeral joiner we registered before its death propagated). Judged under that ring, the source's group may hash to the phantom node — but the source never re-announces it anywhere else, so deleting the row leaves a permanent hole. Consistent-hashing monotonicity protects *subset* views (a group that routes to us in the source's view also routes to us in any subset of it containing us — which is why plain joins are safe in any interleaving), but it says nothing once the views are not nested. The view-agreement check (a) restores the comparison to a single shared view.
* *Data ahead of markers.* A source's `:occupied`/`:vacant_batch` writes still go straight to the occupancy ETS from their RPC workers (only the rare *snapshot* apply is serialized through Scope), and they do **not** touch `member_views` — so a freshly-claimed row can carry a seq higher than the source's last-announced watermark. (Snapshot rows no longer cause this: Scope folds a snapshot's occupancy write and its `member_views` update into one atomic apply, so for snapshot rows the table can't run ahead of the marker.) A row stamped above the source's watermark belongs to an announce round we have not processed yet and must not be judged under the older view; check (b) skips it.

Rows the guard skips are harmless — a non-router's rows are never consulted, so they cost only memory — and they are re-judged on the `:ready` transition, by which point every member has announced agreement with our view and the sweep can collect everything genuinely stale. (`test/forum/muster_test.exs` drives the guard deterministically — a router adopts a view the source has not, under which the group hashes away, and the row must survive — while `test/forum/muster_distributed_test.exs` covers the real-cluster end-states black-box: a joiner reaching `:ready` and an ephemeral node's join/death churn both leave the snapshotted row intact.)

### Network partition

If A and B can no longer reach each other, they each detect peer `:DOWN`, rebalance independently, and route to whoever they can see. When the partition heals, the rejoin runs through discovery → rebalance and the two sub-clusters merge. Broadcasts during the split are delivered to the sub-cluster the sender can see — Muster does not perform anti-entropy beyond this, so a broadcast during a partition won't reach the other side after the heal.

(`test/forum/muster_distributed_test.exs` exercises the harsher *asymmetric* variant: two peers split while a third node still sees both, so the peers' `{T, self}` views and T's three-node view all disagree. The readiness barrier keeps every node in `:converging` — routers flood rather than trust their tables — the stale-entry sweeps run under the split views must not delete the third node's snapshotted rows, and after the heal everyone re-converges to `:ready` with occupancy intact.)

## Observability

Muster logs its lifecycle on two tiers, all prefixed `Muster[node|scope]`:

* **`info`** — the rare, cluster-level events: rebalance start (old → new members + view hash), a one-line rebalance summary (groups held, groups moved, routers re-snapshotted), every `:status` transition (`:rebalancing → :converging → :ready`), and node up / peer down. These are safe to leave on; they fire only on real change.
* **`debug`** — the per-group churn: each claim decision (occupied locally, dispatched to a router, reclaimed from cooldown/queue/in-flight flush, parked behind an in-flight `:occupied`), `:occupied` RPC results, a group entering cooldown, cooldown expiry (queued or reclaimed), and each vacant flush / batch acknowledgement.

Bump the level to watch the per-group flow while playing:

```elixir
Logger.configure(level: :debug)
```

When Muster is embedded in a host app (e.g. Realtime), that app's Logger setup prints these lines. The standalone `forum` app ships with `config :logger, backends: []`, so if you're playing *inside* `forum/` (`iex -S mix`) attach a console handler first:

```elixir
:logger.add_handler(:console, :logger_std_h, %{config: %{type: :standard_io}})
:logger.set_primary_config(:level, :debug)
```

For a point-in-time snapshot, `Forum.Muster.dump(scope)` prints the lifecycle status, view hash, ring members, peers, each peer's last-announced view hash, the per-group state machine, and the router-role occupancy table (`group => [source_node]`), then returns `:ok`:

```
iex> Forum.Muster.dump(:topics)
Muster :topics @ :node1@host
  status:       :ready
  view_hash:    123456789
  members:      [:node1@host, :node2@host]
  ...
group_states:
  :occupied (2): ["room:1", "room:2"]
occupancy (as router):
  "room:1" => [:node1@host]
```

Node up/down and group vacancy are also emitted as `:telemetry` events (`[:forum, scope, :node, :up | :down]`, `[:forum, scope, :group, :vacant]`) if you'd rather attach a handler than read logs.

## Trace-based testing (`Snabbkaffe`)

Concurrent code is awkward to test with mocks and `Process.sleep`. The
[snabbkaffe](https://github.com/kafka4beam/snabbkaffe) library instead lets you
assert on the *trace* of events a system emitted, and to block until a specific
event happens. Snabbkaffe is a BEAM library, but its instrumentation ships as
Erlang `-include` macros that Elixir can't use, so `lib/snabbkaffe.ex` provides
the Elixir macro counterparts (the `Snabbkaffe` module).

**Trace points are discarded outside `:test`.** A `tp/2` call compiles to a real
collector call in `MIX_ENV=test` and to `_ = data; :ok` everywhere else (the data
expression is still evaluated, matching snabbkaffe's prod semantics). So you can
sprinkle them through `lib/` code at near-zero production cost:

```elixir
defmodule Forum.Muster do
  use Snabbkaffe

  # ... somewhere in the rebalance path:
  tp(:muster_rebalance_done, %{scope: scope, members: members})
end
```

In a test, `check_trace/2` runs an action, collects the trace, and hands it to a
check function (which passes unless it raises — use ordinary `assert`):

```elixir
use Snabbkaffe

test "rebalance converges" do
  check_trace(
    fn ->
      add_node(:node2)
      block_until(%{:"$kind" => :muster_rebalance_done}, 1000)
    end,
    fn trace ->
      assert [%{members: members}] = of_kind(:muster_rebalance_done, trace)
      assert :node2 in members
    end
  )
end
```

`Forum.Muster.Scope` emits trace points you can build assertions on:

* `:muster_rebalance_start` — `%{scope, node, from, to, view_hash}`.
* `:muster_status_change` — `%{scope, node, from, to, members, view_hash}`, on
  every `:rebalancing → :converging → :ready` transition.
* `:muster_peer_registered` — `%{scope, node, peer}`, when discovery pairs a peer.
* `:muster_node_state_received` — `%{scope, node, source, view_hash, groups}`,
  after a `:receive_node_state` snapshot has been committed on the receiver.
* `:muster_occupied` — `%{scope, node, group, source, seq}`, after an
  `:occupied` INSERT has been committed on the router.
* `:muster_vacant_batch` — a `tp_span/3` around the router-side batched DELETE
  (match `:"$span"` of `:start` / `{:complete, _}`); the `:start` event fires
  before the deletes, so forcing an ordering on it parks the whole batch.
* `:muster_drop_stale_entry` — `%{scope, node, group, source}`, per row the
  stale-entry sweep actually deletes (emitted after the delete, so blocking on
  it implies the row is gone).
* `:muster_group_state` — `%{scope, node, group, state}`, on every per-group
  state-machine transition on the source node (`state: nil` means the group
  was forgotten). Lets tests `block_until` a group reaches e.g.
  `:vacant_queued` instead of polling.

All are discarded outside `:test`.

### Distributed traces

The collector runs on the node that calls `check_trace`. To capture trace points
emitted on *other* nodes (e.g. `:peer` nodes in `muster_distributed_test.exs`),
tell each remote node to forward its events to the collector:

```elixir
:snabbkaffe.forward_trace(remote_node)
```

Attach it **before** the remote work starts so no event is missed — a remote
`tp` emitted before forwarding is wired up goes nowhere. With forwarding on, a
single `check_trace` sees events from the whole cluster, which is how the
distributed test asserts that *every* node re-converges to `:ready` (matching on
the final `view_hash`) after a node joins. The remote nodes only need snabbkaffe
on their code path — no collector of their own.

Available macros: trace points `tp/2,3` and `tp_span/3,4`; running/checking with
`check_trace/2,3`; collector lifecycle `start_trace/0`, `stop/0`,
`collect_trace/0,1`; synchronisation `block_until/1,2,3`, `wait_async_action/2,3`,
`retry/3`; trace querying `of_kind/2`, `projection/2`, `find_pairs/3,4`,
`causality/3,4`, `strict_causality/3,4`; fault injection `force_ordering/2,3`,
`inject_crash/2,3`; plus `give_or_take/3` and the `match_event/1` predicate
builder. Patterns are ordinary Elixir patterns (snabbkaffe's `?match_event`
becomes `match?/2`); the event's kind lives under the `:"$kind"` key, so prefer
`of_kind/2` for filtering. See the `Snabbkaffe` moduledoc for details.
