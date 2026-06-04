# Forum

Forum is a scalable, distributed process-group library for Elixir/OTP. It ships two primitives that share the same supervision/partition machinery but solve different problems:

* **`Forum.Census`** — eventually-consistent counting of group membership across the cluster. Use when you need to know "how many processes are in group X right now" without paying per-join/leave network traffic.
* **`Forum.Muster`** — precisely-targeted fan-out broadcast. Use when you want to send a message to every process that has joined a group, anywhere in the cluster, without blindly broadcasting to nodes that don't care.

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

### The designated node

For each group, exactly one node in the Muster cluster is the **designated** node, chosen by **consistent hashing** over the sorted member list (via [`ex_hash_ring`](https://hexdocs.pm/ex_hash_ring), 128 vnodes per node by default). Every node computes the same designated independently from the same ring (no consensus needed — the member list is the only input). Consistent hashing matters at rebalance time: when a node joins or leaves a cluster of size *N*, only ~1/*N* of the groups change their designated, instead of nearly all groups (as a naive `phash2(group, length(members))` would produce).

The designated node owns the authoritative "which nodes hold this group" set. When the first local member of a group joins on node A, A sends a synchronous `:occupied` notification to the designated node. When the last local member leaves (after a cooldown — see below), A sends `:vacant`. The designated keeps a table keyed by `{group, node}` and uses it to forward broadcasts.

### Public API

```elixir
Forum.Muster.join(scope, group, pid)        # :ok | {:error, :rpc_failed | :not_local | ...}
Forum.Muster.leave(scope, group, pid)       # :ok
Forum.Muster.broadcast(scope, group, msg)   # :ok — async fan-out
Forum.Muster.designated(scope, group)       # {:ok, node} | {:rebalancing, [node]}
Forum.Muster.members(scope)                 # [node]
Forum.Muster.local_members(scope, group)    # [pid]
Forum.Muster.local_member?(scope, group, pid)
Forum.Muster.local_member_count(scope, group)
```

Start it under supervision with a scope name (use a different scope from any Census on the same node):

```elixir
children = [
  {Forum.Muster, [:topics, partitions: 8, vacancy_cooldown_ms: 30_000]}
]
```

### How join works

```
caller                       local Scope                 designated Scope (remote)
  |                              |                                    |
  | Partition.member_count > 0?  |                                    |
  | yes  -- Partition.join, :ok  |                                    |
  | no                           |                                    |
  |----- {:claim, group} ------->|                                    |
  |                              | designated == self?                |
  |                              |   yes: write occupancy, reply :ok  |
  |                              |   no: spawn worker --------------->|
  |                              |                                    | insert {{group, A}}
  |                              | <---- :ok ------------------------ |
  |                              | reply :ok to all waiters           |
  | <----- :ok ----------------- |                                    |
  | Partition.join(group, pid)   |                                    |
```

Key invariants:

* The RPC happens **before** `Partition.join`, so an entry in the Partition implies the designated has been told.
* If the RPC fails the caller gets `{:error, :rpc_failed}` and the Partition stays empty, so the next `join/3` naturally retries.
* Concurrent `join/3` calls for the same fresh group dedup into **one** RPC; the rest of the callers piggyback on the in-flight `:occupied_pending` state.
* The Scope GenServer never blocks on an RPC — it dispatches the call to a short-lived worker process and parks the waiters in `{:occupied_pending, [from | …]}`. The worker reports back with `{:rpc_done, …}`.

### How leave works (and the cooldown)

`leave/3` just does `Forum.Partition.leave`. When the local count for the group goes 1 → 0, Partition emits a `[:forum, scope, :group, :vacant]` telemetry event. Scope picks this up and enters the **cooldown** state for the group (default 30 s, configurable via `:vacancy_cooldown_ms`). During cooldown:

* The designated still believes we hold the group — no RPC has been sent.
* If a new `join/3` arrives, Scope cancels the cooldown timer and goes back to `:occupied` — no network traffic. This is the whole reason cooldown exists: a quick join/leave/join cycle costs zero RPCs.
* If the cooldown expires with the group still empty, Scope sends a `:vacant` RPC to the current designated. Failure here is logged and tolerated — the designated will clean stale entries on its next rebalance anyway.

---

## Rebalance — what happens when nodes join or leave

Each Muster scope runs one `ExHashRing.Ring` process (linked to the scope's Scope GenServer). The ring stores the member set and provides ETS-backed lookups; mutations bump a generation counter and keep the previous generation accessible for delta computation.

A small `persistent_term` key tracks whether the cluster view is in flux:

```
{Forum.Muster, scope, :status} = :stable | :rebalancing
```

Reads are cheap (atom-value persistent_term) and `Muster.designated/2` consults the ring only when status is `:stable`; when `:rebalancing` it returns the full member list so callers can fan out.

### Trigger

A rebalance starts on every node whenever its view of the cluster changes:

* `:nodeup` from `:net_kernel` (after libcluster, manual `Node.connect/1`, etc.) → if the new node is also running this scope's Muster, the discovery handshake adds it to `peers` → `recompute_members` runs.
* A peer's Scope process `:DOWN` (crash or disconnect) → peer is removed → `recompute_members` runs.

### What `recompute_members` does

1. Compute the new sorted member list. If unchanged, do nothing.
2. Flip `:status` to `:rebalancing`. From this point, `Muster.designated/2` returns `{:rebalancing, members}` for all groups; broadcasters fan out to every member.
3. **Cancel in-flight `:occupied_pending` claims.** Each waiting caller receives `{:error, :rebalance_in_progress}`. `Muster.join/3` retries this internally (up to 3 times, 20 ms apart), so callers don't see it unless the cluster is thrashing.
4. Call `ExHashRing.Ring.set_nodes/2` with the new member list. The ring atomically swaps to a new generation; the prior generation is retained for one cycle.
5. **Compute the delta**: for each `:occupied` or `:cooldown` group, ask the ring for both the new designation (`find_node/2`) and the previous designation (`find_historical_node/3` with `back: 1`). Only groups whose designation actually changed are in the announce-set. With consistent hashing this is typically ~1/N of the candidate groups instead of ~all of them.
6. For each `{new_designated, groups}` pair, send **one** `:receive_node_state` RPC bundling all groups for that destination. The receiver clears its prior entries for our node and inserts the fresh list.
7. Walk our own occupancy table and drop entries for groups we are no longer designated for (those entries will be re-announced to us by the original source nodes during their own rebalances).
8. Flip `:status` back to `:stable`.

### What callers see during the rebalance window

`Muster.designated/2` returns `{:rebalancing, members}` for the entire duration.


### Cost of a rolling deploy

Because the ring is consistent-hashed, a 100-node rolling deploy that grows the new cluster 1 → 100 moves ~1 group out of every 100 candidates per node-add, on average. Compared to a `phash2`-based scheme — where adding one node remaps ~all groups — this slashes the per-event announce-set and keeps the rebalance window short, which in turn keeps the broadcast-fan-out window short.

---

## Failure scenarios

### Join-time RPC failure

The synchronous `:occupied` call from the source node to the designated can fail (network blip, designated overloaded, designated Scope crashed mid-call). When it does:

* The Scope replies `{:error, :rpc_failed}` to the waiting caller.
* `Muster.join/3` propagates this to its caller.
* **Nothing is inserted into the local Partition.** This is the load-bearing invariant: a row in the Partition means the designated has been notified.
* The next `Muster.join/3` for the same group naturally retries — local count is still 0, so it goes through the claim path again.

### Vacant-time RPC failure

`:vacant` RPCs to the designated are best-effort. A failure is logged and the state machine transitions back to `:none`. The designated retains a stale `{group, source_node}` entry until either:

* The source node leaves the cluster (the designated's `:DOWN` handler clears all entries keyed by that node), or
* The next rebalance touches that group and `drop_stale_designated_entries` removes it.

This tolerance is deliberate — we don't want a transient leave-time RPC failure to crash the local Scope or fail a `leave/3` call.

### Rebalance RPC failure

If any `:receive_node_state` call raises or returns `{:error, _}`, `rebalance/2` re-raises. **Scope crashes.** The supervisor restarts it. Scope's `init/1`:

* Resets `:membership` to `{:stable, {node()}}` (forgetting the cluster view).
* Walks the Partition entries (which survive Scope's death because they live in `:public, :named_table` ETS owned by the Supervisor) and rebuilds `group_states` by marking every locally-held group as `:occupied`.
* Re-broadcasts the discovery message; peers respond; `recompute_members` runs again.

The supervisor restart strategy ensures the cluster eventually re-converges. During the restart window, `Muster.designated/2` returns `{:rebalancing, members}` (because the pre-crash flag was left `true` until init resets it), so callers correctly fan out.

### Scope crash for other reasons

Same recovery path: Partition data is preserved (ETS is owned by the Supervisor, not Scope), `init/1` walks it to rebuild `group_states`, discovery and rebalance run, peers learn about us anew.

### Stale designated entries

Whenever cluster membership changes and a group's designated shifts from B to C, B briefly holds a stale `{group, source}` entry. Two things clean it up:

* B's own rebalance does `drop_stale_designated_entries`, removing any entry whose group is no longer designated to B.
* If B is removed from the cluster (the cause of the rebalance), the entries die with B's Scope process.

Stale entries do not cause incorrect broadcasts because broadcasters always route via the *current* designated.

### Network partition

If A and B can no longer reach each other, they each detect peer `:DOWN`, rebalance independently, and route to whoever they can see. When the partition heals, the rejoin runs through discovery → rebalance and the two sub-clusters merge. Broadcasts during the split are delivered to the sub-cluster the sender can see — Muster does not perform anti-entropy beyond this, so a broadcast during a partition won't reach the other side after the heal.
