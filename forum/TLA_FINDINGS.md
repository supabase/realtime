# Forum.Muster — TLA+ model findings

Status: **Finding A found, modeled, reproduced, and FIXED (B1) — fix
model-checked and shipped. Follow-ups done: the occupancy GC sweep (caveat 1)
is now modeled and checked clean; liveness (caveat 6) is now machine-checked;
the fix is corroborated at 4 nodes; the coordinator crash/restart path (part of
caveat 3) is now modeled — safety holds and the crash-on-prepare-timeout escape
hatch is liveness-checked; the ring is now a model parameter, not hard-wired
`min` (caveat 4) — the exhaustive N=3 proof is shown to hold for any
single-group total-order ring (relabeling argument + bit-identical
state counts), and a deeper 4-node bounded search corroborates; and
multi-group (caveat 2) is now modeled — two groups with diverging ring orders
on top of the B1 fix, `NoMissedDelivery` holds per group (exhaustive at
`MaxSeq=2`, partial-clean at `MaxSeq=3`); and the multi-group model's own
**delta-vs-full snapshot selection sub-gap is now closed** — `tla/Muster2Delta.tla`
models the FULL(wipe)/DELTA(add-only) choice, the only-moved-groups delta payload,
and the per-source wholesale `applied_snapshot_seq` watermark faithfully, and
`NoMissedDelivery` still holds; the selection logic is also directly unit-tested.**
With that, **every original caveat is either closed or soundly declined**
(message-ordering is a deliberate over-approximation; node-name-reuse is excluded
by assumption). **Cross-mechanism follow-up (restart × delta) surfaced a
faithfulness gap in the existing restart model — see Finding B.** Composing the
restart action onto the multi-group/delta model (`tla/Muster2DeltaRestart.tla`)
produced a `NoMissedDelivery` violation at `MaxSeq=4`; investigation showed it is
a **modeling artifact**: `Muster2Restart` wrongly assumed peers see no `:DOWN`
when a coordinator restarts in place, but peers monitor the coordinator PID and
DO get a `:DOWN` that wipes the restarted node's stale agreement. With that
`:DOWN` modeled faithfully (`tla/Muster2DeltaRestartDown.tla`) `NoMissedDelivery`
holds again. This document is the checkpoint so work can resume.
**The Finding B residual (the async `:DOWN` window) is now built too**
(`tla/Muster2RestartDownAsync.tla`): the window is **confirmed real**
(`NoMissedDelivery` violated, as predicted), it is **broader than pure `:DOWN`
latency** (two stronger candidate bounds are refuted by real shapes — a
never-monitored first incarnation whose late marker lands behind a withheld
discover-ack piggyback, and a restart-triggered peer-side **shrink** re-homing
a group behind the router's back), and it is **exactly Finding A's class**:
`MissImpliesViewDivergence` (every miss has the missed holder on a different
committed view than the router — transient, self-healing asymmetric
convergence) holds over deep partial searches. Building it also surfaced three
code-level facts the sync `:DOWN` model simplified (per-pid attribution of the
wipes, `:DOWN` = pure shrink when the new incarnation is unregistered, and
markers/data creating no monitor) — see "Follow-up models". **The residual is
now also reproduced end-to-end** (a snabbkaffe-parked distributed test drives
the model's exact 9-step counterexample on a real 2-node cluster) **and its
disposition is decided: documented and accepted for now** — README.md
describes the window; a candidate fix (the "restart-claim guard" dual-claim)
was prototyped, judged too complex, backed out, and recorded for later. See
"Finding B residual — status".
**The caveat-7 cross-mechanism compositions are now built and checked too**
(`tla/Muster3RestartDown.tla` = sweep × restart, single-group;
`tla/Muster3DeltaRestartDown.tla` = sweep × delta/multi-group × restart):
`NoMissedDelivery` **holds** in both (exhaustive at `MaxSeq=2`, partial-clean at
`MaxSeq=3`/`MaxSeq=4` with confirmed sweep/delta/post-restart-sweep witnesses),
so the sweep's informal fail-safe arguments are now machine-checked and
**every caveat is closed or soundly declined**. One structural finding: in the
multi-group composition the sweep is **unreachable at `MaxSeq=2`** (snapshot
emission is bound to `Commit` and costs a seq), so the `MaxSeq=2` exhaustive
baseline is sweep-vacuous there and the sweep-covering runs are the
`MaxSeq≥3` partials — see "Follow-up models".

Fifteen models:

* `tla/Muster.tla` (+ `.cfg`) — the baseline routing model that **exhibits**
  Finding A (`NoMissedDelivery` is violated).
* `tla/Muster2.tla` (+ `.cfg`) — the same model plus the **B1 two-phase view
  adoption** fix; `NoMissedDelivery` **holds** (see "The B1 fix" below).
* `tla/Muster3.tla` (+ `.cfg`) — Muster2 **plus the occupancy GC sweep**
  (`drop_stale_router_entries`) and **tombstone reap** (`reap_tombstones`), the
  caveat-1 mechanisms. `NoMissedDelivery` still **holds** (see "Follow-up
  models" below).
* `tla/Muster2Live.tla` (+ `.cfg`) — Muster2 with **fairness** and a
  **liveness** property (every prepare round eventually resolves); holds under
  fairness (see "Follow-up models").
* `tla/Muster2Cancel.tla` (+ `.cfg`, `_fixed.cfg`) — the **grow-then-shrink
  cancel** finding: markers carry the node's **stable `view_seq`** (not a fresh
  per-message bump, the abstraction that hid this from `Muster2Live`), so a
  cancelled prepare round leaves the members that already acked **stranded**
  (`NoStranded`/`Repair` VIOLATED). Toggling `Fix` (the shipped
  `cancel_view_change` that bumps `view_seq`) makes both hold (see "Follow-up
  models").

* `tla/Muster2Restart.tla` (+ `.cfg`) — Muster2 **plus a coordinator
  crash/restart action** (the crash-on-prepare-timeout / crash-on-snapshot
  escape hatch). Checks `NoMissedDelivery` survives a restart (ring reset +
  retained occupancy table + wiped `member_views` + start `:converging`). Holds
  (see "Follow-up models").
* `tla/Muster2RestartLive.tla` (+ `.cfg`) — the restart hatch under **fairness
  with a droppable prepare** (up-but-unreachable peer): a wedged prepare round is
  resolved by the crash-restart. `RoundsResolve` and `<>[]RoundsQuiet` both hold.
* `tla/Muster2Ring.tla` (+ `.cfg`) — Muster2 with the ring **generalized from
  hard-wired `min` to a `RingRank` constant** (any total-order ring). Confirms
  `NoMissedDelivery` does not depend on the `min` artifact (caveat 4), and hosts
  the deeper 4-node bounded search with non-vacuity witnesses (see "Follow-up
  models").

* `tla/Muster2Multi.tla` (+ `.cfg`) — Muster2 **generalized from one group to
  many** (caveat 2): two groups with **diverging per-group ring orders**
  (`RingRank[g]`), per-group `holds`/`occ`, and rebalance snapshots that carry a
  **set** of groups. `NoMissedDelivery` holds **per group** (see "Follow-up
  models").

* `tla/Muster2Delta.tla` (+ `.cfg`, `_s4.cfg`, `_w1.cfg`) — Muster2Multi with the
  rebalance snapshot **selection modeled faithfully** (closes the sub-gap
  Muster2Multi left open): the **FULL(wipe+replace) vs DELTA(add-only)** choice,
  the `groups_to_reannounce` delta payload of **only the moved-in groups**, and
  the per-source **wholesale `applied_snapshot_seq` watermark** (a stale reordered
  round is dropped entirely). `NoMissedDelivery` holds (exhaustive at `MaxSeq=2`,
  partial-clean at `MaxSeq=4` — the delta path is only reachable at `MaxSeq≥4`; see
  "Follow-up models").

* `tla/Muster2DeltaRestart.tla` (+ `.cfg`, `_s4.cfg`, `_wr.cfg`, `_wd.cfg`) —
  **Muster2Delta composed with the coordinator restart action** — the one
  cross-mechanism interaction previously checked only in isolation (restart in
  `Muster2Restart` was single-group with no delta; the delta path in
  `Muster2Delta` had no restart). This composition **exposed Finding B**: a
  `NoMissedDelivery` violation at `MaxSeq=4` (exhaustive-clean at `MaxSeq=2`),
  which turned out to be a **faithfulness artifact** of the restart model (it
  omitted the peer-side coordinator-pid `:DOWN`). See "Finding B" and "Follow-up
  models".
* `tla/Muster2DeltaRestartDown.tla` (+ `.cfg`, `_s4.cfg`) — the **corrected**
  restart model: a coordinator restart also fires the peer-side `:DOWN` (blanks
  the restarted node's `member_views` agreement on every peer, and drops the old
  incarnation's in-flight messages, FIFO-faithfully). `NoMissedDelivery` **holds**
  again (exhaustive at `MaxSeq=2`, partial-clean at `MaxSeq=4` past the depth-12
  where the base violated). See "Finding B".
* `tla/Muster2RestartDownAsync.tla` (+ `.cfg`, `_char.cfg`, `_char3.cfg`,
  `_strong.cfg`) — the **async peer-side `:DOWN`** (the Finding B residual),
  single-group, with the `:DOWN` modeled faithfully to the code (per-incarnation
  pid attribution; shrink-vs-wipe by registration state; channel-accurate
  monitor creation and ordering). `NoMissedDelivery` is **violated** (the window
  is real — `tla/trace_asyncdown_window.txt`); the characterization
  `MissImpliesViewDivergence` **holds** (partial-clean, deep). See "Follow-up
  models".

* `tla/Muster3RestartDown.tla` (+ `.cfg`, `_s4.cfg`, `_w1.cfg`, `_w2.cfg`) —
  **caveat-7 composition #1: the occupancy GC sweep × the (Finding-B-corrected)
  coordinator restart**, single-group. Muster3's `DropStale`/`Reap` composed
  with the peer-`:DOWN`-faithful `Restart`. `NoMissedDelivery` **holds**
  (exhaustive at `MaxSeq=2`, partial-clean at `MaxSeq=4` past Finding B's
  depth-12), with confirmed witnesses that sweeps fire, including after a
  restart (see "Follow-up models").
* `tla/Muster3DeltaRestartDown.tla` (+ `.cfg`, `_s3.cfg`, `_s4.cfg`,
  `_w1.cfg`, `_w2.cfg`, `_w3.cfg`) — **caveat-7 composition #2: the sweep ×
  the multi-group delta selection × the corrected restart**. Muster2DeltaRestartDown
  plus `DropStale`/`Reap` lifted to per-group rows. `NoMissedDelivery` **holds**
  (exhaustive at `MaxSeq=2`; sweep-covering partial at `MaxSeq=3`; delta-covering
  partial at `MaxSeq=4`). Structural finding: the sweep is unreachable at
  `MaxSeq=2` here (see "Follow-up models").

Plus two bounded 4-node harnesses (`tla/MusterBounded.tla`,
`tla/Muster2Bounded.tla`) — see "Follow-up models".

The first three model Muster's core **routing-safety** story: *when a broadcast
is routed to a router that trusts its occupancy table, does it reach every live
holder of the group?* `Muster2Live` targets **convergence** (does churn settle?).

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

### Finding B (model faithfulness gap — NOT a code bug): the restart models omit the peer-side coordinator `:DOWN`

Surfaced by the **restart × delta** cross-mechanism follow-up
(`tla/Muster2DeltaRestart.tla`, this composition being the one place where one
mechanism — restart — resets exactly the state another — the add-only delta — relies
on). Composing the coordinator restart onto the multi-group/delta model produced a
`NoMissedDelivery` **violation at `MaxSeq=4`** (the base was exhaustive-clean only at
`MaxSeq=2`; the shape needs seq 4, which the original `Muster2Restart` never reached —
it was exhaustive at `MaxSeq=2`, partial at `MaxSeq=3`). The **same violation
reproduces in the single-group `Muster2Restart` at `MaxSeq=4`** (found in 6 s; run
`Muster2Restart_s4.cfg`), so it is neither a delta nor a multi-group phenomenon.

**The counterexample (9 steps, single-group, `tla/trace_restart_artifact.txt`).**
Nodes 1 and 2 converge to view `{1,2}`; node 1 is group `a`'s router (`min`) and
becomes `:ready` on node 2's agreement. Node 2's **coordinator restarts in place**
(view resets to `{2}`, `:converging`, `member_views` wiped) but the model leaves
node 1's `member_views[2] = {1,2}` untouched. Node 2 then freshly (re)joins group `a`
under `{2}`, claiming it on **itself**. Node 1 — still `:ready` for `{1,2}`, still the
router, with no row for node 2 — routes a broadcast to nobody. It is the exact
**Finding-A stale-ready-router shape, re-created by a restart rather than by
asymmetric convergence**. Note B1 is not even the relevant defence here: both nodes
grew to `{1,2}` as singletons (empty prepare audience), so no B1 prepare ever fired.

**Why it is a modeling artifact, not a code bug.** The restart models
(`Muster2Restart`, `Muster2DeltaRestart`) assume *"the node stays up, so peers see no
`:DOWN`"* — **false**. Peers monitor the restarting node's **coordinator PID**, so a
coordinator restart-in-place delivers a `:DOWN` (of the old pid) to every peer. The
`:DOWN` handler (`scope.ex` ~L815-883) explicitly reasons about *"a peer that restarts
in place"* and *"the OLD pid's DOWN"*, wiping that pid's `member_views` (and occupancy
/ `applied_snapshot_seq`) entries. That wipe removes node 1's stale `{1,2}` agreement
for node 2, so node 1 drops out of `:ready` and floods. Erlang monitor + dist ordering
also guarantees the `:DOWN` is delivered **after** the old incarnation's last message,
so no stale pre-restart marker can re-establish the agreement past the `:DOWN` — which
the base model's **unordered `msgs`** set wrongly allows (caveat 5's over-approximation
biting: the violation relies on delivering the stale marker *after* the restart, a
reordering real FIFO forbids).

**The corrected model holds.** `tla/Muster2DeltaRestartDown.tla` makes `Restart(n)`
also (a) blank `mv[p][n]` on every peer `p` (the peer-side `:DOWN`) and (b) drop the
old incarnation's in-flight messages (`{m ∈ msgs : m.src = n}`, FIFO faithfulness).
`NoMissedDelivery` **holds** again: exhaustive at `MaxSeq=2` (1,830,351 distinct,
depth 20, 0 on queue) and **partial-clean at `MaxSeq=4`** (27.2M distinct, BFS depth
12 — past the depth where the base model violated). So the peer-pid `:DOWN` is the
mechanism that keeps the restart path safe, and the code has it.

**Residual (NOW BUILT AND CHARACTERIZED — see `tla/Muster2RestartDownAsync.tla`
under "Follow-up models").** The corrected model fires the `:DOWN`
**synchronously** with the restart, collapsing its delivery latency to zero. A peer
that was legitimately `:ready` on the old view before the restart stays `:ready` until
it actually **processes** the (async) coordinator-pid `:DOWN`; a `persistent_term`-based
broadcast in that gap (`Muster.targets` reads status/occupancy directly, not via the
coordinator mailbox) could still miss a group the restarted node re-homed under its
reset view. The async model **confirms this window is real** (`NoMissedDelivery`
violated, 9-step trace) and shows it is **broader than `:DOWN` latency alone** —
but every reachable miss is **Finding-A-class**: the missed holder is on a
different committed view than the router (asymmetric convergence; transient and
self-healing). Whether it warrants action is the same *zero-miss vs
eventual-convergence* decision as Finding A. **Decided: documented and
accepted for now** — reproduced end-to-end by a distributed test and written
up in README.md; the candidate fix is recorded but deferred (see "Finding B
residual — status" under "Follow-up models").

**Takeaway.** The follow-up did its job: it found that `Muster2Restart` (and hence the
restart half of caveat 3) was **not faithful** — it omitted the load-bearing peer-pid
`:DOWN`. The corrected model restores the clean result; the caveat-3 write-up below is
annotated accordingly.

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

## Follow-up models (sweep GC, liveness, 4-node)

All runs use the same invocation as "How to run" above, swapping the module/cfg
(and adding `-fp 7` to re-seed the fingerprint hash where noted).

### `tla/Muster3.tla` — occupancy GC sweep + tombstone reap (was caveat 1)

Adds to the shipped-fix model (Muster2) the two GC mechanisms TLA_FINDINGS.md
called the **highest-priority** unmodeled code, because they are the only ways a
router row can go absent *without* a message from the source (the under-delivery
risk):

* **`DropStale(r, s)`** — `drop_stale_router_entries/1` (`scope.ex` ~1369): the
  periodic / on-`:ready` / post-rebalance sweep that **downgrades a `:present`
  row to a tombstone at its EXISTING seq** when the row's source agrees with our
  committed view (`SourceAgrees`) and the group no longer routes to us
  (`Router(view[r]) # r`). Own rows are always judgeable.
* **`Reap(r, s)`** — `reap_tombstones/1` (`scope.ex` ~1693): the time-windowed
  **hard delete** of a tombstone back to truly-absent (seq 0). Modeled faithful
  to the retention-window design: a tombstone is reaped only once its
  `{router,source}` key is **quiescent** (no in-flight message could still land
  for it), which is exactly the assumption "the window (a multiple of
  `rpc_timeout_ms`) outlasts every orphaned, un-cancelled RPC". Firing reap while
  a message is still in flight would model a *window-too-short* timing bug, a
  separate concern the design explicitly rules out.

**Why a single atomic `DropStale` step is faithful to the select-then-guarded-
replace race.** The real sweep does an `:ets.select` (judge) then a seq-guarded
`:ets.select_replace` (write only if still `:present` at the *same* seq). The
only thing that can change between them is the ROW (`occupied/4`, `vacant_batch/4`
write ETS straight from `:erpc` workers); `view[r]` cannot, because the whole
sweep runs to completion inside one coordinator `handle_info`. So any concurrent
claim is a separate delivery step ordered either before this one (higher seq ⇒
the `present`/seq precondition fails ⇒ no-op, matching the guarded replace) or
after it (a fresh higher-seq claim overwrites the tombstone via `ApplyPresent`'s
strict `>`, matching the live re-claim surviving). No two-step split is needed.

**Result: `NoMissedDelivery` holds.**

* `MaxSeq=2`, 3 nodes — **exhaustive**: 605,694 distinct states, depth 20, 0 left
  on queue, no violation. Re-confirmed with `-fp 7` (identical count).
* `MaxSeq=3`, 3 nodes — partial (state count grows past the heap): **79.5M
  distinct states with no violation** before being killed by memory pressure.
  Corroborating; the `MaxSeq=2` exhaustive result is the proof.

Takeaway: the sweep's source-agreement + routes-away guard means a node only ever
tombstones rows for a group it does **not** route, so it can never drop a live
row on the actual current router — confirmed across the whole `MaxSeq=2` space.
`Reap` is safety-neutral for under-delivery (it only turns an already-absent
tombstone into an absent empty; its window matters only for over-delivery, which
the property intentionally ignores).

### `tla/Muster2Live.tla` — liveness under fairness (was caveat 6)

Turns the prose convergence argument into a machine-checked temporal property.

**The bounded-seq obstacle, handled.** Every seq-consuming action is guarded by
`CanBump` (a finiteness device), and in Muster2 `Commit`/`DetectDown` also spend
a seq on their self-row re-assert fold. So for *any* finite `MaxSeq` there is a
trace where a node spends its last seq on a `Discover` and can then never
`Commit` — an active round wedged forever. That is a **model artifact**, not a
real stall (the code's self-reassert is an unconditional local ETS upsert;
`next_seq()` never runs out). `Muster2Live` therefore **decouples the
`Commit`/`DetectDown` self-reassert from `CanBump`** (writes at the current seq,
bumping nothing), so those two are enabled by their real preconditions only.
Everything that models genuine **churn** (`HolderJoin/Leave`, `Discover`,
`SelfClaim`, `SendSnapshot/Marker`) still consumes bounded seq and is left
**unfair**, so churn provably ceases and the convergence question is well posed.

**Fairness:** weak fairness on the convergence-driving steps only — message
delivery (prepares ack, snapshots/markers/vacants land), `Commit`, `DetectDown`.
Churn actions are deliberately unfair.

**Properties, both hold:**

* `Liveness == <>[]RoundsQuiet` — eventually, forever, no live node has an active
  prepare round (the last round drains and commits).
* `RoundsResolve == \A n : (up[n] /\ round[n].active) ~> (~up[n] \/ ~round[n].active)`
  — the leads-to form.
* `NoMissedDelivery` was kept as an invariant here too (sanity: the liveness
  variant does not break safety) — holds.

Runs: **exhaustive** at 2 nodes / `MaxSeq=2` (565 distinct) and at 3 nodes /
`MaxSeq=2` (488,867 distinct), no violation of either temporal property.

**Caveat.** The model never *drops* a message, so every prepare is eventually
delivered = acked; the real **crash-on-prepare-timeout** escape hatch (for a peer
that is up but unreachable) is out of scope here and is still argued, not checked.

### `tla/Muster2Cancel.tla` — grow-then-shrink cancel (a liveness gap `Muster2Live` masked)

**Finding: a cancelled prepare round strands the members that already acked.**
This is the bug fixed in `cancel_view_change/1` (`scope.ex` ~1581) and covered by
the "grow then shrink back to the committed view" tests
(`test/forum/muster_distributed_test.exs`). A node grows its view and PREPAREs its
old-view members — each ack **invalidates** that member's `member_views` entry for
the mover, stamped at the round seq (`next_seq()`, *above* the mover's committed
`view_seq`). If the growth peer then leaves **before commit**, membership is back to
the committed view: there is no ring to swap, so the round is **cancelled**. But an
old-view member that already acked is now invalidated for the mover at a seq above
the mover's `view_seq`, and a bare heartbeat marker carries that *lower* `view_seq`
— so `newest-seq-wins` rejects it forever. That member stays `:converging` for the
mover until the mover's next *committed* rebalance, which in a now-stable cluster
may never come.

**Why `Muster2Live` did not catch it.** `Muster2Live`'s re-announce (`SendMarker`)
stamps every marker with a **fresh per-message `Bump`**, so a heartbeat always
eventually out-seqs a stale invalidation and heals it — the exact failure is
abstracted away. The real heartbeat (`announce_view`) carries the node's **stable
committed `view_seq`**, which is *not* advanced merely by running a round. This
module makes that distinction explicit: a separate `viewSeq[n]` (advanced only at
`Commit`, and — with the fix — at cancel) is what `Heartbeat` markers carry, while
a round's prepare invalidation is stamped at the round seq (strictly above
`viewSeq[n]`). A `CONSTANT Fix` toggles `cancel_view_change`: `Fix=TRUE` bumps
`viewSeq` past the round seq on cancel; `Fix=FALSE` is the pre-fix code.

**Properties.**

* `NoStranded` (safety) — the crisp characterization: no state where an up member
  `r` holds an invalidation for an up peer `s` (`~known`, seq `>` `viewSeq[s]`)
  while `s`'s round is quiet and both sit on the same committed view. In such a
  state no heartbeat from `s` can ever out-seq the invalidation.
* `Repair` (liveness) — two committed peers on the same view eventually agree
  again, unless a node dies or the views legitimately diverge.

**Confirmed results** (`Nodes={1,2,3}`, `MaxSeq=3`):

* **`Fix=FALSE`** — `NoStranded` **VIOLATED** in ~4s. Trace: nodes `1,2` pair →
  `1` grows toward `{1,2,3}` and prepares `2` → `3` goes down → `1` cancels → `2`'s
  ack lands, stranding `2` for `1` permanently. `Repair` **VIOLATED** too (~2min):
  an infinite heartbeat loop that never heals.
* **`Fix=TRUE`** — `NoStranded` **holds** (exhaustive, ~1.9M states); `Repair`
  **holds** (bounded, ~20min).

**One modeling correction along the way.** The first `Fix=TRUE` liveness run threw
a *spurious* `Repair` counterexample: a cycle that endlessly re-delivered an
already-applied marker while starving the one that heals — weak fairness on
`\E msg : DeliverMarker(msg)` is satisfied by delivering *any* message. Real
transport delivers each link independently, so delivery fairness is quantified
**per `(src,dst)`**. Pre-fix still fails; the spurious cycle is gone.

**Caveat.** `msgs` accumulates idempotent re-announce markers, so exhaustive
temporal checking is unbounded; a `StateConstraint` (`seqCtr ≤ MaxSeq+1`,
`|msgs| ≤ 2`) bounds it. `NoStranded` against the fairness-free `Spec` is the
crisp, cheap reproduction; the bounded `Repair` liveness result corroborates.

Run:

```bash
cd forum/tla
mise exec java@corretto-26.0.1.8.1 -- \
  java -Djava.io.tmpdir="$TMPDIR" -XX:+UseParallelGC -cp ../tla2tools.jar \
  tlc2.TLC -workers auto -deadlock -config Muster2Cancel.cfg Muster2Cancel.tla        # Fix=FALSE
# swap in Muster2Cancel_fixed.cfg for Fix=TRUE
```

### `tla/Muster2Restart.tla` — coordinator crash/restart (part of caveat 3)

> **⚠️ Superseded on one point — see Finding B.** This model assumes *"peers see
> no `:DOWN`"* on a coordinator restart-in-place. That is **not faithful**: peers
> monitor the coordinator PID and DO receive the old pid's `:DOWN`. The omission
> is invisible at `MaxSeq=2` (this model's exhaustive bound) but produces a
> spurious `NoMissedDelivery` violation at `MaxSeq=4`. The corrected model is
> `tla/Muster2DeltaRestartDown.tla`, which restores the clean result. Read the
> rest of this section together with Finding B.

Models the **crash-on-prepare-timeout / crash-on-snapshot-failure** path: a
prepare or snapshot RPC to an up-but-unreachable peer fails, the coordinator
`raise`s (`scope.ex` ~964 / ~921), and the supervisor restarts it under the
**same live node name**. This is distinct from the excluded "node name reuse
across deployments" case — the node stays UP. The model asserted **peers see no
`:DOWN`** and keep their occupancy / `member_views` rows for it — but that is the
faithfulness gap Finding B corrects: the BEAM node stays up, yet the coordinator
*process* dies, so peers monitoring its PID do get a `:DOWN`. `Restart(n)` is
otherwise modeled faithful to `init/1` (`scope.ex` ~435) and
`reannounce_local_groups_at_init`:

* the **occupancy table survives** (owned by the `Forum.Supervisor` sibling, not
  the coordinator): `occ[n][s]` rows are RETAINED — stale rows are over-delivery,
  which the property ignores; the question is whether a *needed* row can go
  missing;
* the **ring resets to `{n}`**; **`member_views` is wiped** (the node forgets
  every peer's agreement, so it cannot be a stale-ready router on a grown view);
  `pending_round` / `owed_snapshots` cleared; self rows re-asserted monotonically;
* it starts **`:converging`, not `:ready`** — even as a singleton — with a
  bounded, init-only **singleton-promotion** that trusts `{n}` only when the node
  is genuinely alone. This is the restart analog of the B1 gate (modeled by the
  `promoted` flag). In-flight messages to `n` survive the restart (writes target
  the registered scope name / the surviving ETS table, not the dead pid).

**Result: `NoMissedDelivery` holds.**

* `MaxSeq=2`, 3 nodes — **exhaustive**: 1,035,991 distinct states, depth 20, 0
  left on queue, no violation.
* `MaxSeq=3`, 3 nodes — partial (state count grows past the heap): **136.5M
  distinct states with no violation** before a 9-minute cap (23M left on queue).

**Non-vacuity (this is the important part).** A reachability probe
(`RestartRecoversToRouter`, via the `everRestarted` history var) shows the
scenario that matters — a node that *has restarted* recovering into a Ready
multi-node router actually delivering to a live remote holder — is **not reachable
at `MaxSeq=2`** (that budget only funds a restart, not a full re-pair) but **is
reachable at `MaxSeq=3` (depth 11)**, well inside the depth-20 partial search. So
the `MaxSeq=3` partial run genuinely exercised restart recovery; the `MaxSeq=2`
exhaustive pass alone would have been near-vacuous for it. Reproduce with
`Muster2Restart_probe.cfg` (MaxSeq=2, probe holds) and `Muster2Restart_probe3.cfg`
(MaxSeq=3, probe violated = witness printed).

Takeaway: coming back **`:converging` with a wiped `member_views`** is the
load-bearing mechanism — a restarted node floods until it either re-pairs (grows
+ peers re-announce agreement) or is confirmed alone, so the retained stale table
is only ever trusted after the current holders have re-asserted. The retained
rows never cause under-delivery.

### `tla/Muster2RestartLive.tla` — the crash-on-timeout hatch, under fairness

`Muster2Restart` (above) fires restart spontaneously; this model ties it to its
real trigger and checks **liveness** — the remaining half of caveat 6 (the
message-reliable `Muster2Live` never drops a prepare, so it never needs the
hatch). Adds:

* **`DropPrepare`** — a prepare RPC to an up-but-unreachable peer fails (the
  message is discarded, never acked). An UNFAIR fault. A round with a dropped
  prepare is **wedged**: `awaiting` never empties, so `Commit` is never enabled.
* **`RestartOnTimeout`** — enabled precisely when a round is wedged (an awaited
  member's prepare is no longer outstanding). WEAK-FAIR, so a wedged round is
  eventually resolved by the crash-restart. The restart self-reassert is
  decoupled from `CanBump` (a real crash needs no seq); round creation
  (`Discover`) stays seq-bounded, and a re-grow from the restarted singleton has
  an **empty prepare audience** so it cannot itself wedge.

**Properties, all hold — exhaustive at 3 nodes, `MaxSeq=2` (647,985 distinct, 0
left on queue):**

* `RoundsResolve == \A n : (up[n] /\ round[n].active) ~> (~up[n] \/ ~round[n].active)`
  — the hatch's guarantee: **no prepare round wedges forever** (a dropped-prepare
  stall is broken by the crash-restart).
* `Liveness == <>[]RoundsQuiet` — eventually no live node has an active round.
* `NoMissedDelivery` kept as an invariant (safety sanity under the liveness
  variant + restart) — holds.

**Non-vacuity confirmed:** probes show both a **wedged round** (`NoWedgeReached`
violated) and a **fired hatch** (`NoTimeoutRestart` violated) are reachable, so
the properties are not passing over a hatch that never triggers. Reproduce with
`Muster2RestartLive_probe.cfg`.

**Caveat.** `<>[]RoundsQuiet` holds here because bounded `MaxSeq` bounds the
drop→restart→re-grow loop. Under truly unbounded seq a *permanently*
unreachable-but-up peer would loop forever; in the field such a peer eventually
crosses net-tick and goes `:DOWN` (→ `DetectDown` prunes it), so the hatch's real
job is transient unreachability, which `RoundsResolve` captures directly. 2 nodes
is uninteresting for the hatch (growth from a singleton has an empty audience, so
no prepare is ever sent).

### 4-node runs (`tla/MusterBounded.tla`, `tla/Muster2Bounded.tla`)

Both Finding A and the B1 proof were only ever exhaustive at **3 nodes**. A 4th
node is the smallest config that exercises cascading / concurrent prepare rounds
and transitive staleness. A 4-node exhaustive run is infeasible (3 nodes was
already 57.8M states), so these are **bounded** harnesses (`MaxSeq` low + an
`|msgs|` cap via a `CONSTRAINT`). A bounded run **cannot prove** 4-node safety; it
can only surface a shallow 4-node-specific counterexample.

* **Positive control — `MusterBounded` (baseline, has Finding A), 4 nodes,
  `MaxSeq=2`, `|msgs|≤3`:** ✅ **found** a `NoMissedDelivery` violation in 13s
  (depth 10). Confirms the bounded 4-node search actually reaches violations, so
  a clean fix run is meaningful, not vacuous.
* **`Muster2Bounded` (B1 fix), 4 nodes, `MaxSeq=2`, `|msgs|≤2`:** partial (queue
  grows past the heap): **71.3M distinct states with no violation** before being
  killed by memory pressure.

**Symmetry limitation (corrected).** An earlier version of this note claimed a
4-node exhaustive proof "would first need `min` replaced by a monotone
uninterpreted ring function to recover symmetry reduction." That is **wrong**, and
the reasoning behind it is what the relabeling argument (next section) actually
resolves: *any* router that resolves a group to a specific node by identity/ring
position — `min` or a real hash — inherently distinguishes node ids, so a TLC
`SYMMETRY` set over node ids is unsound **regardless** of whether the ring is
`min` or uninterpreted. Generalizing the ring is still worth doing, but for
**generality** (proving the result is not a `min` artifact), not for symmetry. A
4-node exhaustive run therefore remains infeasible; the 4-node story is
necessarily bounded (see `Muster2Ring` below for a deeper bounded run).

### `tla/Muster2Ring.tla` — generalized ring (was caveat 4)

Muster2 with the router generalized from hard-wired `min` to a **`RingRank`
constant** (an injective `Nodes -> Nat`, i.e. any total order); `Router(V)` is the
minimum-rank present node. `RingRank = identity` reproduces `min` exactly.

**The relabeling / WLOG argument (the main result).** In the single-group model,
node identities are compared **nowhere** except inside `Router` (the sole `<=` on
nodes). `Init` is symmetric (every node a singleton) and every action quantifies
over `Nodes` uniformly. So for any node-id permutation π, replacing `RingRank` by
`RingRank ∘ π⁻¹` yields an **isomorphic** transition system, and
`NoMissedDelivery` (uniform in `u,r,s`) is preserved by π. Hence the systems for
**any two total-order rings are isomorphic by relabeling**, and the existing N=3
exhaustive result for `min` (MODULE Muster2) **already implies safety for every
single-group total-order ring**. Real consistent hashing *is* a fixed total order
per group (which node is closest to the group's hash), so `min` is WLOG here; the
genuinely richer *per-group-different-order* behaviour is a **multi-group** concern
(caveat 2), out of scope for this single-group model.

**Empirically confirmed (guards against a hidden asymmetry the argument missed).**
Running a non-identity ring (reversed order — node 3 top-of-ring, not node 1):

* `MaxSeq=2`, 3 nodes — **exhaustive**: **439,759 distinct states, depth 20, 0
  left on queue, no violation** — *bit-identical* to the `min` model at the same
  bound (also 439,759 distinct / 1,299,335 generated). Isomorphic systems have
  identical state counts; they do, to the state.
* `MaxSeq=3`, 3 nodes — **exhaustive**: **57,881,211 distinct states, depth 27, 0
  left on queue, no violation** — again identical to MODULE Muster2's `min` run
  (57.8M, depth 27). The full-scale exhaustive proof holds under a non-`min` ring.

**Deeper 4-node bounded search (`Muster2Ring4.cfg`).** 4 nodes, `MaxSeq=2`, a
shuffled ring (node 3 top), and `|msgs|≤3` — a **looser** bound than
`Muster2Bounded`'s `|msgs|≤2`, so the search reaches further into the
concurrent-round region. Partial (queue grows past the heap): **70.4M distinct
states with no violation** at BFS depth 16 (31M left on queue) before a 9-minute
cap. Corroborating, not a proof (4-node exhaustive is infeasible; see above).

**Non-vacuity witnesses (the important part — probes expected to be VIOLATED, same
pattern as `Muster2Restart_probe`).** They prove the bounded 4-node search
actually reaches the states that make "no violation" meaningful:

* `NoConcurrentRounds` (`_w1`) — **violated**: two live nodes with simultaneously
  active prepare rounds are reachable, i.e. the search exercises the
  concurrent/cascading-round machinery B1 introduced (the whole reason 4 nodes
  matters).
* `NoLaggingReadyRouter` (`_w2`) — **violated**: a lagging `:ready` router
  (Ready + routes its own view to itself) coexisting with a strictly-more-advanced
  live peer is reachable — the exact Finding-A shape the fix must render safe.
* `NoWideView` (`_w3`) — **violated**: a node's committed view reaches size 3
  (grown twice). Note size **4** (full convergence) is **unreachable at
  `MaxSeq=2`** by seq budget — growing the view is a `Discover`, each `Discover`
  spends a seq, so 2 seq ⇒ at most 2 growths ⇒ committed view ≤ 3. Full 4-node
  convergence would need `MaxSeq ≥ 3`; the bounded run exercises 3-node views and
  concurrent rounds *among* 4 nodes, not a fully-converged 4-node cluster.

Takeaway: the `min`-dependence question (caveat 4) is closed for the single-group
model — the N=3 exhaustive proof is ring-shape-independent by the relabeling
argument, confirmed to the state at `MaxSeq∈{2,3}` — and the deeper, non-vacuous
4-node bounded search finds no violation.

### `tla/Muster2Multi.tla` — multi-group (was caveat 2)

Muster2 generalized from one group to many. This is the caveat the doc long
called the **sole substantive remaining gap**, because the `Muster2Ring`
relabeling argument is explicitly *single-group*: it makes one group's ring order
WLOG, but real consistent hashing routes **different groups to different nodes
under the same view**, and there is no single total order to relabel to.

**What is per-group vs shared (faithful to the code).** `holds[n][g]` and
`occ[r][g][s]` become per-group. Everything that is a **cluster-view / node**
property stays shared, because the code makes it so: `view`, the B1 `round` (a
view swap re-routes *every* group the node holds at once), `member_views`
(agreement about the view, not a group), `owed_snapshots` (per-`{holder,router}`
— one snapshot batches all groups), `seqCtr` (`next_seq()` is one monotonic
counter per node), and `Ready`/`CanDecide` (status `:ready` + view-hash
agreement are per node, not per group). The new machinery: each group gets its
own ring order (`RingRank[g]`; group `"a"` routes to `min`, `"b"` to `max`, so
under `{1,2,3}` they route to opposite ends); a rebalance snapshot carries the
**set** of groups the sender holds that route to the target (`SendSnapshot`/
`DeliverSnapshot` over `grps`); `Commit`/`DetectDown` re-assert self rows for
**every** held group now routing to self, and `DetectDown` wipes the dead peer's
rows in **all** groups. Setting `Groups` to a singleton + identity ring recovers
MODULE Muster2 exactly.

**Result: `NoMissedDelivery` holds for every group.**

* `MaxSeq=2`, 3 nodes, 2 groups (diverging rings) — **exhaustive**: 1,035,377
  distinct states, depth 20, 0 left on queue, no violation.
* `MaxSeq=3`, 3 nodes, 2 groups — partial (2-group state space is far larger):
  **29.5M distinct states with no violation** before a 5-minute cap (13.4M left
  on queue). Corroborating; the `MaxSeq=2` exhaustive result is the proof.

**Non-vacuity witnesses (probes expected VIOLATED — reproduce with
`Muster2Multi_w1/w2/w3.cfg`):**

* `NoDivergentReadyRouter` (`_w1`) — **violated**: a `:ready` router whose
  committed multi-node view routes two groups to *different* nodes is reachable —
  per-group router divergence is actually exercised in a trusted-routing state
  (the crux of multi-group).
* `NoMultiGroupHold` (`_w2`) — **violated**: two different live nodes holding two
  different groups concurrently is reachable.
* `NoLaggingReadyRouter` (`_w3`) — **violated**: the Finding-A lagging-`:ready`
  self-router-behind-an-advanced-peer shape is reachable in the multi-group
  setting, so the clean safety run is not vacuous.

Takeaway: the B1 gate is a **view-level** invalidation (the prepare un-readies an
old-view member for *any* view containing the mover, group-independent), so it
closes Finding A for every group simultaneously — divergent per-group routing
does not reopen it.

**Sub-gap (now closed).** Muster2Multi sends the *correct, complete* group-set on
every snapshot (all held groups routing to the target) and applies it add-only
with only a per-row seq guard — so it checks the **protocol** given a correctly
computed set but does **not** exercise the code's `groups_to_reannounce`
delta-vs-full *selection* nor the add-only/wholesale apply. That is closed by
`tla/Muster2Delta.tla` (below) plus direct unit tests.

### `tla/Muster2Delta.tla` — delta-vs-full snapshot selection (the Muster2Multi sub-gap)

Muster2Multi's snapshot was a single abstract "full content, add-only apply"
step. The real `do_rebalance` (`scope.ex` ~L1112-1169) is richer, and this model
makes it faithful:

* **Selection.** `groups_to_reannounce` = held groups whose **router changed vs
  the previous ring generation** (`find_historical_node(_,_,1)`);
  `changed_routers` = routers that gained ≥1 such group. Each changed router gets
  **FULL** (`receive_node_state`, wipe+replace; payload = *all* held groups
  routing to it) when it is **new to the view this round** *or* still **owed** a
  previous round's snapshot, else **DELTA** (`apply_delta`, add-only; payload =
  *only the moved-in* groups). Emission is bound to `Commit` (grow) and
  `DetectDown` (shrink) — both funnel through `do_rebalance` in the code — because
  the delta is a per-round quantity against the previous committed view.
* **Wholesale watermark.** A per-source `appliedSeq[r][s]`
  (`applied_snapshot_seq`): a snapshot/delta whose round seq is **not strictly
  greater** than the highest already applied from that source is dropped
  **entirely** (all its adds), not just per-row. Muster2Multi had only the per-row
  guard.

**The invariant under test.** A delta is add-only and carries only this round's
moved groups; it is correct **only if** the receiver already holds every group the
source holds routing to it that did *not* move this round (the *previous-generation
baseline*). The `owed_snapshots` gate is meant to guarantee this — a delta is sent
only to a router that **acked** the source's prior round, and any in-flight round
forces a FULL. `NoMissedDelivery` asks whether that gate (plus the wholesale
watermark) ever lets a delta leave a router missing a needed group.

**Result: `NoMissedDelivery` holds.**

* `MaxSeq=2`, 3 nodes, 2 groups (diverging rings) — **exhaustive**: 817,825
  distinct states, depth 20, 0 left on queue, no violation. This is the
  **non-delta baseline** (see the structural finding below).
* `MaxSeq=4`, 3 nodes, 2 groups — partial (space grows past the heap): **100.6M
  states generated, 29.0M distinct with no violation** at BFS depth 13 before a
  ~4-minute cap. This is the **delta-covering** run (`Muster2Delta_s4.cfg`).

**Structural finding (why the delta path is deep).** With consistent-hashing
rings the router of a group is the min-rank present node, so **growth** can only
move a group onto a *newly added* node (adding an element to a set only lowers the
minimum) — which is always ∉ `old_members`, hence always a **FULL** snapshot. The
add-only **DELTA path is therefore reachable only via a ≥3-node SHRINK** that
removes a group's router and promotes an *existing* survivor. In this model that
first occurs at `MaxSeq=4`, BFS depth 10 — so the exhaustive `MaxSeq=2` run
contains **no deltas** (it is the non-delta baseline) and the `MaxSeq=4` partial
run is what actually exercises the add-only path. This is itself a useful fact
about the code: `apply_delta` is exclusively a shrink-time optimization.

**Non-vacuity.** `NoDeltaSent` (`Muster2Delta_w1.cfg`) is **violated** at
`MaxSeq=4` (depth 10) — a delta *is* dispatched, so the `MaxSeq=4` safety search
genuinely covers the add-only branch. Two deeper probes (`NoWholesaleDrop`,
`NoBaselineDelta`) target the stranded-stale-round and add-onto-baseline states;
neither surfaced within a multi-minute `MaxSeq=4` search, consistent with the
owed-gate making a stranded stale delta hard to reach. They are kept as
documented probes in the module, not claimed as confirmed witnesses.

**Direct unit tests (the selection + receiver apply).** The selection is also
verified in Elixir (`test/forum/muster_test.exs`), independent of the model:

* *"rebalance full vs. delta dispatch"* — a settled router that gains groups on a
  leave gets a **delta of only the moved-in groups** (never the ones it already
  held); an **owed** router falls back to a **full**.
* *"rebalance occupancy snapshot completeness"* — a leave sends the gaining router
  a delta of only the moved-in group, not the kept one; a router that gains
  nothing gets **no** snapshot.
* *"remote entry points …"* — receiver-side: `receive_node_state/5` **wipes**
  (replaces all rows for a source); `apply_delta/5` **adds without wiping** (the
  baseline survives — the property the delta relies on); and a **stale
  (not-newer) delta is dropped wholesale** even where its per-row guard alone
  would admit it. (The last two were added with this model.)

**Narrow residual.** The model asserts the mover computes the *right* moved-set
from the ring generations; the unit tests confirm the code's `find_node` /
`find_historical_node` selection produces that set. What remains unmodeled is only
the ExHashRing internals themselves (treated as a faithful total-order oracle,
per caveat 4).

### `tla/Muster2DeltaRestart.tla` + `tla/Muster2DeltaRestartDown.tla` — restart × delta (found + fixed Finding B)

The one cross-mechanism composition where one mechanism resets exactly the state
another relies on: a coordinator **restart** wipes `member_views`,
`owed_snapshots` and `applied_snapshot_seq` (all coordinator State) while the
occupancy ETS **survives** — precisely the watermark/owed bookkeeping the add-only
**delta** path leans on. `Muster2DeltaRestart.tla` composes the two; it **found a
`NoMissedDelivery` violation at `MaxSeq=4`** which turned out to be a faithfulness
artifact of the restart model (missing peer-pid `:DOWN`) — the full analysis is
**Finding B** above. The corrected `Muster2DeltaRestartDown.tla` (restart also
blanks peers' agreement for the node and drops its old in-flight messages) **holds**:

* `MaxSeq=2`, 3 nodes, 2 groups — **exhaustive**: 1,830,351 distinct states, depth
  20, 0 left on queue, no violation.
* `MaxSeq=4`, 3 nodes, 2 groups — partial: **27.2M distinct states, no violation**
  at BFS depth 12 (past the depth where the base model violated) before a
  ~5-minute cap.

Non-vacuity for the base composition (that the search reaches the interesting
states): `RestartRecoversToRouter` (`_wr.cfg`) is **violated** — a restarted node
recovers into a Ready multi-node router delivering to a live remote holder; and
`NoDeltaWithRestart` (`_wd.cfg`) is **violated** at `MaxSeq=4` — a delta genuinely
rides alongside a restart. Cross-check: `Muster2Restart_s4.cfg` shows the same
violation in the single-group restart model at `MaxSeq=4`, confirming Finding B is
a restart-path (not delta/multi-group) phenomenon.

**Next step — DONE:** the **async** peer-`:DOWN` action is now built
(`tla/Muster2RestartDownAsync.tla`, next section).

### `tla/Muster2RestartDownAsync.tla` — the async peer-`:DOWN` window (the Finding B residual, built)

Single-group (Finding B reproduces single-group), on the `Muster2Restart` base.
Instead of the sync model's restart-time "blank `mv[p][n]` everywhere + drop all
old in-flight messages", the `:DOWN` is a **queued per-peer event**
(`downQ[p][n]` = dead incarnations of `n` whose `:DOWN` peer `p` has not yet
processed), and its semantics were re-derived from the code rather than assumed.
That re-derivation surfaced **three facts the sync model simplified** (scope.ex
`:DOWN` handler ~L841-883, `recompute_members` ~L1476, `register_peer` call
sites):

1. **Attribution.** The handler wipes only occupancy rows / `member_views` /
   `applied_snapshot_seq` entries **written by the dying pid**
   (`:ets.match_delete(occ, {{:_, peer_node}, :_, :_, pid})`); data already
   re-written by the new incarnation survives. Modeled by an `inc` stamp on
   every message, occupancy row and `member_views` entry.
2. **Membership.** `members` is derived from the `peers` **pid map**, so
   processing the `:DOWN` when no newer incarnation of `n` is registered is a
   **pure shrink** — the peer drops `n` from its committed view and re-homes
   `n`'s groups exactly as if `n` had died (`recompute_members` →
   `do_rebalance`), *not* merely an agreement blank. If a newer incarnation's
   discover raced ahead (real: different senders, no dist ordering), membership
   is unchanged and only the attributed wipe happens.
3. **Monitors.** Only the discover/discover-ack handshake calls
   `register_peer`; **markers, prepares, snapshots and vacants create no
   monitor**. A dead incarnation that a peer never registered gets **no `:DOWN`
   at all**, and its late writes (worker/erpc channels are unordered with the
   coordinator's death — the code comment at ~L820-832 says exactly this) can
   land *after* whatever `:DOWN` did fire. Coordinator-sent markers, by
   contrast, are Erlang-signal-ordered before their incarnation's `:DOWN`
   (enforced as a delivery guard).

**Results (Nodes = {1,2,3}, MaxSeq = 4):**

* **`NoMissedDelivery` is VIOLATED — the window is real**, found in 14s at
  depth 9 (`tla/trace_asyncdown_window.txt`): nodes 1,2 pair on `{1,2}` (router
  1 `:ready`); node 2 heartbeats, then its coordinator restarts (the `:DOWN` is
  queued at node 1, not yet processed) and re-joins the group under its reset
  view `{2}`, claiming it on itself; the pre-restart marker lands and node 1 is
  `:ready` for `{1,2}` with an empty table — a broadcast from node 1 misses
  node 2's live member. This is the exact transient Finding B predicted.
* **`MissImpliesPendingDown` ("the window closes when the router's mailbox
  drains") is REFUTED** — and the witness is a *real* shape, not an artifact: if
  node 1 had **never registered node 2's first incarnation** (its discover-ack
  was still in flight), no monitor exists and **no `:DOWN` is ever delivered**
  for it. Node 1 then registers the *new* incarnation — whose discover/ack
  piggyback is **withheld** precisely because the new incarnation's re-grow
  moved the group onto node 1 and owes it a snapshot (scope.ex ~L743-750) — so
  nothing overwrites the agreement, and the dead incarnation's late marker
  makes node 1 stale-ready. Heals when the owed snapshot lands (it carries both
  the row and the newer marker).
* **`MissImpliesStaleResidue` ("...or the router holds a dead incarnation's
  agreement entry") is REFUTED too**, by a second-order shape with *no* dead
  incarnation residue at the router: node **1** restarts; node 2 processes the
  `:DOWN` with the new pid unregistered → **pure shrink** to `{2}`, re-homing
  the group onto itself; node 2's *pre-shrink* marker (live incarnation,
  asserting `{1,2}`) then lands at the re-paired node 1 → node 1 is
  stale-ready for `{1,2}` while the holder sits on `{2}`. The restart-triggered
  shrink is a view change racing exactly like Finding A's discovery — and every
  commit in the trace has an **empty B1 audience** (all growth from
  singletons), so the prepare gate never engages. Heals when the handshake
  re-grows node 2 and its owed snapshot lands.
* **`MissImpliesViewDivergence` HOLDS — the characterization.** Every reachable
  miss has the missed holder's committed view **different from the router's**:
  the miss lives strictly inside an asymmetric-convergence window (the holder is
  mid-churn relative to the router), i.e. **Finding A's class** — transient and
  self-healing, closed by the holder's convergence re-announcing through the
  B1/owed-snapshot machinery. A miss between two nodes *settled on the same
  committed view* would be a genuinely new bug class; none is reachable.
  Partial-clean (the async dimensions make exhaustion infeasible): `MaxSeq=3` —
  429M generated / 110.8M distinct, BFS depth 15, no violation (~10 min cap);
  `MaxSeq=4` — 419M generated / 115M distinct, BFS depth 13, no violation. All
  three refuted-invariant witnesses live at depths 9-12, well inside both
  searches, so the clean result is non-vacuous by construction.

**Takeaway.** The Finding B residual is real but no worse than Finding A: the
async `:DOWN` (plus the never-monitored and shrink-race variants) re-opens only
**asymmetric-convergence transients**, never a settled-view miss. The healing
signals are the same machinery the design already leans on (the `:DOWN` itself,
the owed-snapshot barrier, newest-seq-wins announces). It also sharpens the
severity discussion: the window is bounded not by `:DOWN` delivery alone but by
*convergence + owed-snapshot delivery* after a coordinator restart. Whether
zero-miss-during-restart-churn is required is the same product decision as
Finding A.

**Finding B residual — status (decided): reproduced end-to-end, DOCUMENTED,
fix deferred.** The model's 9-step counterexample now reproduces on a real
2-node cluster: `test/forum/muster_distributed_test.exs`, describe
`"coordinator restart behind an unprocessed :DOWN (TLA Finding B residual)"`,
kills S's coordinator, parks R's handling of both the old pid's `:DOWN` and
the new incarnation's registration (whichever arrives first freezes R's
coordinator loop `:ready` for `{R,S}`; both released by one event), freshly
joins the group on the restarted S (it self-routes under the reset ring), and
asserts the live miss — R `:ready`, R the group's router for the shared view,
S holding a live member, yet `Muster.targets/3` returning `{:ok, []}` — then
releases the parks and asserts the self-heal (both nodes re-converge and R's
delivery set includes S). A trace check asserts the `:DOWN` was applied only
after the release, i.e. the miss assertions ran strictly inside the held-open
window. The test is kept as a **characterization** of the accepted window
(it will fail — correctly — when a fix ships). The window is documented in
`README.md` ("Known transient window: peers learn of a restart
asynchronously").

A fix was designed, prototyped, and **deliberately backed out as too complex
for now**. For the record, the leading candidate ("restart-claim guard",
dual-claim): (a) for a `:ready` router to miss, sender and router must share a
view, so the only router that can miss a group freshly joined on the restarted
node S is the group's router under **S's last committed pre-restart view**;
(b) persist that view across coordinator restarts (written at every rebalance
commit, erased on a committed singleton view and on a fresh
`Forum.Supervisor` start) and load it into a second, normally-empty "guard
ring" sibling at init; (c) while armed (init → the first `:ready` that
accounts for every guard-view member as re-agreed or disconnected), a fresh
join claims on the current router AND, acked, on the guard router — **one
targeted `occupied/5`**, a direct ETS write on the peer that lands even while
the peer's coordinator is wedged (an init-time B1-style prepare round would
instead block all joins on the slowest peer *coordinator*, the exact
replicated failure mode); failures follow the existing remote-claim story.
Known residual even with the guard: the shrink-re-home shape (no join
involved, third refuted-invariant witness above) stays open in every design
considered — it is the irreducible Finding-A-class transient, healed by the
owed-snapshot barrier. If the fix is revived: flip the characterization
test's miss assertion to a no-miss assertion, and model the guard on
`tla/Muster2RestartDownAsync.tla` (arm at `Restart`, dual-write in
`HolderJoin` while armed, sticky disarm at first ready; check "no miss whose
holder's claim was an armed-window fresh join" — expected to hold — alongside
`MissImpliesViewDivergence`).

**Modeling notes.** Known simplifications, judged benign and documented in the
module header: Discover/Reregister register the *current* incarnation only (a
stale discover would monitor a dead pid → instant `:DOWN` → net no-op); and
when a `:DOWN` pops the old pid while a newer incarnation is registered mid
prepare-round, the code supersedes/cancels the round while the model leaves it
unchanged (the in-flight prepares still carry their invalidation). The
`Reregister` action models the withheld-piggyback ack (register without
asserting a view); the asserting variant is `Reregister` + an ordinary marker.

### `tla/Muster3RestartDown.tla` + `tla/Muster3DeltaRestartDown.tla` — sweep × restart, sweep × delta (was caveat 7)

The two remaining cross-mechanism compositions: the GC sweep (`Muster3`) had
only been verified on the single-group, no-restart base, with informal
fail-safe arguments for its interaction with the restart and the delta. Given
Finding B came from exactly this kind of composition, both are now built:

* **`Muster3RestartDown`** (composition #1, single-group): Muster3's
  `DropStale`/`Reap` verbatim, composed with the **Finding-B-corrected**
  restart (peer-side coordinator-pid `:DOWN` blanks the restarted node's
  agreement everywhere; old-incarnation in-flight messages dropped,
  FIFO-faithfully; occupancy ETS survives; `:converging` + singleton-promotion
  gate). The question: can the sweep, fed post-restart agreement state
  (`mv` wiped on the restarted node; its agreement blanked on every peer while
  they may still be `:ready` on the old shared view), tombstone a row a Ready
  router still needs?
* **`Muster3DeltaRestartDown`** (composition #2): Muster2DeltaRestartDown
  verbatim, plus `DropStale`/`Reap` **lifted to per-group rows** faithful to
  the code (the judge is per `{group, source}` row: `:present` ∧
  `source_agrees?(source, row_seq)` ∧ `find_node(group) != self`; agreement is
  per **source** with own rows always judgeable — `scope.ex` ~L1369-1449).
  This is the sweep × delta check: a delta's add-only apply is correct only if
  the receiver keeps its previous-generation **baseline**, and the sweep is the
  one mechanism that removes rows without a message from the source. The
  fail-safe argument (a baseline group by definition routes to the receiver, so
  the routes-away guard spares it) is judged under the *receiver's* committed
  view while the source computes the delta under *its own* ring generations —
  `NoMissedDelivery` checks whether `SourceAgrees` really makes the judge
  abstain across every mid-churn divergence, including post-restart (restart
  wipes the very `member_views` agreement `SourceAgrees` reads, and resets
  `applied_snapshot_seq`, while swept/reaped rows survive in the ETS table).

**Result: `NoMissedDelivery` holds in both.**

* `Muster3RestartDown`, `MaxSeq=2`, 3 nodes — **exhaustive**: 1,418,590
  distinct states, depth 20, 0 left on queue, no violation.
* `Muster3RestartDown`, `MaxSeq=4` — partial: **74.3M distinct (309.7M
  generated), BFS depth 14, no violation** at a 6-minute cap — past the
  depth-12 where the uncorrected restart model (Finding B) violated at
  `MaxSeq=4`.
* `Muster3DeltaRestartDown`, `MaxSeq=2`, 3 nodes, 2 groups (diverging rings) —
  **exhaustive**: 1,891,411 distinct states, depth 20, 0 left on queue, no
  violation. **Sweep-vacuous** (see the structural finding below).
* `Muster3DeltaRestartDown`, `MaxSeq=3`, no message bound (`_s3.cfg`) —
  partial: **35.2M distinct (142.1M generated), BFS depth 13, no violation**
  (6-minute cap). This is the **sweep-covering** run.
* `Muster3DeltaRestartDown`, `MaxSeq=4`, `|msgs|≤3` (`_s4.cfg`) — partial:
  **37.1M distinct (142.3M generated), BFS depth 12, no violation** (6-minute
  cap). This is the **delta-covering** run.

**Structural finding (why the multi-group sweep is deep).** In the multi-group
models snapshot emission is bound to `Commit` (`do_rebalance` is a per-round
quantity), so a commit that re-routes a held group **costs a seq** — and "a
held group re-routes away from me" is exactly the sweep's enabling condition
for own rows. At `MaxSeq=2` the budget (join + discover already spend 2) can
never fund such a commit, so **`DropStale` is unreachable and the exhaustive
`MaxSeq=2` run is sweep-vacuous** — unlike the single-group models, where
`Commit` emits no snapshot and the sweep fires at depth 6. First sweep:
`MaxSeq=3`, depth 7 (`_w1.cfg`). Same genre as Muster2Delta's
"delta needs `MaxSeq≥4`" finding; both are documented in the cfgs.

**Non-vacuity witnesses:**

* `Muster3RestartDown`: `NoSweep` (`_w1`) **violated** (depth 6) — a sweep
  fires; `NoSweepAfterRestart` (`_w2`) **violated** (depth 7) — a sweep fires
  *after* a coordinator restart, i.e. it judges post-restart agreement state.
* `Muster3DeltaRestartDown`: `NoSweepEver` (`_w1`, `MaxSeq=3`) **violated**
  (depth 7) — a sweep fires in the multi-group composition; `NoDeltaSent`
  (`_w3`, `MaxSeq=4`) **violated** (depth 10) — a delta is dispatched, well
  inside the depth-12 clean `_s4` search. `NoDeltaToSweptRouter` (`_w2` — a
  delta in flight to a router that has already swept) did **not** surface
  within a multi-minute `MaxSeq=4` search (depth 12, 46.4M distinct); kept as
  a documented probe, not a confirmed witness (same status as Muster2Delta's
  `NoWholesaleDrop`/`NoBaselineDelta`).

**Takeaway.** The informal caveat-7 arguments are now machine-checked: the
sweep's `SourceAgrees` + routes-away guard stays fail-safe under both a
coordinator restart (no agreement ⇒ no sweep; post-restart sweeps *do* happen
and stay safe) and the delta's baseline dependency (a baseline group routes to
the receiver, so the guard spares it, across every reachable mid-churn view
divergence). No code change needed.

## Caveats / what is NOT yet modeled (next steps)

1. ~~**`drop_stale_router_entries` sweep + tombstone GC** are not modeled.~~
   **DONE** — modeled in `tla/Muster3.tla`; `NoMissedDelivery` holds (exhaustive
   at `MaxSeq=2`, partial-clean at `MaxSeq=3`). See "Follow-up models" above. The
   feared *seq-guarded delete vs concurrent re-claim* under-delivery race does
   not occur: the sweep's routes-away guard means a node only tombstones rows for
   groups it does not route.
2. ~~**Only one group.**~~ **DONE** — modeled in `tla/Muster2Multi.tla`: two
   groups with **diverging per-group ring orders**, per-group `holds`/`occ`, and
   snapshots carrying a group-*set*. `NoMissedDelivery` holds per group
   (exhaustive at `MaxSeq=2`, partial-clean at `MaxSeq=3`), with non-vacuity
   witnesses confirming per-group router divergence is exercised. See "Follow-up
   models". ~~**Narrow sub-gap remaining:** the model assumes a correctly-computed
   snapshot group-set, so it does not verify the code's `groups_to_reannounce`
   delta-vs-full *selection* itself.~~ **DONE** — modeled in `tla/Muster2Delta.tla`
   (the FULL/DELTA choice, only-moved-groups delta payload, and per-source
   wholesale `applied_snapshot_seq` watermark); `NoMissedDelivery` holds
   (exhaustive `MaxSeq=2` non-delta baseline, partial-clean `MaxSeq=4` delta
   coverage). The selection + receiver apply are also directly unit-tested. See
   "Follow-up models".
3. **Coordinator restart** — split into two cases:
   * **Restart-in-place under the same live node name** (a coordinator crash from
     the crash-on-prepare-timeout / snapshot-failure hatch; the node stays up,
     ring resets to `[node()]`, occupancy table survives, re-discovery, singleton
     promotion). ~~Excluded.~~ **DONE (with a correction — see Finding B)** —
     modeled in `tla/Muster2Restart.tla` (safety) and `tla/Muster2RestartLive.tla`
     (the hatch's liveness); `RoundsResolve` / `<>[]RoundsQuiet` hold. **Safety
     needed a fix:** those models assumed peers see no `:DOWN` on a coordinator
     restart, which is unfaithful (peers monitor the coordinator PID); the
     restart × delta follow-up exposed this as a spurious `NoMissedDelivery`
     violation at `MaxSeq=4`. With the peer-pid `:DOWN` modeled faithfully
     (`tla/Muster2DeltaRestartDown.tla`) `NoMissedDelivery` holds again. The
     async-`:DOWN`-latency transient (Finding B residual) is now **also modeled**
     (`tla/Muster2RestartDownAsync.tla`): real, but characterized as
     Finding-A-class (`MissImpliesViewDivergence` holds). This is NOT
     covered by the no-name-reuse assumption (that is about deployments; this is a
     supervisor restart of a still-live node). See Finding B and "Follow-up models".
   * **Node name reuse across deployments** (a brand-new incarnation reusing a
     name, resetting seq) remains excluded, consistent with the user assumption
     that nodes do not come back and reset their seq. If that is relaxed, add it.
4. ~~**Ring = `min`.**~~ **DONE (for the single-group model)** — generalized in
   `tla/Muster2Ring.tla`: the router is now a `RingRank` constant (any total-order
   ring). `NoMissedDelivery` does **not** depend on `min` — proven WLOG by a
   relabeling argument (node ids are compared only inside `Router`, so any two
   total-order rings are isomorphic by relabeling) and confirmed empirically by
   *bit-identical* state counts for a non-`min` ring at `MaxSeq∈{2,3}`, N=3
   (exhaustive). See "Follow-up models" above. **Correction to a prior claim:**
   generalizing the ring does **not** recover TLC `SYMMETRY` — any position-based
   router distinguishes node ids, so node-id symmetry is unsound regardless of
   `min` vs uninterpreted; a 4-node *exhaustive* proof stays infeasible and the
   4-node story is necessarily bounded (a deeper bounded run is included). The
   richer *per-group-different-order* behaviour of real hashing is inherently
   **multi-group** (caveat 2), not reachable in a single-group model.
5. **Message ordering.** Modeled as a fully unordered set (faithful for `:erpc`
   worker calls and cross-channel marker/snapshot interleaving; a safe
   over-approximation for same-pair dist sends — see Finding A's FIFO note).
   **Low value to pursue:** the unordered model is a strict *over*-approximation
   (its trace set is a superset of any FIFO refinement), so a property that
   *holds* here — which `NoMissedDelivery` does in every fix model — holds under
   FIFO too. A FIFO refinement cannot surface a new violation; it is only useful
   for confirming a *found* counterexample is FIFO-real, which was already done by
   hand for Finding A. Not planned.
6. ~~**Liveness.** Only safety is checked.~~ **DONE** — modeled in
   `tla/Muster2Live.tla` under explicit fairness; `<>[]RoundsQuiet` and the
   `RoundsResolve` leads-to both hold (exhaustive at 2 and 3 nodes, `MaxSeq=2`).
   The crash-on-prepare-timeout hatch for an up-but-unreachable peer (which
   `Muster2Live` cannot reach, being message-reliable) is now **also checked** in
   `tla/Muster2RestartLive.tla`: a droppable prepare wedges a round and the
   crash-restart resolves it; `RoundsResolve` and `<>[]RoundsQuiet` hold
   (exhaustive at 3 nodes, `MaxSeq=2`). See "Follow-up models" above.
7. ~~**Remaining cross-mechanism compositions (open, ranked low).**~~ **DONE**
   — both compositions are now modeled and checked clean:
   **sweep × restart** in `tla/Muster3RestartDown.tla` (`NoMissedDelivery`
   holds; exhaustive at `MaxSeq=2`, partial-clean at `MaxSeq=4` past Finding
   B's depth) and **sweep × delta/multi-group × restart** in
   `tla/Muster3DeltaRestartDown.tla` (holds; exhaustive at `MaxSeq=2`,
   sweep-covering partial at `MaxSeq=3`, delta-covering partial at `MaxSeq=4`),
   with confirmed sweep / post-restart-sweep / delta witnesses. The informal
   fail-safe arguments (no agreement ⇒ no sweep; baseline groups route to the
   receiver so the routes-away guard spares them) are machine-checked. See
   "Follow-up models". One narrow residual, noted there: the
   delta-to-an-already-swept-router probe (`_w2`) did not surface within its
   search budget, so that exact shape is covered by the clean partials, not by
   a confirmed witness. Still open (unchanged): `Muster2RestartDownAsync` is
   single-group and sweep-less — its composition with the delta selection is
   unchecked (the sync `Muster2DeltaRestartDown` covers restart × delta; the
   async window is view-level, so multi-group is not expected to change its
   class), and its composition with the occupancy GC sweep is unchecked too
   (`Muster3RestartDown` composes the sweep with the *sync* corrected restart
   only; the async residual could in principle let the sweep judge under a
   dead incarnation's not-yet-wiped agreement, though the routes-away guard's
   fail-safe argument is unchanged). Both are expected Finding-A-class at
   worst; neither is built.
8. **Marker seq abstraction (noted, declined).** Every `NoMissedDelivery` model
   stamps re-announce markers with a fresh per-message seq, while the real
   heartbeat carries the stable committed `view_seq` — the abstraction
   `Muster2Cancel` showed can hide *liveness* bugs (stranding). For *safety*
   it is sound by a content-level simulation: a stable-seq marker that would be
   rejected (seq ≤ current) maps to "never deliver that marker" in the
   fresh-bump model (delivery is optional), and one that applies asserts the
   same content at a seq consistent with the per-node monotonic counter, so
   every stable-seq `mv`-content evolution is reproducible fresh-bump. The
   seq-axis behaviour itself (stranding + the `cancel_view_change` fix) is
   machine-checked separately in `Muster2Cancel`.
