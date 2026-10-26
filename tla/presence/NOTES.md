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

For a run with liveness properties and more than about 100K states, add
`-lncheck final`. By default TLC checks liveness on the partial state space
every few seconds and again at the end; the option skips the partial passes.

## Assumptions

- One tenant. The tracker is per tenant, heartbeats are per-tenant
  broadcasts routed by Muster, and no state is shared between tenants. A
  second tenant would add states without adding behaviour.
- A node is the authority for the entries its own clients tracked. Nothing it
  receives from a peer can conflict with its own entries, so there is no
  merge, only replace.
- Topics are not modelled. A topic is a projection of an entry's payload,
  and the payload is opaque to replication. Replication, interest and dead
  detection are tenant-level. Grouping entries by topic is an implementation
  detail of the client-facing side.
- The transport is unordered and lossy. Muster over gen_rpc uses a pool of
  connections per node with no ordering guarantee, so two heartbeats from
  one sender can arrive in either order. The model never assumes ordering.
- Every tracker's heartbeat timer runs at the same rate, and delivery delay
  is bounded in heartbeat periods. A silence threshold counted in heartbeats
  means nothing without both. From step 5, time advances in cluster-wide
  ticks and every message carries its age in ticks.
- A tracker's entries do not outlive the tracker. The tracker links to the
  channel that tracked each entry, so a tracker crash takes those channels
  with it and a channel crash is a leave. A tracker restart is therefore a
  crash followed by a join, and the model has no separate restart. See
  step 6.

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

## Step 5: `Presence5.tla`, crash, goodbye and dead detection

What: a node can crash. A tracker that stops gracefully sends a goodbye, an
empty snapshot. Every tracker counts, per peer, how many heartbeat periods
have passed since it last heard from that peer, and purges the peer's
entries once the count reaches a threshold. Time is explicit from this
step: one `Tick` action fires every live timer at once, and every message
carries its age in ticks with a bound on how old it can get.

Properties:

- A stopped tracker's entries are eventually gone from every live replica,
  and stay gone (`DeadStatesArePurged`).
- Under unbounded loss, every link between two live trackers is correct
  infinitely often (`PairRepair`).
- Under bounded loss, the whole cluster is correct infinitely often and
  eventually stays correct (`Convergence`, `Stabilisation`).

Why this step: step 4 ended with survivors holding a departed tracker's
entries. A goodbye covers the graceful case. It does not cover a crash, a
lost goodbye, or a stale snapshot still in flight behind the goodbye, so
silence-based purging is needed as well. Purging makes time part of the
protocol: a threshold counted in heartbeats is only meaningful if the
timers agree and delivery is not arbitrarily slow. This step states both
assumptions and the constraint that follows from them.

Decisions recorded in the module:

- Crash wipes the node's entries, discards messages to it and sends
  nothing. Leave sends an empty snapshot to every interested peer.
- The silence counter is per tracker per peer, reset by any delivery from
  that peer, and saturates at the threshold. Purge requires something to
  purge and is weakly fair.
- A message is delivered or dropped before it is older than `MaxDelay`
  ticks. `Tick` is blocked while any message is at the bound.
- `ASSUME MaxDelay + 1 < SilenceThreshold`. The counter goes up in the tick
  the latest snapshot was sent, so a snapshot arriving `MaxDelay` ticks late
  finds the counter at `MaxDelay + 1`. Below that threshold a late heartbeat
  is indistinguishable from a dead peer.

Finding 1: per-node heartbeat actions make the threshold meaningless. With
each node's heartbeat as its own action, nothing relates one node's timer
to another's. At threshold 1 TLC found a loop with no loss at all in which
one node heartbeats repeatedly, its counter for the peer reaches the
threshold, and it purges a live peer that simply has not had its turn yet.
At threshold 2 the same thing needs one drop. No threshold fixes it. The design
assumes timers run at the same rate; the model has to say so. Fixed by
replacing per-node heartbeats with one cluster-wide `Tick`, and by giving
messages an age so that "late" is bounded in the same unit.

Finding 2: "eventually always converged" is false under unbounded loss for
any threshold. Lose a peer's heartbeats threshold times in a row and it is
purged; the next delivery restores it; loss can do this forever. The honest
property under unbounded loss is repair, `[]<>`, not stabilisation, `<>[]`.
Cluster-wide repair is false too: TLC found a 25-state loop where loss
alternates between the two directions, so whenever one link is restored the
other has just been purged. Each link repairs, but the cluster is never
consistent as a whole at any instant. Per-link repair holds. Cluster-wide
repair and stabilisation hold once loss is bounded (`BoundedLoss`,
`MaxDrops`), which models a network that eventually stops losing.

Finding 3: a false positive, purging a live peer, is reachable at any finite
threshold. The probe `FalsePositivesUnreachable` says a non-empty, correct
replica is never at the threshold. It fails through two consecutive drops.
The threshold is a tuning parameter, not a correctness one: it trades
detection delay against false positives, and the model cannot say how often
a real network loses two in a row. The probe excludes a replica that no
longer matches its source, because that is a crashed-and-rejoined peer's
leftovers, which purging is right to remove.

Finding 4: fairness per message was the entire liveness cost. Strong
fairness quantified over every possible message put the temporal phase at
33s for 31K states, and the number of conjuncts grows with the message
domain. Replaced by strong fairness per link, on "some message in flight
from s to d is delivered". That is sound because the age bound stops `Tick`
while an old message is in flight, so no message can be starved by others
on its link. It is a weaker assumption about the network, and the temporal
phase dropped to under a second. A scratch run confirmed TLC still finds
the alternating-loss loop under the new fairness.

Runs (2026-10-21), all at `MaxJoins = 2`, `SilenceThreshold = 2`,
`MaxDelay = 0`:

| Config | Nodes | Refs | Loss | Distinct states | Depth | Time | Result |
|---|---|---|---|---|---|---|---|
| `Presence5.cfg` | 2 | 2 | unbounded | 31,133 | 20 | 1s | holds |
| 3 refs (ad hoc) | 2 | 3 | unbounded | 239,461 | 22 | 24s | holds |
| `Presence5_stable.cfg` | 2 | 2 | 2 drops | 64,365 | 20 | 2s | holds |
| 3 nodes, invariants only (ad hoc) | 3 | 2 | unbounded | >188M | >27 | stopped at 15 min | unknown |

Witnesses:

- `Presence5_w1.cfg`: `FalsePositivesUnreachable` as an invariant. Violated
  in 11 states: both nodes join, one tracks, one tick delivers both
  heartbeats, the next tick's heartbeats are both dropped, and the tick after
  that takes the counter to the threshold with a correct replica in hand.
  10,698 states.
- `Presence5_w2.cfg`: `PurgeEnabled = FALSE`. `DeadStatesArePurged`
  violated in 16 states, ending in stuttering with one node crashed and the
  survivor still holding its entry. Shows the goodbye alone is not enough.
- `Presence5_w3.cfg`: cluster-wide `Convergence` under unbounded loss.
  Violated, 26 states looping back to state 10. The alternating-loss trace
  from finding 2.

Observations:

- A third node multiplies the state space rather than adding to it. The
  3-node run was still generating states at 188 million. Two nodes is
  representative for this protocol because no node forwards another's
  entries, so each link depends only on its two endpoints. Three nodes
  would matter if the design ever added forwarding.
- Three refs at two nodes is cheap enough to use as a confirmation run. It
  becomes the better default once heartbeats carry diffs, since a diff with
  both an add and a remove needs a node holding two entries while a third
  changes.
- `MaxDelay = 1` with threshold 3, where two snapshots from one sender can
  be in flight together, has not been run yet.

## Step 6: tracker restart, no module

What: the tracker process on a node restarts while the node stays up. The
question was whether the entries tracked through it survive the restart.

Decision: they do not. The tracker links to each channel that tracks an
entry, so a tracker crash kills those channels, their clients rejoin and
track again, and peers see the old entries leave and new ones join. A
restart is a crash followed by a join, which step 5 already models and
checks: `PairRepair` holds through Crash then Join at the default
constants, because the first snapshot from the restarted tracker replaces
whatever a peer still held.

Why this way: it is what Phoenix Tracker does, and the new tracker runs side
by side with Phoenix Presence for a while. Two implementations with
different restart semantics would be two sets of client-visible behaviour
to support. The per-tenant tracker still narrows the blast radius of a
restart from every tenant sharing a shard to one tenant on one node.

How Phoenix does it, for reference: the shard calls `Process.link` on the
channel pid when it tracks and traps exits, so a dying channel is a leave.
Channels do not trap exits, so a dying shard takes its channels down. The
shard restarts empty with a new replica version. A remote shard that sees a
heartbeat from the same node with a new version marks the old version
permanently down, reports every entry from it as a leave, and syncs with
the new one. The version is what lets peers drop the old state at once
rather than waiting for silence.

Deferred: monitoring the channels instead of linking, so a tracker restart
leaves them connected. Worth revisiting once Phoenix Tracker is fully
replaced, because channels surviving a tracker restart limits the blast
radius across broadcast and database-changes features too. The cost, from
working it through: the tracker has to rebuild its entries from the
channels before it heartbeats, or peers see every entry leave and come
back; its replicas are empty until the next tick, so its own clients see
every remote entry leave and come back; and the entries' refs have to
survive the restart, which means the channel owns the ref, not the tracker.
Each of those is a mechanism the model would need to add.

Shadow mode needs monitor semantics anyway, without the rebuild. While the
new tracker runs alongside Phoenix Presence and is not the source of truth,
a crash in it must not disconnect channels. The link is created by the
tracker, which holds every channel pid, so the switch lives there and
nowhere else: the tracker always monitors the channel pid and treats
`:DOWN` as the leave, always traps exits, and in link mode also calls
`Process.link` on the same pid. A per-tenant feature flag read once at
tracker start picks the mode. Link rather than a channel-side monitor for
the end state because an exit signal kills a non-trapping channel at once,
while a `:DOWN` message queues behind whatever the channel is doing. In
shadow mode a tracker crash loses this node's entries until each channel
leaves and rejoins, and the shadow comparison diverges for that long; a
telemetry event on tracker crash makes the divergence explainable. The
model is unaffected: in both modes the tracker's entries die with it.

The incarnation id stays in step 8. In snapshot mode the next heartbeat
corrects a peer completely, so nothing distinguishes a restarted sender
from a delayed message except a replica going backwards for one period
when `MaxDelay` is at least 1. That becomes corruption rather than a
transient once heartbeats carry diffs.

## Step 7: `Presence7.tla`, client contract

What: the last hop, from the tracker on a node to a client connected to
that node. The client is sent one full copy of what the node knows, then
only changes: refs that joined and refs that left. It keeps its own copy
and applies each message in turn. The property is that a client that has
received the full copy and has nothing left to process holds exactly what
the node knows, its own entries plus every replica.

The module starts as a copy of step 5 with the tracker lifecycle renamed:
Join is Start, Leave is Stop, `MaxJoins` is `MaxStarts`. Join and leave
are what the client contract calls an entry appearing and disappearing,
and this step adds that contract. Earlier modules keep the old names.

Topics: a client subscribes to one topic per channel and is sent only that
topic's state and diffs. Authorisation for the topic is decided before the
subscription and the tracker never sees it. The model keeps one client per
node receiving the unfiltered stream, because a topic's client is a
projection of it. Filtering a set of refs by topic commutes with union and
difference, so a client receiving the filtered state and filtered diffs
ends with the filtered view exactly when the unfiltered client ends with
the whole view. A ref's topic never changes, since a ref is one track
call. The subscribe-then-read race is per topic in the same way: a change
to the topic in the gap is lost just as it would be for the whole view.

For the implementation this means the tracker fans one tenant stream out
by topic: a diff computed over the tenant's view is split into per-topic
diffs before publishing, and a state read is filtered by topic. Both are
projections of the two things the model has. Putting topics in the module,
a constant function from refs to topics and one client per node and topic,
would check the same argument at a larger state space and find nothing the
argument misses. Revisit only if step 8 makes diffs or checksums per topic.

This is the only step where Phoenix terms map onto the model: the state
message is `presence_state`, a diff is `presence_diff`, a ref is `phx_ref`.
An update with the same key is an untrack and a track, which matches the
SDK: it matches metas by ref, and an update produces a new ref with the old
one as `phx_ref_prev`.

Properties:

- A client that is subscribed, has been sent the state message, and has
  nothing left in its inbox holds exactly the node's view
  (`ClientViewsAreCorrect`). An invariant, since every state has to satisfy
  it, not just eventually.

Decisions recorded in the module:

- One client per node, as a record: subscribed, synced, view, inbox, and a
  subscribe counter for the bound. The inbox is a sequence, not a set,
  because the path from channel to socket to SDK is one ordered stream and
  the contract depends on that order. Heartbeats stay a set.
- Subscribe and Sync are separate actions so the race between them is in
  the model. `SubscribeFirst` picks the order; TRUE is the default.
- Every action that changes a node's view, Track, Untrack, Deliver and
  Purge, queues a diff for the node's client through one helper, which
  sends nothing when no client is subscribed or the view did not change.
  Empty diffs are never sent.
- Consume applies a state message by replacing the view and a diff by
  removing the leaves then adding the joins, as set operations.
- Crash resets the node's client, the link semantics from step 6. Stop
  requires an idle client. Unsubscribe resets everything but the counter.
- The default config checks invariants only, with a state constraint
  bounding each inbox at two messages. The inbox is unbounded on paths where
  the client never consumes, so without the constraint the state space is
  infinite. TLC's liveness results are unreliable under a state constraint,
  so the tracker's liveness properties are checked in a separate config with
  the client switched off (`MaxSubscribes = 0`), where no constraint is
  needed and the state space is exactly step 5's.

Finding 1: the cold-start order is subscribe for changes first, then read
and send the state. The other order loses any change that lands between
the read and the subscription: it is in neither the state message nor a
diff, and the client has no way to know. TLC finds it in 6 states. The
current channel code already subscribes before it reads; the model shows
why that order is the right one and that it is not optional.

Finding 2: with subscribe first, a diff can reach the client before the
state message. The client applies it to an empty view and the state message
then replaces that view, which is correct. The contract point is that the
state message must be applied as a replacement, or a merge equivalent to
one, not as a set of joins. The SDK's state sync does this.

Finding 3: the client multiplies the state space by about 290, from 31,133
states to 8,970,793, because every tracker state is now paired with every
reachable view and inbox. Still 72 seconds at two nodes and two refs. Two
ways to pull it back if step 8 needs the room: symmetry on nodes and refs,
which is unsound for liveness but sound for this invariants-only config,
and an inbox bound of one, which still finds the ordering witness.

By construction, not found by TLC: a track on a node reaches the node's own
clients immediately, before any heartbeat, the local fast path. And every
step 5 transient is client-visible here. A stale snapshot or a purge of a
live peer is a leave followed by a join for an entry that never went
anywhere. Nothing in this step fixes that; it is what snapshot mode under
loss looks like from the outside.

Runs (2026-10-26), all at two nodes, two refs, `MaxStarts = 2`,
`SilenceThreshold = 2`, `MaxDelay = 0`, unbounded loss:

| Config | Client | Distinct states | Depth | Time | Result |
|---|---|---|---|---|---|
| `Presence7.cfg` | on, inbox bounded at 2 | 8,970,793 | 42 | 72s | holds |
| `Presence7_live.cfg` | off | 31,133 | 20 | 1s | holds |

The liveness config's state count matches `Presence5.cfg` exactly, which is
the check that the module edits did not disturb the tracker.

Witnesses:

- `Presence7_w1.cfg`: `SubscribeFirst = FALSE`. `ClientViewsAreCorrect`
  violated in 6 states: Start, Sync of an empty view, Track, Subscribe,
  Consume. The client holds nothing while the node holds one ref.

Observations:

- Keep the two-config split in step 8: the invariant config with the client
  on and the constraint, the liveness config with the client off. The
  client contract is a safety property, so losing liveness in the config
  that checks it costs nothing.
- A liveness property about the client itself, a subscribed client
  eventually catches up, is not checked. It would need weak fairness on
  Consume and a bounded-loss run with a constraint high enough not to cut
  off any real behaviour.
- Not yet run: the no-loss witness pair for the delay constraint, which
  would replace the `ASSUME` with a checked claim, and `MaxDelay = 1`.

## Roadmap

Each step adds one mechanism and the property it is responsible for. The
order is chosen so that each protocol decision is made with a counterexample
in hand.

8. **Diff and version heartbeats.** The heartbeat nondeterministically
   carries full state, a diff with a sequence number, or a version only. Gap
   detection, snapshot request, and an incarnation id so a receiver can tell
   a restarted sender from a delayed message. Checked against the same
   properties as the snapshot model, at three refs.
