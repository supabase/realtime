# Muster TLA+ model

A TLA+/TLC model of `Forum.Muster`'s routing-safety story. See
`../TLA_FINDINGS.md` for the full write-up (what is modeled, findings, next
steps).

## Files

* `Muster.tla` (+ `.cfg`) — the baseline routing model. **Exhibits Finding A**
  (`NoMissedDelivery` is violated; see `../TLA_FINDINGS.md`).
* `Muster2.tla` (+ `.cfg`) — the same model plus the **B1 two-phase view
  adoption** fix. `NoMissedDelivery` **holds** (exhaustive at `MaxSeq=3`).
* `Muster3.tla` (+ `.cfg`) — Muster2 plus the **occupancy GC sweep**
  (`drop_stale_router_entries`) and **tombstone reap** (`reap_tombstones`).
  `NoMissedDelivery` **holds** (exhaustive at `MaxSeq=2`, partial-clean at
  `MaxSeq=3`).
* `Muster2Live.tla` (+ `.cfg`) — Muster2 with **fairness** + a **liveness**
  property (every prepare round eventually resolves). Holds (exhaustive at 2 and
  3 nodes, `MaxSeq=2`). Run without `-deadlock`? No — keep `-deadlock` (natural
  seq-bounded termination is not a real deadlock).
* `Muster2Multi.tla` (+ `.cfg`, `_w1/_w2/_w3.cfg`) — Muster2 **generalized to
  many groups** (caveat 2): two groups with diverging per-group ring orders,
  per-group `holds`/`occ`, snapshots carrying a group-set. `NoMissedDelivery`
  holds **per group** (exhaustive at `MaxSeq=2`, partial-clean at `MaxSeq=3`);
  the `_w1/_w2/_w3` probes are non-vacuity witnesses (expected VIOLATED).
* `Muster2Delta.tla` (+ `.cfg`, `_s4.cfg`, `_w1.cfg`) — Muster2Multi with the
  rebalance snapshot **selection modeled faithfully**: the FULL(wipe+replace) vs
  DELTA(add-only) choice, the `groups_to_reannounce` delta = only-moved-groups
  payload, and the per-source **wholesale `applied_snapshot_seq` watermark** that
  Muster2Multi abstracted (it always sent the complete set + add-only apply).
  `NoMissedDelivery` **holds** (exhaustive at `MaxSeq=2` — the NON-delta baseline;
  partial-clean at `MaxSeq=4` — the delta-covering run, `_s4.cfg`). Structural
  finding: with consistent-hashing rings the add-only DELTA path is reachable
  **only via a ≥3-node shrink** (growth can only route a group onto a *new* node,
  always a FULL), witnessed by `_w1.cfg` (delta dispatched at BFS depth 10).
* `Muster2DeltaRestart.tla` (+ `.cfg`, `_s4.cfg`, `_wr.cfg`, `_wd.cfg`) —
  **Muster2Delta composed with the coordinator restart action** (the one
  cross-mechanism interaction its predecessors checked only in isolation:
  restart × delta). A restart wipes `member_views`, `owed_snapshots` **and**
  `applied_snapshot_seq` (all coordinator State) while the occupancy ETS table
  **survives**. This composition **found a `NoMissedDelivery` violation at
  `MaxSeq=4`** (exhaustive-clean at `MaxSeq=2`) — see Finding B in
  `../TLA_FINDINGS.md`. It is a **faithfulness artifact**: the restart models
  omitted the peer-side coordinator-pid `:DOWN`. Non-vacuity: `_wr.cfg` witnesses
  a restarted node recovering into a Ready multi-node router; `_wd.cfg` witnesses
  a DELTA riding alongside a restart (expected VIOLATED).
* `Muster2DeltaRestartDown.tla` (+ `.cfg`, `_s4.cfg`) — the **corrected** restart
  model: restart also fires the peer-side `:DOWN` (blanks the restarted node's
  `member_views` agreement on every peer + drops its old in-flight messages,
  FIFO-faithfully). `NoMissedDelivery` **holds** (exhaustive `MaxSeq=2`,
  partial-clean `MaxSeq=4` past the depth-12 where the base violated), confirming
  the peer-pid `:DOWN` is the mechanism that keeps the restart path safe.
* `Muster2RestartDownAsync.tla` (+ `.cfg`, `_char.cfg`, `_char3.cfg`,
  `_strong.cfg`) — the **async peer-side coordinator-pid `:DOWN`** (the Finding
  B residual the sync model collapsed to zero latency), single-group, with the
  `:DOWN` modeled faithfully to scope.ex ~L815-883: per-incarnation **pid
  attribution** of occ/mv wipes, `:DOWN` = **pure shrink** when no newer
  incarnation is registered (members derive from the `peers` pid map), only
  discover/ack register (markers/prepares/snapshots/vacants create no
  monitor), and coordinator-sent markers ordered before their incarnation's
  `:DOWN` while worker/erpc channels stay unordered. Results: `NoMissedDelivery`
  **VIOLATED** (expected — the window is real; trace in
  `trace_asyncdown_window.txt`); two candidate bounds (`MissImpliesPendingDown`,
  `MissImpliesStaleResidue`) **REFUTED by real shapes** (never-monitored first
  incarnation + withheld ack piggyback; restart-triggered peer shrink);
  the characterization `MissImpliesViewDivergence` (every miss is a Finding-A
  class asymmetric-convergence window) **holds** partial-clean (MaxSeq=3 depth
  15 / 110M distinct; MaxSeq=4 depth 13 / 115M distinct). See TLA_FINDINGS.md.
* `MusterBounded.tla` / `Muster2Bounded.tla` (+ `.cfg`) — bounded **4-node**
  harnesses (`|msgs|` capped via `CONSTRAINT`). The baseline finds Finding A at 4
  nodes (positive control); the fix shows no violation over a large partial run.
  Not a proof — 4 nodes is not exhaustible, and `Router == min` breaks node
  symmetry so no `SYMMETRY` set applies.
* `trace_finding1.txt` — saved counterexample trace for Finding A.
* `trace_restart_artifact.txt` — the Finding B (modeling-artifact) trace.
* `trace_asyncdown_window.txt` — the async-`:DOWN` window miss
  (Muster2RestartDownAsync, 9 steps).

See `../TLA_FINDINGS.md` → "Follow-up models" for the full write-up and state
counts.

Run `Muster2` the same way, swapping the file/config:

```bash
mise exec java@corretto-26.0.1.8.1 -- \
  java -Djava.io.tmpdir="$TMPDIR" -XX:+UseParallelGC -cp ../tla2tools.jar \
  tlc2.TLC -workers auto -deadlock -config Muster2.cfg Muster2.tla
```

`MaxSeq=4` is infeasible to exhaust here (state count grows unbounded); `MaxSeq=3`
is exhaustive and is the proof.

## Run

Java is available via `mise` (Amazon Corretto 26); `tla2tools.jar` (TLC 2.19) is
in the parent dir. TLC needs a writable temp dir and a loopback socket, so set
`java.io.tmpdir` and run outside the command sandbox.

```bash
cd forum/tla
mise exec java@corretto-26.0.1.8.1 -- \
  java -Djava.io.tmpdir="$TMPDIR" -XX:+UseParallelGC -cp ../tla2tools.jar \
  tlc2.TLC -workers auto -deadlock -config Muster.cfg Muster.tla
```

`-deadlock` is required: the bounded seq counter makes behaviours terminate,
which is not a real deadlock and would otherwise cut off exploration early.
