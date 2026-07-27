# Design note: anti-entropy for Muster's occupancy table

**Status:** proposal / not implemented
**Scope:** `Forum.Muster.Scope` occupancy table only
**Related:** [`muster-broadcast.md`](muster-broadcast.md), top-level `README.md`

## 1. Problem

A router's occupancy table (`{group, source_node} => :present | tombstone`) is the
input to `Forum.Muster.targets/3`. Two kinds of error are possible:

| Error | Table says | Reality | Broadcast effect |
| --- | --- | --- | --- |
| **False positive** | `:present` | source does *not* hold group | over-deliver (extra traffic) — **harmless** |
| **False negative** | absent | source *does* hold group | **miss** — a live member never gets the message |

Only the false negative is a correctness bug. Everything Muster does around the
table is arranged so that a false negative can only exist while the router is
*not* trusted:

- The **readiness barrier** (`can_decide?/2`) makes `targets/3` return
  `{:error, :flood}` unless the router is `:ready` *and* the sender's view hash
  matches. While incomplete, the caller floods → no miss.
- Every *known* way the table can drift has a targeted, bounded-latency healer:
  `occupied/4` (atomic with join, retried on next join), `vacant_batch`
  (re-queued on failure), the rebalance snapshot / delta
  (`receive_node_state` / `apply_delta` on every membership edge),
  `drop_stale_router_entries` (false-positive GC), the view heartbeat +
  `rediscover` (dropped announcements / restart-in-place), and
  `reannounce_local_groups_at_init` (restart re-push from the shard tables).

**The residual gap:** there is no periodic *source → router* reconciliation of
the present set that is independent of a membership edge. Once a router reaches
`:ready`, it trusts its table for a group **forever** and never re-floods it. A
source only re-pushes occupancy on (a) the first local join of a group or (b) a
rebalance in which that group *moves*. So if a `:present` row is ever lost — or
never written — while the router stays `:ready` and membership is stable, the
result is a **permanent, silent miss** with nothing in the system to repair it.

I could not construct a concrete reachable path to such a loss under today's
code (I traced router restart-in-place, cooldown re-claim, and snapshot
reordering; the barrier floods and the surviving rows stay attributed to the
still-live source pid). So this is **defense-in-depth**, not a fix for a named
hole. Its value is:

> **Update (2026-07-20, TLA Finding D): a concrete reachable path now
> exists.** The trace above covered the *coordinator* restart-in-place,
> where the occupancy table survives (it is owned by `Forum.Supervisor`).
> The **escalated** restart — `Forum.Supervisor` itself restarted by the
> host app on a still-live node, rebuilding every table empty while the
> name and the monotonic seq survive — combined with the
> register-before-`:DOWN` race (the peer registers the new incarnation
> before processing the old pid's `:DOWN`, so the `:DOWN` is an attributed
> no-op, the peer sees no membership edge, and its rows are never
> re-pushed) yields exactly the permanent, silent miss described here,
> machine-checked in `tla/Muster2SupRestart.tla` (`NoQuiescentMiss`
> violated; see `TLA_FINDINGS.md` → "Finding D"), and the path is
> **operationally reachable** (the host restarts forum's tree in place
> under a `:one_for_one`). Note, however, that the tree restart also
> deterministically drops every LOCAL membership (a loss no source→router
> re-assert can repair — the pid-level data existed only on the restarted
> node), so anti-entropy alone cannot be the Finding-D fix. The agreed
> direction (2026-07-21, deferred) is a node-fatal
> `significant`/`auto_shutdown` child spec, optionally composed with a
> durable-table vault — see Finding D's disposition. Anti-entropy remains
> valuable on its own terms: it heals the routing half of any such loss
> within one interval and covers unanticipated row-loss classes (§1).

1. **Neutralizing the node-name-reuse hazard.** Reusing a node name currently
   loses broadcasts *permanently* (a load-bearing deployment assumption). A
   periodic full re-assert re-establishes occupancy for the new incarnation
   within one interval, softening that assumption from load-bearing to
   best-effort.
2. **Converting a fragile invariant into a self-healing one.** Correctness today
   is "correct iff every incremental channel is bug-free," resting on a lot of
   subtle seq / tombstone / writer-pid reasoning. Anti-entropy makes it "correct,
   and self-heals regardless" against unanticipated bugs, ETS anomalies, or
   attribution edge cases.

## 2. Non-goals

- **Not** a replacement for the readiness barrier, rebalance snapshots, or the
  per-channel retries. It sits *underneath* them as a slow backstop.
- **Not** a consensus / gossip membership layer. Membership is still driven by
  `net_kernel` + discovery; anti-entropy only reconciles occupancy *data*.
- **Not** aimed at convergence *speed*. The event-driven paths converge in
  milliseconds; this runs on the order of a minute.

## 3. Design overview

**One direction, present-set only.** Each source node periodically re-asserts,
per router, the full set of groups it currently holds that route to that router
under the current ring. This is exactly what `do_rebalance` computes, but scoped
to *all held groups* rather than *moved groups*, and triggered by a timer rather
than a membership change.

The re-assert reuses the existing full-snapshot receiver path
(`receive_node_state`): it upserts the held rows at a fresh seq and tombstones
that source's stale rows below that seq. That means it repairs **both**
directions as a bonus — a missing `:present` row is re-inserted, and a stale
`:present` row the source no longer holds is tombstoned — at no extra cost.

```
timer (only when :ready and fully settled)
  └─ held = union of all shards' held groups            (same gather as rebalance, cheap: local calls)
     router_of = group -> Ring.find_node(ring, group)
     for each router R with ≥1 held group routing to it:
        send R a full snapshot of {groups held that route to R} via receive_node_state
```

### Why reuse `receive_node_state` on the receiver

- The per-source seq guard (`applied_snapshot_seq`) already makes a *sequence* of
  overlapping full-state rounds safe: a reconcile round and a rebalance round are
  both "source's full held set at dispatch time," so dropping whichever has the
  lower seq is correct. Sharing the guard is not just convenient, it's the right
  semantics.
- `upsert_if_newer` + `tombstone_stale_source_rows` are already seq-guarded, so a
  reconcile can never clobber a fresh concurrent claim from the source's shards
  or resurrect a vacated group.
- Folding the carried view marker (`put_member_view` + `update_status`) is a
  no-op for readiness in steady state (the source's view hash already matches
  everyone's); it merely advances the source's watermark, which keeps
  `drop_stale_router_entries` able to judge the freshly-stamped rows.

### What must be *new* (not reused from rebalance)

The dispatch and completion handling must differ in two ways:

1. **Gating.** Run only when `status == :ready` **and** `owed_snapshots == %{}`
   (fully settled). This is precisely the window where the gap exists; while
   `:rebalancing` / `:converging` the rebalance path is already re-pushing
   everything, so a reconcile would be redundant and add churn.
2. **Non-crashing failure policy.** A failed *rebalance* snapshot crashes the
   coordinator on purpose ("restart re-announces from a clean slate"). A failed
   *reconcile* must **not** crash — it should log and simply retry on the next
   interval. This needs a distinct worker tag / done-handler
   (`{:anti_entropy_done, router, seq}`) so it doesn't route into the existing
   `:node_state_done` crash branch.

## 4. Interaction with existing invariants

- **Readiness barrier:** unchanged. Reconcile only *runs* when already `:ready`;
  it never flips status by itself in steady state.
- **Tombstones / GC:** reconcile writes `:present` rows (raised seqs) and
  tombstones stale ones; the periodic `reap_tombstones` sweep reaps them on the
  normal window. Re-bumping the seq of live `:present` rows every interval is
  fine — seq is monotonic and present rows are never reaped.
- **`drop_stale_router_entries`:** complementary. Reconcile advances the source's
  watermark (via the folded marker), so the receiver's own stale-row sweep can
  still judge the newly-stamped rows.
- **`owed_snapshots` suppression:** by gating on `owed_snapshots == %{}` we never
  start a reconcile while a rebalance snapshot is in flight, so the two never
  contend over the same source→router marker suppression.
- **Node-name reuse:** the new incarnation's first reconcile re-asserts the full
  held set under its fresh pid/seq; the full snapshot tombstones the old
  incarnation's surviving rows. The permanent miss becomes a ≤ one-interval miss.

## 5. Cost and the scale path

**Simple (recommended v1):** full held-set snapshot per router per interval.
Cost is `O(groups held)` payload per source per interval. With a minute-scale
interval and per-router batching this is negligible for moderate group counts,
and it is dead simple (reuses the snapshot machinery wholesale).

**Digest-compare (future, if group counts are large):** classic Merkle/digest
anti-entropy. Each interval a source sends each router a cheap *digest* (e.g.
count + a seq-fold hash of its held groups routing to that router). The router
compares against its own `:present` rows for that source and requests a full
snapshot **only on mismatch**. Steady-state cost drops to `O(1)` per
source→router pair per interval, with full transfer only when divergence is
actually detected. This also cleanly detects false positives (router has an
extra row → digest mismatch → full snapshot → tombstone-stale). More moving
parts; defer until measured need.

A middle option is **rotating-slice** reconciliation: each tick reconcile only
groups whose `phash2` falls in a rotating window, bounding per-tick cost while
covering everything over N ticks. Mention only; probably unnecessary.

## 6. Config

- `:anti_entropy_interval_ms` — how often a settled source reconciles its held
  set to its routers. Default: a multiple of `:view_heartbeat_interval_ms`
  (e.g. `6 *` → ~60s), or `:infinity` / `0` to disable entirely. Disabled by
  default vs. on by default is an open question (§8).

The timer schedules like the others (`schedule_view_heartbeat` pattern), runs
its work as local gather + fire-and-forget RPC workers (never blocking the Scope
loop), and re-schedules itself.

## 7. Testing

- **Injected divergence heals:** with a 2-node cluster at `:ready`, delete a
  `:present` row directly from the router's ETS table, assert `targets/3` misses
  it, then assert it reappears within one interval and `targets/3` is correct.
- **Reconcile does not disturb steady state:** run reconcile repeatedly on an
  agreeing cluster and assert status stays `:ready`, view hash unchanged, and no
  spurious floods.
- **Reconcile loses to a fresh claim:** race a reconcile round (lower seq) behind
  a concurrent `occupied` (higher seq) via the existing `tp_span` force-ordering
  hooks; assert the fresh claim survives.
- **Failed reconcile does not crash:** make the RPC fail; assert the coordinator
  logs and stays up (contrast with the rebalance-snapshot crash path).
- **Name-reuse heal (distributed):** simulate an incarnation swap and assert
  occupancy is re-established within one interval.

## 8. Open questions

1. **On or off by default?** Given no reachable hole today, shipping it
   *disabled* (opt-in via config) is defensible; shipping it *enabled* at a slow
   cadence is the "insurance always on" stance. Leaning enabled-but-slow.
2. **Full-snapshot vs digest for v1.** Recommend full-snapshot; revisit if a
   node routinely holds enough groups that a per-interval full re-assert is
   material.
3. **Should reconcile ever *raise* readiness?** Proposal says no (it only runs
   when already `:ready`). Keeps anti-entropy purely about data, not the barrier.

## 9. Recommendation

> **Refined after the concurrency analysis in §11:** use an **add-only**
> reconcile (reuse the `apply_delta` receiver path), **not** a full-snapshot
> wipe. A full snapshot's tombstone-stale wipe buys only false-positive cleanup,
> which `drop_stale_router_entries` already provides, while adding a strict
> completeness requirement and a more delicate interaction with rebalance's delta
> baseline. Add-only cannot create a miss and cannot corrupt a concurrent
> rebalance; its worst case is transient over-delivery that existing GC cleans up.
> See §10 for the plan and §11 for why.

Add the **source→router, present-set, add-only** reconcile, gated on `:ready` +
settled, on a slow timer, with a **non-crashing** completion handler. It reuses
the existing `apply_delta` receiver and the per-source seq machinery almost
entirely; the genuinely new surface is one timer, one synchronous held-set gather
(a barrier read on the shards), a per-router group-by, and one non-crashing
worker-done handler. Ship it enabled at a ~60s cadence. Defer digest-compare
until group-count growth makes the per-interval re-assert measurably expensive.

## 10. Implementation plan

### 10.0 Approach

Add-only reconcile, reusing `Forum.Muster.Scope.apply_delta/6` →
`{:apply_delta}` on the receiver. Each settled source periodically re-asserts
(as an add-only, seq-guarded upsert) the groups it holds that route to each
remote router under the current ring. Nothing is wiped; removes stay owned by the
receiver's `drop_stale_router_entries`.

### 10.1 The load-bearing discipline: stamp seq, then gather via a barrier

This is the one subtle correctness constraint (see §11 for the proof). The
reconcile MUST:

1. Stamp `ae_seq = next_seq()` in the Scope process **first**.
2. Gather the held set with a **synchronous** call into each shard (a FIFO
   barrier), **not** `Shard.groups/1` — that helper is a direct ETS read with no
   barrier, so it can report a group whose concurrent leave will dispatch a
   `vacant_batch` at a seq lower than `ae_seq`, resurrecting a vacated row.

`{:rebalance}` already provides such a barrier but has side effects
(`normalize_pending_for_rebalance`, `settle_moved_pending`). So add a **new,
side-effect-free** synchronous shard call:

```elixir
# shard.ex
def handle_call(:held_groups, _from, state) do
  {:reply, {:held, held_groups(state)}, state}
end
```

Held set = `:occupied | :cooldown | :occupied_pending` (identical to the
rebalance gather; `:cooldown` is included because the router still believes we
hold it until the vacant flush lands).

### 10.2 `scope.ex` changes

1. **Config plumbing.** New `:anti_entropy_interval_ms`
   (`:infinity`/`0` disables). Default = `6 * view_heartbeat_interval_ms`
   (~60s). Add to `State`, validate in `Forum.Muster.start_link/2` and
   `Scope.init/2` alongside the existing interval knobs.
2. **Schedule.** `schedule_anti_entropy/1` (mirrors `schedule_view_heartbeat/1`),
   armed in `handle_continue(:discover, …)`; no-op when disabled.
3. **`handle_info(:anti_entropy, state)`:**
   - **Gate:** run only when
     `:persistent_term status == :ready` **and** `state.owed_snapshots == %{}`
     **and** `map_size(state.members) > 1`. Otherwise just reschedule (a
     rebalance is already re-pushing, or we're singleton).
   - `ae_seq = next_seq()`.
   - Synchronous held-set gather across shards (10.1), union.
   - `router_of = &Ring.find_node(ring, &1)`; `group_by` router; drop the self
     entry (self rows are always judgeable and written directly).
   - For each remote router with ≥1 held group: `spawn_rpc_worker` calling
     `apply_delta(scope, node(), groups, own_view_hash, ae_seq, self())`, tagged
     `{:anti_entropy_done, router, ae_seq}`.
   - **Do not** set `owed_snapshots` and **do not** bump `view_seq`: in steady
     state R already agrees with us; the marker `apply_delta` folds is idempotent
     and only advances R's watermark for us (which is exactly what keeps
     `drop_stale_router_entries` able to judge the freshly-stamped rows). See
     §11.4.
   - Reschedule.
4. **Non-crashing completion handler** `handle_info({{:anti_entropy_done, router,
   _seq}, _ref, :process, _pid, exit_reason}, state)`: on `:ok` no-op; on failure
   **log and drop** (contrast the rebalance `:node_state_done` handler, which
   crashes on purpose). A failed reconcile simply retries next interval.
5. **Telemetry / trace points:** `:muster_anti_entropy_start` (scope, node,
   held_count, router_count), reuse `:muster_delta_received` on the receiver.

### 10.3 Tests (`muster_test.exs` + `muster_distributed_test.exs`)

- **Heals an injected miss:** 2-node `:ready` cluster; delete a `:present` row
  from the router's ETS directly; assert `targets/3` misses, then reappears
  within one interval and `targets/3` is correct.
- **No-resurrection under concurrent leave:** force-order a `vacant_batch`
  against a reconcile round via the existing `tp_span` hooks; assert the vacated
  group is not resurrected (this is the §11.1 guarantee).
- **Idempotent in steady state:** run reconcile repeatedly on an agreeing
  cluster; assert status stays `:ready`, `view_hash` unchanged, no spurious
  status flips.
- **Rebalance races (see §11):** (a) rebalance starts while a reconcile RPC is in
  flight → newer round wins, no miss; (b) reconcile lands after a delta →
  dropped by the seq guard or merged as harmless over-delivery.
- **Failed reconcile does not crash** the coordinator (contrast the rebalance
  snapshot crash path).
- **Name-reuse heal (distributed):** simulate an incarnation swap; occupancy
  re-established within one interval.

### 10.4 Docs

Update `README.md` (failure-handling section) and the `Forum.Muster.start_link/2`
docstring for the new option; add a short "anti-entropy backstop" note to
`muster-broadcast.md` §1. Keep this design note as the rationale of record.

## 11. Integrity analysis: reconcile × rebalance

> **Model-checked (2026-07-21).** This section's hand argument is now
> mechanized in `tla/Muster2AntiEntropy.tla` (see `TLA_FINDINGS.md` →
> "the anti-entropy reconcile backstop"). Composing the add-only reconcile
> onto the multi-group B1 + delta-selection model, `NoMissedDelivery` **holds**
> under both a barrier gather and the forbidden unsynchronized gather
> (exhaustive at `MaxSeq=2` — reconcile-vacuous baseline; partial-clean at
> `MaxSeq=4`, BFS depth 13, past the depth-11 where reconcile first fires),
> confirming §11.3's "add-only can only add, never miss". The rejected
> full-snapshot variant **holds with a complete payload** (§11.5) but
> **VIOLATES `NoMissedDelivery` with an incomplete one** (§11.4's completeness
> obligation: an incomplete full payload wipes a still-held row), which is why
> the barrier gather (§10.1) and add-only (§9) are both load-bearing. The
> *healing* half (a lost row is re-added within one interval) is liveness and
> is intentionally out of the model's scope, consistent with the doc's
> argument here.

The reconcile writes occupancy that a rebalance also writes, from a
fire-and-forget worker, so the two can interleave. This section shows the
add-only reconcile is safe in every ordering, and why the full-snapshot variant
is safe-but-fragile.

### 11.1 The stamp-then-barrier discipline forbids resurrection

Occupancy rows are ordered only by per-source `seq`. A reconcile add is an
`upsert_if_newer` at `ae_seq`. The only hazard is re-asserting a group the source
has actually vacated (a false positive that `drop_stale` won't clean, since the
group still routes to the same router). That requires including a group `G` in
the held set whose `vacant_batch` carries `seq_vac < ae_seq`.

With `ae_seq` stamped **before** a **synchronous** shard gather:

- If the shard processed `G`'s leave before replying to `:held_groups`, `G` is
  **not** in the held set → not re-asserted. Safe.
- If the shard had not processed the leave at reply time, then its
  `vacant_batch` (dispatched only *after* it processes the leave) is stamped
  *after* the reply, which is *after* `ae_seq` → `seq_vac > ae_seq` →
  `tombstone_if_newer` wins over the reconcile's upsert. Safe.

The `seq_vac < ae_seq ∧ G ∈ held` case is therefore unreachable. This is the
same argument that makes the rebalance gather's wipe safe, and it is exactly why
`Shard.groups/1` (an unsynchronized ETS read) must **not** be used — without the
barrier, `seq_vac` and `ae_seq` are unordered and resurrection becomes possible.

### 11.2 Rebalance *before* a reconcile

The reconcile is gated on `:ready` + `owed_snapshots == %{}`, i.e. the previous
rebalance has fully settled and its ring is adopted. So the reconcile computes
its `router_of` mapping under the post-rebalance ring; there is no stale-ring
window. If a rebalance is still `:rebalancing`/`:converging`, the reconcile skips
the tick entirely.

### 11.3 Rebalance *after* / *concurrent with* a reconcile RPC

A reconcile RPC to router `R` (seq `ae_seq`) can still be in flight when a new
rebalance starts. Because both `next_seq()` stamps happen in the single Scope
process and the reconcile only runs when no rebalance is outstanding, any
later-starting rebalance stamps `rb_seq > ae_seq`. On `R`:

- **Rebalance round lands first** (`applied_snapshot_seq[S] = rb_seq`): the later
  reconcile `apply_delta` (`ae_seq < rb_seq`) is **dropped wholesale** by the
  per-source seq guard. No effect.
- **Reconcile lands first** (`applied = ae_seq`): its adds apply; then the
  rebalance round (`rb_seq > ae_seq`) applies normally on top. Because reconcile
  is **add-only**, the worst it can leave is a few `:present` rows for groups that
  the rebalance moved *away* from `R` — pure false positives (over-delivery),
  reaped by `R`'s own `drop_stale_router_entries` once `R` adopts the new view.
  **Never a miss.**

This is the payoff of add-only: a reconcile can neither delete a row a rebalance
needs nor resurrect one it dropped; it can only transiently *add*, and adds are
correctness-safe.

### 11.4 Why we neither wipe, set `owed_snapshots`, nor bump `view_seq`

- **No wipe (add-only).** A full snapshot's `tombstone_stale_source_rows` would
  require the reconcile's per-router set to be *complete* under `ae_seq`'s ring
  (an incomplete set would tombstone a still-held group → a miss deltas won't
  heal). Add-only removes that requirement outright; false-positive cleanup is
  delegated to `drop_stale_router_entries`, which already does exactly this.
- **No `owed_snapshots`.** That suppression exists so a bare view marker can't
  let a peer count us as "agreed" *before* our post-rebalance data lands. In the
  reconcile's gating window `R` already agrees with us and has for a while, so
  there is no such ordering hazard; the reconcile only repairs data.
- **No `view_seq` bump.** `view_seq` (the announce watermark) stays owned by
  rebalance/init. The `apply_delta` the reconcile sends still folds
  `put_member_view(S, view_hash, ae_seq)` on `R`, advancing `R`'s watermark for
  `S` to `ae_seq` — which is required so `drop_stale_router_entries` can judge the
  rows the reconcile just stamped at `ae_seq` (it needs `row_seq <= watermark`).
  Reusing `apply_delta` gives this for free; a data-only variant that skipped the
  marker would strand the watermark behind the rows and quietly disable the
  receiver's stale-row GC for that source.

### 11.5 The full-snapshot variant, for the record

A full-snapshot reconcile (`receive_node_state`) is *also* safe — the §11.3 seq
guard still keeps the newest round, and §11.1 still forbids resurrection — but it
adds a **completeness obligation** (§11.4) and duplicates `drop_stale`'s job. Its
only unique benefit is faster false-positive cleanup, which is not a correctness
property. Add-only is therefore preferred; revisit only if false positives are
measured to linger long enough to matter (in which case tightening `drop_stale`'s
cadence is the better lever than switching to a wipe).
