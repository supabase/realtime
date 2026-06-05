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

A periodic **vacant flush** (every `:vacant_flush_interval_ms`, default 5 s) then drains the queue: it buckets all `:vacant_queued` groups by their *current* router and sends **one** `:vacant_batch` RPC per router (groups routed to self are pruned locally). On success the groups are forgotten; **on failure they go back to `:vacant_queued`** and the next flush retries them. The flush is therefore self-draining: a transient RPC failure — or a router that was briefly overloaded — no longer leaves a permanently stale `{group, node}` entry, because the group keeps being re-sent until the router acknowledges it. Because the router computed at flush time is always the current one, a rebalance that moved a queued group's router simply routes the next flush to the right node.

---

## Rebalance — what happens when nodes join or leave

Each Muster scope runs one `ExHashRing.Ring` process (linked to the scope's Scope GenServer). The ring stores the member set and provides ETS-backed lookups; mutations bump a generation counter and keep the previous generation accessible for delta computation.

A small `persistent_term` key tracks whether the cluster view is in flux:

```
{Forum.Muster, scope, :status} = :stable | :rebalancing
```

Reads are cheap (atom-value persistent_term) and `Muster.router/2` consults the ring only when status is `:stable`; when `:rebalancing` it returns the full member list so callers can fan out.

### Trigger

A rebalance starts on every node whenever its view of the cluster changes:

* `:nodeup` from `:net_kernel` (after libcluster, manual `Node.connect/1`, etc.) → if the new node is also running this scope's Muster, the discovery handshake adds it to `peers` → `recompute_members` runs.
* A peer's Scope process `:DOWN` (crash or disconnect) → peer is removed → `recompute_members` runs.

### What `recompute_members` does

1. Compute the new sorted member list. If unchanged, do nothing.
2. Flip `:status` to `:rebalancing`. From this point, `Muster.router/2` returns `{:rebalancing, members}` for all groups; broadcasters fan out to every member.
3. **Normalize in-flight pending states.** A `:vacant_queued` entry is left untouched — we don't hold the group (so it isn't announced), but the next flush after the ring update re-routes it to the group's *current* router, which drains any stale entry the old router still holds. A `{:vacant_flushing, []}` entry (a batch RPC in flight, no waiters) is rewritten back to `:vacant_queued` so the next flush re-sends to the post-rebalance router; the in-flight worker's late result is dropped. A `{:vacant_flushing, waiters}` entry (a claim arrived while the batch was in flight) is rewritten to `{:occupied_pending, waiters}` so the rebalance re-announces it and settles the waiters. `:occupied_pending` claims are kept and carried through; they are settled with `:ok` (step 7) once the new router has been told (callers parked on `Muster.join/3` are **not** cancelled).
4. Call `ExHashRing.Ring.set_nodes/2` with the new member list. The ring atomically swaps to a new generation; the prior generation is retained for one cycle.
5. **Compute the delta**: for each `:occupied`, `:cooldown`, or `:occupied_pending` group, ask the ring for both the new router (`find_node/2`) and the previous router (`find_historical_node/3` with `back: 1`). Only groups whose router actually changed are in the announce-set. With consistent hashing this is typically ~1/N of the candidate groups instead of ~all of them.
6. For each `{new_router, groups}` pair, send **one** `:receive_node_state` RPC bundling all groups for that destination (groups whose new router is this node are written to the local occupancy table directly). The receiver clears its prior entries for our node and inserts the fresh list.
7. Settle the `:occupied_pending` claims whose router changed: reply `:ok` to their parked waiters and move them to `:occupied`. The new router has just been told via `:receive_node_state`, so the claim is satisfied.
8. Walk our own occupancy table and drop entries for groups we are no longer the router for (those entries will be re-announced to us by the original source nodes during their own rebalances).
9. Flip `:status` back to `:stable`.

### What callers see during the rebalance window

`Muster.router/2` returns `{:rebalancing, members}` for the entire duration.


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

### Rebalance RPC failure

If any `:receive_node_state` call raises or returns `{:error, _}`, `do_rebalance/2` re-raises. **Scope crashes.** The supervisor restarts it. Scope's `init/1`:

* Resets the member list to `[node()]` and the `:status` persistent_term to `:stable` (forgetting the cluster view).
* Walks the Partition entries (which survive Scope's death because they live in `:public, :named_table` ETS owned by the Supervisor) and rebuilds `group_states` by marking every locally-held group as `:occupied`.
* Re-broadcasts the discovery message; peers respond; `recompute_members` runs again.

The supervisor restart strategy ensures the cluster eventually re-converges. During the restart window — between the crash and `init/1` running — the `:status` persistent_term is left at `:rebalancing`, so `Muster.router/2` returns `{:rebalancing, members}` and callers correctly fan out.

### Scope crash for other reasons

Same recovery path: Partition data is preserved (ETS is owned by the Supervisor, not Scope), `init/1` walks it to rebuild `group_states`, discovery and rebalance run, peers learn about us anew.

### Stale router entries

Whenever cluster membership changes and a group's router shifts from B to C, B briefly holds a stale `{group, source}` entry. Three things clean it up:

* B's own rebalance does `drop_stale_router_entries`, removing any entry whose group is no longer routed to B.
* If B is removed from the cluster (the cause of the rebalance), the entries die with B's Scope process.
* The source node's periodic vacant flush re-sends queued vacancies to the *current* router, so a vacancy that was never delivered (or was delivered to a node that has since stopped being the router) is eventually applied where it matters.

Stale entries do not cause incorrect broadcasts because broadcasters always route via the *current* router.

### Network partition

If A and B can no longer reach each other, they each detect peer `:DOWN`, rebalance independently, and route to whoever they can see. When the partition heals, the rejoin runs through discovery → rebalance and the two sub-clusters merge. Broadcasts during the split are delivered to the sub-cluster the sender can see — Muster does not perform anti-entropy beyond this, so a broadcast during a partition won't reach the other side after the heal.
