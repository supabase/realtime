# The Rollcall protocol model

This directory holds the TLA+ model of the replication protocol. The model
was built in steps. Each step adds one mechanism and the property that the
mechanism is responsible for. Each step is one module. The last module,
`Presence8.tla`, is the full protocol. `../DESIGN.md` gives the result.
`NOTES.md` gives the reasons, the findings and the run results for each
step.

The modules keep the name `Presence` from the time before the library had a
name. A TLA+ module name must match its file name, so the names stay.

## Run a model

Run TLC through the `tlc` task from any directory under `rollcall`:

```
mise run tlc -- -config Presence8_live.cfg Presence8.tla
```

The task runs in this directory and uses all cores. For a run with liveness
properties and more than about 100K states, add `-lncheck final`. TLC then
checks liveness once at the end instead of every few seconds:

```
mise run tlc -- -lncheck final -config Presence8_live.cfg Presence8.tla
```

TLC writes its working files to `states/`. Git ignores that directory.

When a run finds a violation, TLC prints the trace. A run with several
workers can print a longer trace than the shortest one. The header of each
witness config gives the shortest trace.

## Config kinds

Each module has configs of up to four kinds. The name gives the kind.

- `PresenceN.cfg`: the default run. It checks every invariant. Up to step 5
  it also checks the liveness properties.
- `PresenceN_live.cfg`: the liveness run, from step 7. The client is off, so
  no state constraint is needed. TLC gives unreliable liveness results under
  a state constraint.
- `PresenceN_stable.cfg`: bounded loss. The network drops at most `MaxDrops`
  messages, then it is perfect. The properties that need a network that
  stops losing are checked here.
- `PresenceN_wM.cfg`: a witness. See the section below. The expected result
  is a violation.

Every config header gives the expected result.

## The steps

| Step | Module | Adds | Property |
|---|---|---|---|
| 1 | `Presence1.tla` | Local track and untrack. No messages. | One node owns each ref. |
| 2 | `Presence2.tla` | Snapshot heartbeats over a perfect network. | Replicas converge once tracking stops. |
| 3 | `Presence3.tla` | Message loss. | Convergence holds under loss. |
| 4 | `Presence4.tla` | Interest. A tracker exists only while the node has clients. Heartbeats go to trackers only. | Convergence between live trackers. |
| 5 | `Presence5.tla` | Crash, goodbye, silence purge, explicit time. | Dead state is purged. Each link repairs under unbounded loss. The cluster stabilises under bounded loss. |
| 6 | none | Tracker restart. A restart is a crash and a start. No new mechanism. See `NOTES.md`. | |
| 7 | `Presence7.tla` | The client contract. State message, then diffs. | A synced client with an empty inbox holds the view of its node. |
| 8 | `Presence8.tla` | Diff heartbeats, stamps, marks, the behind flag, request and reply. | A receiver with a current mark holds the entries of the sender. All step 5 properties hold. |

Steps 1 to 5 are the snapshot protocol. Step 7 adds the client. Step 8 is
the full protocol. Earlier modules use the names Join and Leave for the
tracker lifecycle. From step 7 the names are Start and Stop.

## Run times

Measured on a laptop with two nodes and two refs. The witness runs take
seconds and are not listed.

| Config | States | Time | Notes |
|---|---|---|---|
| `Presence1.cfg` | 16 | under 1 s | |
| `Presence2.cfg` | 1,440 | under 1 s | |
| `Presence3.cfg` | 2,908 | 71 s | Strong fairness per message. The liveness check is the cost. |
| `Presence4.cfg` | 6,661 | 1 s | |
| `Presence5.cfg` | 31,133 | 1 s | |
| `Presence5_stable.cfg` | 64,365 | 2 s | |
| `Presence7.cfg` | 8,970,793 | 72 s | Invariants only. |
| `Presence7_live.cfg` | 31,133 | 1 s | The same count as `Presence5.cfg`. |
| `Presence8.cfg` | 288,928,270 | 53 min | Invariants only, with symmetry. Run it at the end of a change, not after each edit. |
| `Presence8_live.cfg` | 572,160 | 15 min | Use `-lncheck final`. |
| `Presence8_stable.cfg` | 490,576 | 10 min | Use `-lncheck final`. |

`Presence8_live.cfg` runs at `MaxStarts = 1`. At `MaxStarts = 2` the two
properties take 34 and 65 minutes when checked one at a time. Both hold.
The per-edit check for step 8 is the live config. The default config is the
end-of-step check.

Three nodes are not practical. Step 2 at three nodes is 778,528 states and
26 seconds. Step 5 at three nodes passed 188 million states and was stopped.
Two nodes are sufficient for this protocol. No node forwards the entries of
another node, so each link depends on its two ends only.

## Witnesses

A witness is a config that makes a property fail on purpose. It switches
off one mechanism, or it asserts the opposite of a known fact. The expected
result is a violation. The trace is the point.

A witness has three uses:

- It shows that a property is not vacuous. A property that holds because
  no state can reach it is worthless. The witness shows that the model can
  reach a state where the property fails.
- It shows that a mechanism is necessary. Switch the mechanism off and the
  property fails. The trace shows what goes wrong without it. This is the
  evidence behind each rule in `../DESIGN.md`.
- It records a finding. A counterexample that TLC found once is kept as a
  config so that anyone can see it again.

A witness that passes is a bug. Either the mechanism is not necessary, or a
change to the model removed the behaviour. Run the witnesses after each
change to a module.

Some witnesses are probes. A probe is a candidate invariant that is known to
be false. It documents a limit of the protocol. `FalsePositivesUnreachable`
in step 5 is an example: a live peer can be purged at any finite threshold.

The witness switches are constants in the modules, such as `UniqueRefs`,
`PeriodicHeartbeat`, `PurgeEnabled`, `SubscribeFirst` and `RequestsEnabled`.
Every config other than the witness sets them to the value the protocol
uses. The switches are not carried forward to later modules unless a later
witness needs them.

| Config | Switches off or asserts | Fails | Shows |
|---|---|---|---|
| `Presence1_w1.cfg` | Ref uniqueness | `OwnedOnce` | Two nodes can track one ref. |
| `Presence2_w1.cfg` | Fairness | `Convergence` | Without fairness a heartbeat stays in flight for ever. |
| `Presence2_w2.cfg` | Asserts replicas stay empty | `ReplicasEmpty` | Replicas do fill. Non-vacuity. |
| `Presence3_w1.cfg` | The periodic heartbeat | `Convergence` | Send-on-change does not survive one lost message. |
| `Presence4_w1.cfg` | Asserts live trackers hold no dead state | `LiveTrackersDontCarryDeadTrackersState` | The gap that step 5 closes. |
| `Presence5_w1.cfg` | Asserts a live peer is never purged | `FalsePositivesUnreachable` | The threshold is a tuning parameter. |
| `Presence5_w2.cfg` | Purge | `DeadStatesArePurged` | The goodbye alone is not enough. |
| `Presence5_w3.cfg` | Asserts cluster-wide repair under unbounded loss | `Convergence` | Only per-link repair holds under unbounded loss. |
| `Presence7_w1.cfg` | Subscribe before read | `ClientViewsAreCorrect` | The subscribe-then-read order is mandatory. |
| `Presence8_w1.cfg` | Subscribe before read | `ClientViewsAreCorrect` | The step 7 witness, unchanged at step 8. |
| `Presence8_w2.cfg` | Asserts no in-flight message is stale | `NoStaleInFlight` | Messages overtake each other. The stamp check is mandatory. |
| `Presence8_w3.cfg` | Requests | `PairRepair` | Diffs alone cannot repair a link. |
| `Presence8_w4.cfg` | Requests, under bounded loss | `Stabilisation` | The request path is necessary even when the network stops losing. |

`Presence8_w2.cfg` fails by two routes. At `MaxDelay = 1` two snapshots
from one incarnation overtake each other. At `MaxDelay = 0` with threshold 2
the route is a restart: Stop, Start, Stop puts goodbyes from two
incarnations in flight together. Edit the two constants to see the second
trace.

## Read next

- `NOTES.md`: the assumptions, the decisions in each module, every finding
  with its trace, and the run tables.
- `../DESIGN.md`: the protocol as rules for the implementation.
