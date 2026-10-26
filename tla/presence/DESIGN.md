# Presence replication: design for implementation

This document gives the protocol that the model in this directory
produced. It is written for the person who implements the protocol.
NOTES.md gives the reasons and the model runs. This document gives only
the result.

The terms are the terms of the model. A ref identifies one track call. An
entry is a ref with its payload. A tracker is the process for one tenant on
one node.

## Scope

Each node runs one tracker for each tenant. A tracker is the authority for
the entries that clients on its own node tracked. A tracker holds a replica
of the entries of each other node. A tracker never changes a replica. It
replaces a replica or clears a replica. The protocol has no merge step and
no conflict resolution.

## What the design changes

The current implementation replicates every presence topic to every node.
Each node holds the full state of the cluster. The work on a node grows
with the presence of the whole cluster, not with the clients on the node.

The design makes three changes:

- The replication unit is the tenant. The state on a node is bounded by
  the tenants that have clients on the node.
- A heartbeat goes only to the nodes that hold the tenant. The routing uses
  the interest registry of Muster. The traffic into a node grows with the
  interest of that node.
- A tracker replaces a replica. It does not merge. The cost of a received
  message is proportional to the size of the replica. There are no vector
  clocks and no delta history.

Two further effects follow from the tenant unit:

- A tracker crash affects one tenant on one node. In the current
  implementation a shard crash affects all tenants in the shard on every
  node.
- A new node starts with no state. It receives the state of a tenant when
  the first client of that tenant connects.

The protocol between two trackers is not new. Each rule in this document
has a counterpart in `Phoenix.Tracker.Shard`. The model shows which of
these rules are necessary. The latency from a track call to a remote
subscriber stays one heartbeat period. The client contract does not
change.

The model checks the protocol between two trackers. It does not check the
three changes above. The tracker lifecycle per tenant, the Muster interest
path and the number of messages between two nodes need load tests.

## Tracker state

Each tracker holds these values:

- `local`: the entries that clients on this node tracked.
- `version`: a counter. The tracker increments it on each local track and
  on each local untrack. The counter starts at 0 when the tracker starts.
- `incarnation`: a timestamp. The tracker takes it when the tracker starts.
  The protocol compares incarnations only for order. The tracker does not
  persist the incarnation across restarts.
- `sent`: the `local` set and the `version` at the time of the last
  heartbeat. The next diff starts from this state.

Each tracker holds these values for each peer node:

- `replica`: the entries that this tracker believes the peer holds.
- `mark`: the stamp of the message that gave the current replica.
- `silent`: the number of heartbeat periods since the last message from the
  peer.
- `behind`: a flag. The tracker sets it when a diff arrives that it cannot
  apply.

A stamp is a pair of an incarnation and a version. Stamp A is newer than
stamp B in two cases. Case one: the incarnation of A is greater than the
incarnation of B. Case two: the incarnations are equal and the version of
A is greater than the version of B.

## Messages

The protocol has three message kinds. The snapshot and the diff carry the
stamp of the sender. The request carries no stamp.

- Snapshot: the stamp and the full `local` set of the sender.
- Diff: the stamp, a `from` version, a `joins` set and a `leaves` set. The
  diff gives the change from the `sent` state of the sender to its current
  state. The `from` version is `sent.version`.
- Request: no payload. The request asks the receiver for a snapshot.

A diff can have a `from` version that is equal to the version in its stamp
and two empty sets. This diff means "no change since this version". Send
this diff when there is no change. The protocol has no separate message
kind for this case.

## Send messages

In each heartbeat period, each tracker sends one message to each peer that
is running. The message is a snapshot or a diff. The tracker chooses the
kind. The model shows that each choice is correct. After the tracker sends
the message, it sets `sent` to the current `local` set and `version`.

In the same period, the tracker sends a request to each peer that has the
`behind` flag set. The tracker sends the request again in each period until
the flag is clear. A lost request needs no extra state. The next period
sends it again.

When a tracker receives a request, it sends a snapshot to the requester
immediately. It sends the snapshot to the requester only. It does not
change `sent`, because a reply is not a heartbeat. If the requester is not
running, the tracker does not reply.

When a tracker stops, it sends a snapshot with an empty set to each peer.
This snapshot is the goodbye. When a tracker crashes, it sends nothing.

Do not send a message to a peer that is known to be down.

## Receive messages

When a message arrives from a peer, set `silent` for that peer to 0. Then
apply one of these rules, by message kind:

- The message is a snapshot and its stamp is newer than `mark`. Replace
  `replica` with the set in the message. Set `mark` to the stamp. Clear
  `behind`.
- The message is a diff, its incarnation is equal to the incarnation of
  `mark`, and its `from` version is equal to the version of `mark`. Remove
  the `leaves` set from `replica`. Add the `joins` set to `replica`. Set
  `mark` to the stamp.
- The message is a diff, its stamp is newer than `mark`, and the previous
  rule does not apply. Set `behind`. Change nothing else.
- No rule above applies. The message is stale. Change nothing.

A stale message is normal. It is not an error. The transport does not keep
messages in order.

## Detect a dead peer

When `silent` for a peer reaches the threshold, purge the peer. Clear
`replica`. Set `mark` to the initial value. Clear `behind`.

The purge must reset `mark`. If `mark` keeps its value, the next heartbeat
from a live peer with no change is stale, and the replica never returns.

The threshold must obey this rule: threshold > max_delay + 1. The value
`max_delay` is the longest delivery delay, measured in heartbeat periods.
Delivery includes the time a message waits in the mailbox of the receiver.
If the threshold is too small, a late heartbeat from a live peer and a dead
peer look the same. Check this rule when the tracker starts. If the rule
fails, do not start.

The threshold is a tuning parameter. It does not change correctness. When
the network loses messages, a tracker can purge a live peer. The next
heartbeat that arrives restores the peer. A client sees a leave and then a
join for a live entry.

## Lifecycle

When a tracker starts, `local` is empty, `version` is 0, `incarnation` is
new, and each peer record has its initial value. A restart gives a new
incarnation. The peers replace the old entries when they receive the first
heartbeat of the new incarnation.

The tracker links to each channel that tracks an entry. The tracker traps
exits. When a channel exits, the tracker untracks its entry. When the
tracker crashes, the link stops its channels. An entry never outlives its
tracker.

In shadow mode, the tracker monitors the channel and does not link to it. A
feature flag for the tenant selects the mode. The tracker reads the flag
when it starts. The tracker always monitors the channel to detect the
untrack. The flag only adds the link. In monitor mode, a tracker crash
loses the entries of the node until each channel connects again. Send a
telemetry event when a tracker crashes, so that the difference has a known
cause.

## Client contract

The view of a node is `local` plus each `replica`. A client on a channel
sees the view for the topic of the channel only. Authorisation for the
topic occurs before the subscription. The tracker does not see it.

- Subscribe the channel to the change stream for its topic first. Then read
  the state and send it to the client. If you do these steps in the other
  order, a change that occurs between them is lost.
- Send a diff to the subscribers only when the view changes. Do not send an
  empty diff to a client.
- The client must replace its full view with the state message. A merge
  that gives the same result is also correct. A diff can arrive before the
  state message. The replacement makes this correct.
- The client must apply a diff as set operations on refs. Remove the leaves
  first. Then add the joins.
- Compute the diff over the view of the tenant. Split the diff by topic.
  Publish each part on its topic. The state for a topic is the view
  filtered by that topic.

At this boundary, the state message is `presence_state`, a diff is
`presence_diff`, and a ref is `phx_ref`.

## Assumptions

The design depends on these conditions:

- One tracker serves one tenant. Trackers share no state.
- The transport does not keep messages in order. The transport can lose
  messages. The delivery delay has an upper limit, measured in heartbeat
  periods. Each tracker runs its heartbeat timer at the same rate.
- Message loss does not depend on the message kind. If a link always
  delivers diffs and always loses snapshots, the link never becomes correct
  again, and the protocol cannot detect this. See the first item in the
  next section.
- An entry does not outlive the tracker that holds it.

## Cautions

1. Make the request and the reply reliable. The snapshot reply is the
   largest message in the protocol. Recovery is not possible without it.
   Under load, a large message can be lost more often than a small message.
   This breaks the assumption on message loss. Use a call with an
   acknowledgement for the request and the reply. Do not use a cast.
2. Incarnations must have an order. A different value is not sufficient.
   A stop, a start and a stop in one period put two goodbyes from two
   incarnations in flight at the same time. Without an order, the receiver
   can accept the old goodbye after the new one. A pid identifies an
   incarnation but does not give an order. Put the start timestamp in the
   stamp. Use the pid for the link only.
3. Diffs alone do not restore a link. A receiver that misses one message
   stays behind until it sends a request. The request path is mandatory.
   This is true also on a network that loses messages rarely.
4. The purge must reset `mark`. See the section on dead peers.
5. Do not reply to a requester that is down. A request can be in flight
   when its sender crashes. The request still arrives. A reply to it goes
   to a node that cannot receive it.
6. A requester can become behind two times. The reply carries the state at
   the time of the reply. The next diff starts from `sent`. If a change
   occurred between the two, the requester sees one more gap and sends one
   more request. The number of requests has a limit, and the result is
   correct. If the extra round is a problem, keep a base version for each
   peer and advance it on each reply.
7. A stale snapshot that arrives after a goodbye has no effect. Its version
   is older, and the receiver ignores it. No special rule is necessary.
8. After a crash and a restart, the peers remove the old entries when they
   receive one heartbeat. This is because the first message of the new
   incarnation replaces the old entries. If the implementation used the pid
   as the key of a replica, the old entries would stay until the silence
   threshold.
9. Send a heartbeat in each period also when there is no change. Send the
   empty diff. The heartbeat is what keeps `silent` at 0 on the peers.
10. The number of heartbeats grows with the number of tenants. The current
    implementation sends a fixed number of shard heartbeats from each node
    in each period. This design sends one heartbeat for each tenant to each
    interested peer. A node with many tenants sends many small messages.
    Put the heartbeats for all tenants between two nodes into one message.
    The content for each tenant stays independent.
11. A new tracker has no replicas. The first message from a peer can be a
    diff. The tracker is then behind, and the request goes out in the next
    period. A client that joins in this time gets an empty state and then
    diffs. To shorten this, set `behind` for each peer when the tracker
    starts. The tracker then sends requests in its first period. The model
    did not check this start state. It is the state the model reaches after
    one diff arrives at a new tracker.

## Decisions for the implementation

The model does not decide these items:

- When to send a snapshot and when to send a diff. Each choice is correct.
  The cost is different.
- How to put the heartbeats of many tenants into one message between two
  nodes. See caution 10. The protocol does not change.
- How to split messages by topic and how to handle payloads.
- The heartbeat period and the silence threshold. The threshold rule
  applies.

## Results of the model

The model checked these properties with two nodes, two refs and two
tracker starts, with the client on and with the client off:

- One node owns each ref. A replica holds only refs that exist. A dead
  tracker has no state and receives no messages. A receiver with a mark
  equal to the current stamp of the sender holds exactly the entries of the
  sender. A client with an empty inbox holds exactly the view of its node.
- With unlimited message loss, each link between two live trackers becomes
  correct again an unlimited number of times. The entries of a dead tracker
  are removed from each live tracker, and they stay removed.
- With limited message loss, all replicas become correct and stay correct.

The model proved the liveness properties with two nodes only. Two nodes are
sufficient because a node does not forward the entries of another node.
Each link depends on its two ends only. The model could not check three
nodes in an acceptable time.
