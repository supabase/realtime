# Presence TLA+ model notes

A TLA+/TLC model of the replication protocol for the new per-tenant presence
tracker, built incrementally. One module per step, numbered. Each step adds
one mechanism and the property that mechanism is responsible for. Muster and
PubSub are not modelled; from step 3 they are abstracted as a delivery layer
that may drop a message to an interested node.

Each module has a `.cfg` of the same name. Check it with TLC (2.19 at the
time of writing) from this directory:

```
java -cp tla2tools.jar tlc2.TLC -workers auto -config Presence1.cfg Presence1.tla
```

## Assumptions

- One tenant. The tracker is per tenant, heartbeats are per-tenant
  broadcasts routed by Muster, and no state is shared between tenants. A
  second tenant would add states without adding behaviour.
- A node is the authority for the entries its own clients tracked. Nothing it
  receives from a peer can conflict with its own entries, so there is no
  merge, only replace.
- Topics are not modelled until the client contract step. Replication,
  interest and dead detection are tenant-level and do not look at topics.

## Protocol options

The heartbeat is periodic in every option. Step 3 shows why: with lossy
delivery, send-on-change alone does not converge. The options differ in
what a heartbeat carries.

1. **Full state every heartbeat.** Each node sends the entries it owns, every
   period, to every interested node. Receiver replaces its replica. No
   sequence numbers, no gap detection; a lost heartbeat is repaired by the
   next one. Cost scales with steady-state size: bytes are re-sent whether or
   not anything changed.
2. **Version-stamped full state.** Each node keeps a counter that increments
   on every local change. Every heartbeat carries the counter; the entry set
   rides along only when the counter changed since the last send. A receiver
   that sees a version it has not applied, with no state attached, requests
   a snapshot. Steady-state heartbeats are a few bytes. Any change, however
   small, costs a full snapshot. Still replace-only on the receiver.
3. **Diffs.** Heartbeats carry changes since the last heartbeat, with a
   sequence number for gap detection and a checksum or similar to catch a
   bad apply. Recovery from a gap, a restart, or a cold start is a full
   snapshot, so this option contains option 1 as a sub-protocol. Cost scales
   with change rate. Adds per-change bookkeeping on the sender and merge
   logic on the receiver.

Decision: model and implement option 1 first. It is the protocol everything
else recovers through. Add option 2 if measurement shows steady-state bytes
matter. Option 3 only if change rate is the problem.

For the model, option 2 and option 3 share the machinery (a per-sender
version, a request path, a receiver that detects it is behind). When that
step arrives, the heartbeat action should nondeterministically carry full
state, a diff, or a version only. One model then covers every threshold
policy an implementation might choose; the policy stays out of the spec.

## Step 1: `Presence1.tla`, local state only

What: nodes track and untrack presence entries locally. No messages, no
replication. The only property is that an entry belongs to one node at a time.

Why this step first: it fixes the vocabulary every later step builds on.
A presence entry is a ref, created by one `track` call and never reused.
Each node is the authority for its own entries. Keys and payloads are left
out until the client contract (step 7); replication does not depend on them.
Entry uniqueness is set here because later steps rely on it to tell a stale
replica of an entry from a fresh one.

It also settles how behaviours end. The set of refs is finite, so every
behaviour terminates, and the model needs a way to say so that is not a
deadlock. Step 2's convergence property needs that quiescent state to exist.

Runs (2026-10-20):

| Config | Nodes | Refs | Distinct states | Depth | Result |
|---|---|---|---|---|---|
| `Presence1.cfg` | 2 | 2 | 16 | 5 | holds |
| 3x3 (ad hoc) | 3 | 3 | 125 | 7 | holds |

Witness (non-vacuity): `Presence1_w1.cfg` sets `UniqueRefs = FALSE`, which
switches off the guard that stops a ref being tracked twice. `OwnedOnce`
violated in 3 states: `n2` tracks `r1`, then `n1` tracks `r1`. 24 distinct
states. The constant exists only for this; every other config sets it `TRUE`.

Observations:

- Nothing in the spec orders nodes or refs, so a `SYMMETRY` set over both is
  sound for safety checking. Not used: step 2 adds liveness, and TLC's
  liveness checking under symmetry is not sound in general.
- TLC writes a `states/` directory next to the spec. It should be ignored
  (`states/`, `*.st`, `*.fp`, `*.chkpt`).

## Roadmap

Each step adds one mechanism and the property it is responsible for. The
order is chosen so that each protocol decision is made with a counterexample
in hand.

2. **Snapshot heartbeat, perfect delivery.** A replica table per node and a
   message set. A heartbeat carries a node's full local set. A node's view is
   its local set plus every replica. First liveness property: once tracking
   stops, every replica eventually equals its source. Introduces fairness.
3. **Lossy delivery.** A `Drop` action with no fairness. Convergence must still
   hold. Witness: heartbeat on change only, instead of periodic, and
   convergence fails. This is the "keep the heartbeat" decision.
4. **Interest.** A tracker exists on a node only while it has clients.
   Heartbeats reach interested nodes only (the Muster abstraction). Cold start
   on first client, teardown on last. Interest flapping first appears here.
5. **Node crash and dead detection.** Permanent node down, a missed-heartbeat
   counter per peer, a purge past a threshold. Properties: a dead node's
   entries are eventually gone; a live node is never purged while it
   heartbeats. With lossy delivery the second fails for a low threshold.
   Decides which signal declares a peer dead.
6. **Tracker restart.** Process restart on a live node. Decides whether local
   entries survive, whether heartbeats carry an incarnation id, and what a
   receiver does on seeing a new one. Resolves interest flapping.
7. **Client contract.** What a subscribed socket receives: a full state at
   sync, then diffs. Invariant: state plus diffs always equals the node's
   current view. The only step where Phoenix terms appear. Decides cold-start
   ordering and the local fast path.
8. **Diff-mode heartbeats.** Sequence numbers, gap detection, checksum,
   snapshot request. A separate model checked against the same properties as
   the snapshot model.
