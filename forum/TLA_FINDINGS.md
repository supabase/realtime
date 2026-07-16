# Forum.Muster — TLA+ model findings

Status: **Finding A found, modeled, reproduced, and FIXED (B1) — fix
model-checked and shipped.** This document is the checkpoint so work can resume.

Two models:

* `tla/Muster.tla` (+ `.cfg`) — the baseline routing model that **exhibits**
  Finding A (`NoMissedDelivery` is violated).
* `tla/Muster2.tla` (+ `.cfg`) — the same model plus the **B1 two-phase view
  adoption** fix; `NoMissedDelivery` **holds** (see "The B1 fix" below).

Both model Muster's core **routing-safety** story: *when a broadcast is routed to
a router that trusts its occupancy table, does it reach every live holder of the
group?*

## How to run

```bash
cd forum/tla
# Java is available via mise (Amazon Corretto 26); TLC 2.19 is in ../tla2tools.jar.
# TLC needs a writable tmp dir and a local socket, so point java.io.tmpdir at a
# writable dir and run outside the command sandbox (needs loopback sockets).
mise exec java@corretto-26.0.1.8.1 -- \
  java -Djava.io.tmpdir="$TMPDIR" -XX:+UseParallelGC -cp ../tla2tools.jar \
  tlc2.TLC -workers auto -deadlock -config Muster.cfg Muster.tla
```

`-deadlock` disables deadlock detection: the model is finite because the
per-source seq counter is bounded (`MaxSeq`), so behaviours naturally terminate;
that termination is not a real deadlock and would otherwise mask deeper states.

Config: `Nodes = {1,2,3}`, `MaxSeq = 3`. ~105k distinct states, ~1s.

## What is modeled (and how it maps to the code)

| Model | Code |
|---|---|
| `Nodes`, `up[n]` (down is permanent) | Muster cluster nodes; user assumption "nodes cannot come back and reset seq" |
| ONE group `g`, `holds[n]` | node n has ≥1 local member of g (ground truth a broadcast must reach) |
| `view[n]` (a set) | the node's sorted member list / cluster view. **The `phash2(members)` view-hash is modeled as the set itself** (equal sets ⇒ equal hash; no hash collisions modeled) |
| `Router(V) = min(V)` | `ExHashRing.Ring.find_node`. `min` is a faithful *instance* of consistent hashing for the one property non-barrier paths rely on: **subset-monotonicity** (`r` routes g in `V` ∧ `r ∈ V' ⊆ V` ⇒ `r` routes g in `V'`). See caveats. |
| `occ[r][s] = [present, seq]` | the Scope router-role occupancy table for a single group; per-`{group,source}` last-writer-wins register |
| seq-guarded `ApplyPresent` (strict `>`) / `ApplyTomb` (`>=`) | `upsert_if_newer` / `tombstone_if_newer` |
| `mv[r][s] = [known, hv, seq]` | `member_views`, newest-seq-wins |
| `Ready(r)`, `CanDecide(r, senderView)` | `ready?/1`, `can_decide?/2` (status `:ready` ⇔ `Ready`; `:converging`/`:rebalancing` ⇒ flood) |
| `owed[s]` | `owed_snapshots` (marker suppression: no bare marker to a router we owe a snapshot) |
| `msgs` set, any `Deliver*` step, any time | Erlang dist / `:erpc`: a dispatched RPC lands later, in any order, never cancelled |
| `HolderJoin` writes the router row atomically | `join/3`: local-router path writes the occupancy row in the same call; remote path registers the member only *after* the `:occupied` RPC is acked — so becoming a committed holder is atomic with the router knowing |
| `HolderLeave` → async `vacant` (or self-tombstone) | `leave/3` + cooldown + vacant flush (fire-and-forget, seq-guarded) |
| self-row re-assert folded into `Discover`/`DetectDown` | `do_rebalance` re-upserts local self-rows synchronously, before `:status` leaves `:rebalancing` |
| `SendSnapshot` (data+marker atomic) / `SendMarker` (bare) | rebalance snapshot vs bare `rebalance_marker` / view heartbeat |
| `DetectDown` wipes departed node's rows/mv | peer `:DOWN` handler (all of d's rows, since d never restarts) |

### The safety property

`NoMissedDelivery`: for every live sender `u` and router `r` such that `u` routes
g to `r` under its view **and** `r` may trust its table (`CanDecide`), every live
holder `s` of g that is a member of the shared view is in `r`'s delivery set.
Over-delivery (a stale entry) is intentionally **not** flagged — it is safe.

## Findings

### Finding A (candidate real gap): a lagging `:ready` router can miss a group joined under a newer view

**`NoMissedDelivery` is violated** by a 9-step trace (saved in
`tla/trace_finding1.txt`). Reduced scenario:

1. Nodes 2 and 3 form a healthy, converged 2-node cluster, view `{2,3}`. Node 1
   is not yet known to either. Node 2 is g's router (`min{2,3}=2`).
2. Node 3 announces agreement with `{2,3}` to node 2 (a bare marker; node 3
   holds nothing yet). Node 2 records `member_views[3] = {2,3}`.
3. Node 3 discovers node 1 and advances to view `{1,2,3}`. It dispatches a fresh
   `{1,2,3}` marker to node 2, but that marker is still in flight.
4. Node 3 **freshly joins g** under `{1,2,3}`. Since `Router({1,2,3}) = 1`, node
   3 claims on **node 1**, not node 2.
5. Node 2 (still lagging on view `{2,3}`, having only processed node 3's *stale*
   `{2,3}` marker) is `:ready`, considers itself g's router, and its occupancy
   for g is empty.

A broadcast by any process on node 2 (which carries view-hash `{2,3}`) routes to
node 2, passes `can_decide?` (ready + hash agreement, since sender and router
share view `{2,3}`), and delivers to **nobody** — missing node 3's live member.

**Why it is robust to Erlang-dist FIFO.** The counterexample only ever *delivers*
the stale `{2,3}` marker; node 3's superseding `{1,2,3}` marker is left
undelivered. Since the stale marker was sent first, this ordering is legal even
under strict per-pair FIFO — FIFO forces the older marker to arrive first, which
is exactly what the trace does. So the window is not an artifact of the model's
unordered-delivery abstraction; it is the real "coordinator has processed marker
N but not yet marker N+1" gap.

**Why the design's safety argument does not cover it.** The README argues a
lagging node transiently `:ready` on a superseded view is safe because "the
occupancy data for that view was committed before [the markers] were sent" and
"senders already on the newer view carry a mismatching hash, so that router
floods for them." Both hold here, yet delivery is still missed, because:

* the missed holder is a member that **joins g *after* the stale marker was
  sent**, under the *newer* view, routing to a *different* router (node 1). There
  was no data to commit at marker-send time, so "data committed before marker
  sent" is vacuously true and irrelevant.
* the sender is on the **older** view (`{2,3}`), so the "newer-view senders
  flood" protection does not apply to it.

The barrier's argument implicitly assumes the **holder set is stable across the
view transition**. A fresh join under the newer view breaks that assumption.

**Reproduced end-to-end (black box).** `test/forum/muster_distributed_test.exs`,
describe `"stale-ready router window (TLA Finding A)"`, reproduces this on a real
3-node cluster over Erlang distribution:

* R (the local test node) and peer S form a healthy `{R,S}` cluster; R is the
  group's router and `:ready`.
* Peer T joins. Two `force_ordering` parks hold R in the lagging window, both
  released by one `:test_release_stale_ready` event:
  * park `:muster_rebalance_marker` (`source: S, view_hash: {R,S,T}`) — R must
    not *process* S's newer view announcement (a new tp added at marker-receipt,
    before the `member_views`/status update);
  * park `:muster_peer_registered` (`peer: T`) — R must not *register* T (which
    would rebalance it off `{R,S}`).
  Every path that could un-ready R is one of these two, so while both are parked
  R provably stays `:ready` for `{R,S}` — no polling race.
* S advances to `{R,S,T}` and freshly joins the group, claiming it on T. The test
  then asserts, on R: `status == :ready`, `view_hash == {R,S}`, R is still the
  group's router, S holds a live member and the real router T has S in its
  occupancy — yet `Muster.targets(scope, group, {R,S}-hash)` returns `{:ok, []}`,
  omitting S. That empty delivery set is the missed broadcast.
* Releasing the parks lets R rebalance into `{R,S,T}`; the cluster re-converges
  and a broadcast routed to the real router T then reaches S (self-heal).

A negative control (parks removed) fails at `view_hash == {R,S}`: R rebalances to
`{R,S,T}` immediately, proving the miss is reachable *only* inside the parked
window and the test isn't vacuously passing.

**Severity / caveats.** The window is **transient and self-healing**: as soon as
node 2 processes node 3's `{1,2,3}` marker (or discovers node 1 itself), it drops
to `:converging` and floods. It requires a specific interleaving during
asymmetric convergence (node 2 lags discovering node 1 while node 3 has advanced
and freshly joins g). Whether this matters in practice depends on whether Muster
must guarantee *zero* missed broadcasts even for the brief flux window, or only
eventual convergence. The README currently claims the barrier makes it zero, so
this is worth a decision. **This is a candidate finding, not yet a confirmed
production bug** — confirm against intent before acting (per the "confirm before
implementing fixes" preference).

Possible mitigations to explore (not yet designed): a router should not trust its
table for a group whose router-under-its-view is itself unless it can also rule
out that a member has advanced past its view — e.g. gating readiness on a
liveness/epoch signal, or having a fresh first-member join for a group whose
router differs across a member's known views trigger a flood until the next
convergence. Needs discussion.

## The B1 fix (two-phase view adoption) — modeled and shipped

We chose **B1**: a node gates the ring swap (routing joins under a grown view) on
an acknowledged announcement to its **old-view members**. Growth = PREPARE
(invalidate our `member_views` entry on every old-view member, dispatched from
workers so Scope never blocks) → await acks → COMMIT (the existing
`do_rebalance`). This orders "every old-view member knows we left the view"
before "we route a join under the new view", so the stale-ready router either
still holds the mover's row (mover hasn't advanced) or is no longer `:ready`
(mover's invalidation landed). Shrinks commit immediately (a wiped dead-peer
entry already un-readies everyone). Crash-on-prepare-timeout is the liveness
escape hatch.

`tla/Muster2.tla` models this. It caught **two design flaws before any Elixir**:

1. A prepare must **invalidate** the source at the recipient (`known := FALSE`),
   *not* assert the target — asserting would make the recipient trust the mover
   on a view it isn't routing under yet (the mirror bug).
2. While a round is in flight the mover must **suppress ordinary asserting
   markers** — otherwise its own heartbeat re-announces the old view at a higher
   seq and out-races the prepare's invalidation (newest-seq-wins).

**Result:** with both corrections, `NoMissedDelivery` **holds**:

* `MaxSeq=3`, 3 nodes, unconstrained — **exhaustive** (57.8M distinct states,
  complete graph depth 27, 0 left on queue), no violation. Re-confirmed with a
  second fingerprint seed (`-fp 7`), same result — the hash-collision caveat does
  not apply.
* `MaxSeq=4` is **infeasible to exhaust** on this hardware (state count grows
  unbounded); a partial run reached **640M distinct states with no violation**
  before being killed by memory pressure, and a `|msgs| ≤ 5`-constrained variant
  reached 79M with no violation. Corroborating, not a proof; the `MaxSeq=3`
  exhaustive result is the proof.

**Liveness** (final view eventually commits when churn stops) is argued, not
TLC-checked (bounded-seq models make temporal liveness fragile): a round commits
once every `awaiting` member acks or is pruned (a dead one via `:DOWN`, an
unreachable one via crash-on-timeout); a mid-round change supersedes with a fresh
round; churn is finite, so the last round drains and commits.

**Shipped:** `lib/forum/muster/scope.ex` (`begin_view_change`/`commit_view_change`,
`note_transition`/`{:apply_transition}`, the `:transition_done` handler,
`pending_round` state, `update_status`/`announce_view`/discovery-ack suppression
while a round is in flight). The reproduction/characterization lives in
`test/forum/muster_distributed_test.exs`:

* "two-phase view adoption closes the stale-ready router window" — drives the
  exact Finding-A interleaving and shows the gate keeps the mover on the old view
  so its fresh join lands on (and is held by) the old router: no miss.
* "cascading joins … gates the holder on its old peer" — a frozen old peer gates
  the holder's adoption; it never materialises the intermediate view and
  converges straight to the final router on release.

All 195 forum tests pass.

### Modeling gaps found and closed (not code bugs — they validated the model)

* **Gap 1 — join not atomic with router notification.** An early version let
  `holds[n]` flip true before any occupancy write, so a singleton self-router was
  instantly `:ready` with an empty table. Fixed by making `HolderJoin` write the
  router row atomically, faithful to `join/3` (local path writes the row in-call;
  remote path registers only after the `:occupied` ack). This is a genuine
  property of the code, not a patch.
* **Gap 2 — self-row re-assert not atomic with rebalance.** Losing a remote
  router (its node dies) can make a node its own router; if the view change and
  the self-row re-assertion are separate steps, the node is briefly `:ready` as a
  singleton router with no row. Fixed by folding the self-row upsert into the
  view-change step, faithful to `do_rebalance` writing local self-rows
  synchronously *before* `:status` leaves `:rebalancing`.

Both gaps are things the real code gets right; reproducing them confirmed the
model was faithful enough to also surface Finding A, which the code does **not**
obviously handle.

## Caveats / what is NOT yet modeled (next steps)

1. **`drop_stale_router_entries` sweep + tombstone GC** are not modeled. They
   affect only over-delivery cleanup and the *seq-guarded delete vs concurrent
   re-claim* race — a place worth a dedicated model (risk of wrongly deleting a
   live row ⇒ under-delivery). **High priority next.**
2. **Only one group.** Multi-group interactions (batched vacant per shard, a
   snapshot's tombstone-stale-rows pass) are not exercised. The seq register is
   per-`{group,source}`, so single-group covers the register races, but the
   rebalance snapshot/delta *set* logic (full vs delta, `groups_to_reannounce`)
   is not.
3. **Coordinator restart-in-place** (reset ring to `[node()]`, re-discovery,
   singleton promotion) is excluded — consistent with the user assumption that
   nodes do not come back and reset their seq. If that assumption is relaxed,
   this needs adding.
4. **Ring = `min`.** Real consistent hashing satisfies subset-monotonicity (which
   `min` also satisfies) but has richer non-subset behaviour. Finding A does not
   depend on `min` (any ring where growing membership moves a group's router to a
   newly-joined node reproduces it), but the sweep model (step 1) may want a
   more general ring or an explicitly monotone uninterpreted function.
5. **Message ordering.** Modeled as a fully unordered set (faithful for `:erpc`
   worker calls and cross-channel marker/snapshot interleaving; a safe
   over-approximation for same-pair dist sends — see Finding A's FIFO note). A
   dedicated FIFO-channel refinement could tighten which traces are real.
6. **Liveness.** Only safety (`NoMissedDelivery`, `TypeOK`) is checked. No
   temporal/eventual-convergence properties yet.
