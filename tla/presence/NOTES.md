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

## Step 2: `Presence2.tla`, snapshot heartbeat over a perfect network

What: each node periodically sends the entries it owns to every other node,
and a receiver replaces its copy of the sender's entries with what arrived.
No loss. The new property is convergence: once tracking stops, every copy
eventually matches its source and stays matched.

Why this step: it is the first liveness property, and liveness needs
fairness. Safety says what may never happen; convergence says what must
eventually happen, and nothing in a bare transition system forces anything
to happen. This step settles what the model assumes the environment
guarantees (nodes keep heartbeating; a perfect network delivers every
message) and what it does not (nobody forces a track or untrack).

Messages are an unordered set. Delivery order is arbitrary, duplicates
collapse. This over-approximates any real transport, so a property that
holds here holds under stricter ordering too.

Finding: fairness on "some message is eventually delivered" is not enough.
With `WF_vars(\E msg \in msgs : Deliver(msg))`, TLC found a loop where one
node re-sends the same heartbeat forever and the receiver keeps delivering
it, while a different message to the other node is never delivered and a
stale copy persists. The fairness condition is satisfied because deliveries
happen infinitely often. Fixed by quantifying fairness over every possible
message, `\A msg \in Messages : WF_vars(Deliver(msg))`, which is the honest
statement of "every message sent is eventually delivered" on a perfect
network. Step 3 shows it is still too weak once loss exists; see finding 1
there.

Runs (2026-10-21):

| Config | Nodes | Refs | Distinct states | Depth | Time | Result |
|---|---|---|---|---|---|---|
| `Presence2.cfg` | 2 | 2 | 1,440 | 13 | <1s | holds |
| 3 nodes (ad hoc) | 3 | 2 | 778,528 | 21 | 26s | holds |

Witnesses:

- `Presence2_w1.cfg`: the spec without fairness. `Convergence` violated;
  the trace ends in a stuttering state with a heartbeat in flight that is
  never delivered.
- `Presence2_w2.cfg`: `ReplicasEmpty` violated at the first delivery.
  Replicas do fill.

Observations:

- Three nodes costs a few hundred thousand states with liveness on, and
  symmetry reduction is unsound for liveness checking. Iterate at two nodes;
  confirm at three.
- A stale snapshot delivered after a fresher one makes a copy go backwards
  for a moment. `<>[]` tolerates this. Whether the transient is acceptable
  is a client-contract question (step 7).

## Step 3: `Presence3.tla`, lossy delivery

What: any in-flight heartbeat may be dropped. Nothing else changes. The
property is the same convergence as step 2, now required to hold despite
loss.

Why this step: it pins down what the model assumes about the transport and
why the heartbeat has to be periodic. Both are decisions the design had
already made; this step turns them into checked claims. Muster and PubSub
are not modelled. Their contract, as the model now states it, is: a message
may be lost, and a message that keeps being sent is eventually delivered.
Nothing about ordering or at-most-once.

Finding 1: weak fairness on delivery is not enough once loss exists. With
`WF_vars(Deliver(msg))`, TLC found a loop where every heartbeat in one
direction is dropped and the stale replica never repairs. Weak fairness
only forces an action that is enabled continuously; a dropped message is
enabled only in the moments between send and drop. The behaviour it
permits is a permanent one-way partition, which is not "loss". Fixed with
strong fairness, `SF_vars(Deliver(msg))`: an action enabled infinitely
often must eventually occur. Heartbeat keeps weak fairness, since nothing
ever disables it. Strong fairness is much slower to check: the temporal
phase went from under a second to over a minute at the same constants.

Finding 2: send-on-change does not converge. The `PeriodicHeartbeat`
witness switch, with a per-node dirty flag, makes a node heartbeat only
after a local change. One dropped heartbeat then leaves a replica stale
forever, because the flag is already clear and nothing sends again. This
is the "keep the heartbeat" decision as a six-step counterexample. The dirty
flag is also the seed of protocol option 2: a version counter is a dirty
flag that remembers how many times it was set.

Runs (2026-10-21):

| Config | Nodes | Refs | Distinct states | Depth | Time | Result |
|---|---|---|---|---|---|---|
| `Presence3.cfg` | 2 | 2 | 2,908 | 15 | 71s | holds |

Witnesses:

- `Presence3_w1.cfg`: `PeriodicHeartbeat = FALSE`. `Convergence` violated;
  a change triggers one heartbeat, it is dropped, then stuttering. 714
  states. Deadlock checking is off in this config: with send-on-change a
  quiescent state has no enabled action, which is expected and not the
  failure the witness is about.

Observations:

- Loss adds no states, only transitions. Distinct states rose from step 2
  because of the dirty flag, not because of `Drop`.
- Quantifying `Deliver` and `Drop` over the constant set `Messages` rather
  than the variable `msgs` lets TLC name those steps in traces. Quantifiers
  over a variable show up as anonymous `Next` steps.
- In a multi-variable quantifier the bound sets are simultaneous, so
  `\A n \in Nodes, m \in Peers(n)` is an error. Nest the quantifiers when
  one domain depends on another.

## Step 4: `Presence4.tla`, interest

What: a tracker exists on a node only while that node has clients for the
tenant. A node joins (tracker starts, knowing nothing) and leaves (tracker
stops, once its own entries are gone). Heartbeats go only to nodes with a
tracker. Convergence is required only between live trackers.

Why this step: it is the Muster abstraction. A broadcast reaches the
interested set and nothing else; the model does not care how. It is also
where cold start and teardown first exist, so it is the first step that can
show interest flapping: a node leaving and coming back.

Decisions recorded in the module:

- Interest is its own state, not derived from tracked entries. A node can
  have clients that track nothing.
- A joining tracker starts with empty replicas. Nothing is pre-seeded; the
  next round of heartbeats fills it.
- Leaving requires the node's own entries to be gone. The last client's
  entries are untracked when its channel dies, which is a sequence of
  untracks the model already has.
- In-flight messages *to* a departing node are discarded (a mailbox dies
  with its process). In-flight messages *from* it are not: a heartbeat
  already sent survives its sender stopping.
- A heartbeat goes to the nodes interested at send time. A node that joined
  after the send gets the next one.
- Join and leave are bounded by a per-node counter. Tracking is already
  bounded by the finite set of refs; without a bound on interest churn a
  node can flap forever and "eventually always converged" has no quiescent
  state to settle into. That is a counterexample about the environment, not
  the protocol.

Finding: a live tracker can hold entries for a tracker that has stopped,
and nothing in the design so far removes them. The trace needs no loss: a
node tracks, heartbeats, untracks and leaves; its last snapshot is still in
flight and lands on a peer after it has gone. The correction was never sent,
because nothing forces a heartbeat between an untrack and a leave. A
goodbye message on leave would cover that case but not the one where the
goodbye is dropped, or where a stale snapshot from the departed node is
still in flight behind it. Silence-based purging is step 5. Most likely both
are needed. The probe is kept as `LiveTrackersDontCarryDeadTrackersState`,
expected to fail until step 5.

Pruning done when copying step 3 to step 4: the witness switches
(`UniqueRefs`, `PeriodicHeartbeat`, the dirty flag) were not carried
forward, and self-addressed messages were excluded from `Messages`. Each
possible message is a strong-fairness conjunct, and halving them took the
step 3 temporal phase from 71s to under a second on the same model.
Modules carry mechanisms forward, not witness switches.

Runs (2026-10-21):

| Config | Nodes | Refs | MaxJoins | Distinct states | Depth | Time | Result |
|---|---|---|---|---|---|---|---|
| `Presence4.cfg` | 2 | 2 | 2 | 6,661 | 19 | 1s | holds |

Witnesses:

- `Presence4_w1.cfg`: `LiveTrackersDontCarryDeadTrackersState` as an
  invariant. Violated in 8 states, trace as described above. 534 states.

Observations:

- Deadlock checking is off in both configs. Once every node has used its
  joins and left, no action is enabled. That is the bounded environment
  running out, not a protocol deadlock.
- Convergence between live trackers holds through cold start and through
  leave-and-rejoin at `MaxJoins = 2`, so interest flapping is not itself a
  problem for snapshot replication. The stale-entry gap is about what the
  survivors hold, not about the returning node.

## Roadmap

Each step adds one mechanism and the property it is responsible for. The
order is chosen so that each protocol decision is made with a counterexample
in hand.

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
