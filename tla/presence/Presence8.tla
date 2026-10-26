---------- MODULE Presence8 -------------
EXTENDS Integers, Sequences, FiniteSets

(***************************************************************************)
(* This is the eighth step of modelling presence: diff based replication   *)
(* protocol.                                                               *)
(*                                                                         *)
(* It starts as a copy of step 7, with the following changes:              *)
(* 1. Refactored tracker state to be a record instead of a number of       *)
(* global variables.                                                       *)
(***************************************************************************)

CONSTANTS
  Nodes,  
  (***************************************************************************)
  (* Refs are the equivalent of a phx_ref, every track call generates a      *)
  (* unique one                                                              *)
  (***************************************************************************)
  Refs,
  (***************************************************************************)
  (* Bound on how many times a tracker can start on a node                   *)
  (***************************************************************************)
  MaxStarts,
  (***************************************************************************)
  (* Bound on how many times a client can subscribe to a tracker.            *)
  (***************************************************************************)
  MaxSubscribes,
  (***************************************************************************)
  (* How much time has passed before we assume a node is dead, if we haven't *)
  (* heard from it. This is measured in "heartbeats" since we have no        *)
  (* concept of time in TLA+                                                 *)
  (***************************************************************************)
  SilenceThreshold,
  (***************************************************************************)
  (* The most ticks a message can stay in flight. 0 means a message is       *)
  (* delivered or lost within the period it was sent in; 1 allows it to     *)
  (* arrive a period late, which is when two snapshots from one sender can  *)
  (* be in flight together and arrive out of order.                         *)
  (***************************************************************************)
  MaxDelay,
  (***************************************************************************)
  (* A probe that allows us to check how the system behaves if purging is    *)
  (* disabled. This should fail the checker when false due to crashed node   *)
  (* state not being removed.                                                *)
  (***************************************************************************)
  PurgeEnabled,
  (***************************************************************************)
  (* Witness switch for the stabilisation property. When TRUE, Drop is      *)
  (* limited to MaxDrops over the whole behaviour, modelling a network that  *)
  (* eventually stops losing messages. The default model leaves it FALSE:   *)
  (* loss is unbounded, and the protocol is only required to keep repairing. *)
  (***************************************************************************)
  BoundedLoss,
  (***************************************************************************)
  (* Witness switch that allows us to test what happens when a client        *)
  (* receives state before subscribing. By default we subscribe then receive *)
  (* state, the reverse should fail due to the gap between receiving state   *)
  (* and subscribing for updates.                                            *)
  (***************************************************************************)
  SubscribeFirst,
  MaxDrops

VARIABLES 
  (***************************************************************************)
  (* A function that maps nodes to Tracker records.                          *)
  (*                                                                         *)
  (* Each node has one tracker (because we're modelling a single tenant),    *)
  (* and the tracker record contains all the state for that tracker on the   *)
  (* node.                                                                   *)
  (***************************************************************************)
  trackers,
  (***************************************************************************)
  (* Every ref we've ever tracked                                            *)
  (***************************************************************************)
  used,
  (***************************************************************************)
  (* The set of messages that have been sent between nodes. This is modeled  *)
  (* a set to capture the fact that out of order delivery is possible.       *)
  (***************************************************************************)
  msgs,
  (***************************************************************************)
  (* The client state on each node. A function mapping Node to Client        *)
  (* record.                                                                 *)
  (***************************************************************************)
  clients,
  (***************************************************************************)
  (* Messages dropped so far; only counted when BoundedLoss is TRUE          *)
  (***************************************************************************)
  drops

ASSUME MaxStarts \in Nat
ASSUME MaxSubscribes \in Nat
ASSUME SilenceThreshold \in Nat \ {0}
ASSUME MaxDelay \in Nat
ASSUME PurgeEnabled \in BOOLEAN
ASSUME BoundedLoss \in BOOLEAN
ASSUME SubscribeFirst \in BOOLEAN
ASSUME MaxDrops \in Nat

(***************************************************************************)
(* MaxDelay is a promise about the transport, in heartbeat periods: a      *)
(* message is delivered or lost within MaxDelay ticks of being sent. The   *)
(* model enforces it by not letting Tick fire while a message that old is  *)
(* still in flight, so time cannot move on until it is settled.            *)
(*                                                                         *)
(* SilenceThreshold is the receiver's rule for declaring a peer dead: it   *)
(* has not heard from the peer for that many ticks.                        *)
(*                                                                         *)
(* The two have to agree. The counter goes up in the tick the snapshot was *)
(* sent, and up to MaxDelay more times before the snapshot can land, so a  *)
(* heartbeat from a healthy peer can arrive with the counter at            *)
(* MaxDelay + 1. If the threshold is not above that, a merely late         *)
(* heartbeat is indistinguishable from a dead peer and a perfect network   *)
(* produces spurious leaves. This is a constraint on the implementation's  *)
(* timer settings, not something the protocol can get right on its own.    *)
(***************************************************************************)
ASSUME MaxDelay + 1 < SilenceThreshold

(***************************************************************************)
(* Version can never exceed twice the cardinality of Refs, since each ref  *)
(* can only be tracked and untracked once each.                            *)
(***************************************************************************)
MaxVersions == Cardinality(Refs) * 2

(***************************************************************************)
(* A tuple of all the state vars.                                          *)
(***************************************************************************)
vars == <<trackers, used, msgs, drops, clients>>

(***************************************************************************)
(* The incarnation and version of a tracker.                               *)
(*                                                                         *)
(* Combined, these tell us whether a new message matches the state this    *)
(* tracker holds for a replica.                                            *)
(***************************************************************************)
Stamps ==
  [
    incarnation: 0..MaxStarts,
    version: 0..MaxVersions
  ]

Peer ==
  [
  (***************************************************************************)
  (* This stores the refs that the node knows the peer node holds.           *)
  (***************************************************************************)
    replica: SUBSET Refs,
  (***************************************************************************)
  (* This stores the beats that have passed since a node has heard from each *)
  (* other node                                                              *)
  (***************************************************************************)
    silent_beats: 0..SilenceThreshold,
  (***************************************************************************)
  (* Captures the current version and incarnation this replica holds of the  *)
  (* peer's state.                                                           *)
  (***************************************************************************)
    mark: Stamps
  ]

Trackers ==
  [
  (***************************************************************************)
  (* The refs the tracker holds locally                                      *)
  (***************************************************************************)
    local: SUBSET Refs,
  (***************************************************************************)
  (* Counts local changes since the tracker started. Used so a receiver of a *)
  (* replication message can tell if a snapshot is newer than what it holds  *)
  (* or whether a diff applies to what it holds. This is reset to 0 whenever *)
  (* a tracker restarts                                                      *)
  (***************************************************************************)
    version: 0..MaxVersions,
  (***************************************************************************)
  (* Whether the tracker is running on the node. FALSE after Stop or Crash.  *)
  (***************************************************************************)
    running: BOOLEAN,
  (***************************************************************************)
  (* How many times the tracker has been started on the node. Doubles as    *)
  (* the incarnation in message stamps: it is strictly greater for each new *)
  (* start, which is all a receiver needs to tell a restarted sender from a *)
  (* delayed message. The implementation provides a timestamp taken at      *)
  (* tracker start for this, not a counter it has to persist across         *)
  (* restarts. Only the order is ever compared.                             *)
  (***************************************************************************)
    starts: 0..MaxStarts,
  (***************************************************************************)
  (* The node's copy of every other node's refs.                             *)
  (***************************************************************************)
    peers: [Nodes -> Peer]
  ]

(***************************************************************************)
(* The set of all possible messages. Self-addressed messages are excluded. *)
(***************************************************************************)
Messages ==
  { m \in 
      [
        src: Nodes, 
        dest: Nodes, 
        state: SUBSET Refs, 
        age: 0..MaxDelay,
        stamp: Stamps
      ] :
      m.src /= m.dest 
  }

(***************************************************************************)
(* The set of valid messages a tracker may send to a client.               *)
(***************************************************************************)
ClientMessages ==
  [kind: {"state"}, refs: SUBSET Refs] 
  \cup 
  [kind: {"diff"}, joins: SUBSET Refs, leaves: SUBSET Refs]

(***************************************************************************)
(* The set of all possible clients states.                                 *)
(***************************************************************************)
Clients ==
  [
    (***************************************************************************)
    (* Tracks subscriptions, i.e. whether a node's client is subscribed for    *)
    (* updates.                                                                *)
    (***************************************************************************)
    subscribed: BOOLEAN,
    (***************************************************************************)
    (* Counter for how many times the node's client has subscribed. This is a  *)
    (* bounding function.                                                      *)
    (***************************************************************************)
    subscribes: 0..MaxSubscribes,
    (***************************************************************************)
    (* Tracks whether a client has been sent the state message or not. Sync    *)
    (* has to happen once per subscription, so this variable tracks that.      *)
    (***************************************************************************)
    synced: BOOLEAN,
    (***************************************************************************)
    (* Tracks the client's view of the state. This is what the client knows    *)
    (* about the tracker state, either from the initial sync or by applying    *)
    (* updates via diff messages.                                              *)
    (***************************************************************************)
    view: SUBSET Refs,
    (***************************************************************************)
    (* The message inbox for the client. This is a sequence of the messages    *)
    (* sent to the client, that it hasn't yet processed.                       *)
    (***************************************************************************)
    inbox: Seq(ClientMessages)
  ]

(***************************************************************************)
(* This defines a client's initial state, where it's not subscribed to a   *)
(* node.                                                                   *)
(***************************************************************************)
InitialClient ==
  [subscribed |-> FALSE, subscribes |-> 0, synced |-> FALSE, view |-> {}, inbox |-> <<>>]

InitialPeer ==
  [
    replica |-> {},
    silent_beats |-> 0,
    mark |-> [
      incarnation |-> 0,
      version |-> 0
    ]
  ]

InitialTracker ==
  [
    local |-> {},
    version |-> 0,
    running |-> FALSE,
    starts |-> 0,
    peers |-> [p \in Nodes |-> InitialPeer]
  ]
  
(***************************************************************************)
(* This is our initial state.                                              *)
(*                                                                         *)
(* All nodes are empty, no nodes have started, no clients are subscribed   *)
(* and no messages have been sent. It's a cold start.                      *)
(***************************************************************************)
Init == 
    /\ trackers = [n \in Nodes |-> InitialTracker]
    /\ msgs = {}
    /\ used = {}
    /\ clients = [n \in Nodes |-> InitialClient]
    /\ drops = 0

(***************************************************************************)
(* Type checking invariant that ensures our state is always valid          *)
(* according to the types.                                                 *)
(***************************************************************************)
TypeOK ==
  /\ trackers \in [Nodes -> Trackers]
  /\ msgs \subseteq Messages
  /\ used \subseteq Refs
  /\ clients \in [Nodes -> Clients]
  /\ drops \in 0..MaxDrops

(***************************************************************************)
(* `^{\large\textbf{Helper Formula}}^'                                     *)
(***************************************************************************)

(***************************************************************************)
(* Peers gets all the nodes that are not n.                                *)
(***************************************************************************)
Peers(n) == Nodes \ {n}

(***************************************************************************)
(* Returns all nodes whose tracker is running                              *)
(***************************************************************************)
Running == {n \in Nodes : trackers[n].running}

(***************************************************************************)
(* Returns all running nodes that are peers of n                           *)
(***************************************************************************)
RunningPeers(n) == Running \ {n}

(***************************************************************************)
(* Returns all nodes whose tracker is not running, stopped or crashed      *)
(***************************************************************************)
Stopped == {n \in Nodes : ~trackers[n].running}

(***************************************************************************)
(* Increments Beat if it's below the silence threshold                     *)
(***************************************************************************)
IncrementBeat(beats) ==
  IF beats < SilenceThreshold
  THEN beats + 1
  ELSE SilenceThreshold

(***************************************************************************)
(* The refs n believes m holds. Short for the field path, used wherever a  *)
(* property or action reads a replica.                                     *)
(***************************************************************************)
Replica(n, m) == trackers[n].peers[m].replica

(***************************************************************************)
(* Gets a node's view of the state of the entries. This will return a set  *)
(* of Refs that the node believes are "live", based on its local state    *)
(* and the state of its replicas.                                          *)
(***************************************************************************)
NodeView(n) ==
  LET tracker == trackers[n]
  IN tracker.local \cup UNION { tracker.peers[p].replica : p \in Peers(n) }

(***************************************************************************)
(* Gets the diff of two views of the ref state. Returned as a diff client  *)
(* message record.                                                         *)
(***************************************************************************)
Diff(old, new) ==
  [
    kind |-> "diff",
    joins |-> new \ old,
    leaves |-> old \ new
  ]

(***************************************************************************)
(* Adds a diff message to the inbox for a node's client if the client is   *)
(* subscribed and there are any changes to send.                           *)
(***************************************************************************)
Notify(n, old, new) ==
  IF clients[n].subscribed /\ old /= new
  THEN [clients EXCEPT ![n].inbox = Append(@, Diff(old, new))]
  ELSE clients

(***************************************************************************)
(* Creates a sync message from a node with includes it current state.      *)
(***************************************************************************)
SyncMessage(n) ==
  [
    kind |-> "state",
    refs |-> NodeView(n)
  ]

(***************************************************************************)
(* Resets a client's state, leaving the subscribed count intact.           *)
(***************************************************************************)
ResetClient(n) ==
  [clients EXCEPT 
    ![n].view = {}, 
    ![n].inbox = <<>>, 
    ![n].subscribed = FALSE, 
    ![n].synced = FALSE]

(***************************************************************************)
(* Helper to check if the Stamp a is newer than the stamp b.               *)
(***************************************************************************)
NewerThan(a, b) == 
      \/ a.incarnation > b.incarnation
      \/ a.incarnation = b.incarnation /\ a.version > b.version

(***************************************************************************)
(* Gets the current stamp from a tracker.                                  *)
(***************************************************************************)
TrackerStamp(n) ==
  LET tracker == trackers[n]
  IN [
    incarnation |-> tracker.starts, 
    version |-> tracker.version
  ]

(***************************************************************************)
(* `^{\large\textbf{Tracker Lifecycle Behaviours}}^'                                     *)
(***************************************************************************)

(***************************************************************************)
(* Start represents a tracker starting from scratch on a node, the cold    *)
(* start before it has received any track calls.                           *)
(***************************************************************************)
Start(n) ==
  /\ ~trackers[n].running
  /\ trackers[n].starts < MaxStarts
  /\ trackers' = [trackers EXCEPT ![n] =
       [InitialTracker EXCEPT !.running = TRUE,
                                 !.starts = trackers[n].starts + 1]]
  /\ UNCHANGED <<used, msgs, drops, clients>>

(***************************************************************************)
(* Stop is the tracker shutting down gracefully, once every client on the  *)
(* node has untracked. It sends a goodbye so peers need not wait for       *)
(* silence to notice.                                                      *)
(***************************************************************************)
Stop(n) ==
  /\ trackers[n].running
  /\ trackers[n].local = {}
  /\ ~(clients[n].synced \/ clients[n].subscribed)
  /\ trackers' = [trackers EXCEPT
       ![n].running = FALSE,
       ![n].peers = [m \in Nodes |-> InitialPeer]]
  /\ msgs' = {msg \in msgs : msg.dest /= n}
            (* This is the goodbye message in case of graceful shutdown *)
            \cup { [
              src |-> n, 
              dest |-> d, 
              state |-> {}, 
              age |-> 0, 
              stamp |-> TrackerStamp(n)
            ] : d \in RunningPeers(n) }
  /\ UNCHANGED <<used, drops, clients>>

(***************************************************************************)
(* A crash happens when a live node fails and dies. It's local state is    *)
(* wiped out, any messages to it are dropped, and it sends no more         *)
(* messages.                                                               *)
(***************************************************************************)
Crash(n) ==
  /\ trackers[n].running
  /\ trackers' = [trackers EXCEPT
       ![n].local = {},
       ![n].running = FALSE,
       ![n].peers = [m \in Nodes |-> InitialPeer]]
  /\ msgs' = {msg \in msgs : msg.dest /= n}
  /\ clients' = ResetClient(n)
  /\ UNCHANGED <<used, drops>>

(***************************************************************************)
(* Purge is how we detect that a peer node has crashed. If we haven't      *)
(* heard from it in SilenceThreshold beats, we assume it's died and we     *)
(* clear out it state from the nodes local replica.                        *)
(***************************************************************************)
Purge(n, m) ==
  /\ PurgeEnabled
  /\ Replica(n, m) /= {}
  /\ trackers[n].running
  /\ trackers[n].peers[m].silent_beats = SilenceThreshold
  /\ trackers' = [trackers EXCEPT ![n].peers[m] = InitialPeer]
  /\ clients' = Notify(n, NodeView(n), NodeView(n)')
  /\ UNCHANGED <<used, msgs, drops>>

(***************************************************************************)
(* `^{\large\textbf{Tracking Behaviours}}^'                                *)
(***************************************************************************)

(***************************************************************************)
(* Tracking a ref adds it to local for that node and to used               *)
(***************************************************************************)
Track(n, r) ==
  /\ r \notin used
  /\ trackers[n].running
  /\ trackers' = [trackers 
                  EXCEPT ![n].local = @ \cup {r},
                         ![n].version = @ + 1]
  /\ used' = used \cup {r}
  /\ clients' = Notify(n, NodeView(n), NodeView(n)')
  /\ UNCHANGED <<msgs, drops>>

(***************************************************************************)
(* Untracking a ref from a node removes it from the node's set of refs    *)
(***************************************************************************)
Untrack(n, r) ==
  /\ r \in trackers[n].local
  /\ trackers' = [trackers 
                  EXCEPT ![n].local = @ \ {r},
                         ![n].version = @ + 1]
  /\ clients' = Notify(n, NodeView(n), NodeView(n)')
  /\ UNCHANGED <<used, msgs, drops>>

(***************************************************************************)
(* `^{\large\textbf{Network Behaviours}}^'                                   *)
(***************************************************************************)

(***************************************************************************)
(* One heartbeat period for the whole cluster: every live tracker's timer  *)
(* fires. Each one sends a snapshot of its own refs to every running       *)
(* peer and counts one more silent period for every peer. Every message    *)
(* already in flight gets a period older.                                  *)
(*                                                                         *)
(* The guard is the delay bound: time cannot advance while a message has   *)
(* been in flight for MaxDelay periods already. It has to be delivered or  *)
(* dropped first.                                                          *)
(*                                                                         *)
(* A message is a source/destination pair even though the implementation  *)
(* broadcasts, since every broadcast goes from one source to every         *)
(* destination.                                                            *)
(***************************************************************************)
Tick ==
  /\ \A msg \in msgs : msg.age < MaxDelay
  /\ msgs' = { [msg EXCEPT !.age = msg.age + 1] : msg \in msgs }
             \cup UNION { { 
               [
                 src |-> n, 
                 dest |-> d, 
                 state |-> trackers[n].local, 
                 age |-> 0,
                 stamp |-> TrackerStamp(n)
                ] : d \in RunningPeers(n) } : n \in Running }
  (* Every live tracker counts one more silent period for every peer. The *)
  (* tracker record is rebuilt with its peers function replaced; stopped   *)
  (* trackers are left as they are.                                        *)
  /\ trackers' = [n \in Nodes |->
       IF trackers[n].running
       THEN [trackers[n] EXCEPT !.peers = [m \in Nodes |->
              [trackers[n].peers[m] EXCEPT !.silent_beats = IncrementBeat(@)]]]
       ELSE trackers[n]]
  /\ UNCHANGED <<used, drops, clients>>


(***************************************************************************)
(* A message is delivered to a node which incorporates the updates into    *)
(* its                                                                     *)
(* replica set for the source node of the message.                         *)
(***************************************************************************)
Deliver(msg) ==
  /\ trackers[msg.dest].running
  /\ msg \in msgs
  /\ msgs' = msgs \ {msg}
  /\ IF NewerThan(msg.stamp, trackers[msg.dest].peers[msg.src].mark)
      THEN 
        /\ trackers' = [trackers EXCEPT
             ![msg.dest].peers[msg.src].replica = msg.state,
             ![msg.dest].peers[msg.src].mark = msg.stamp,
             ![msg.dest].peers[msg.src].silent_beats = 0]
        /\ clients' = Notify(msg.dest, NodeView(msg.dest), NodeView(msg.dest)')
      ELSE 
        /\ trackers' = [trackers EXCEPT ![msg.dest].peers[msg.src].silent_beats = 0]
        /\ UNCHANGED clients
  /\ UNCHANGED <<used, drops>>

(***************************************************************************)
(* Delivery of some message on one link: whatever is in flight from s to   *)
(* d, one of those messages is delivered. Which one is left open. This     *)
(* exists so fairness can be stated per link rather than per message.      *)
(***************************************************************************)
DeliverOn(s, d) ==
  \E msg \in msgs : msg.src = s /\ msg.dest = d /\ Deliver(msg)

(***************************************************************************)
(* We model lossy transmission by adding a Drop(msg) action, when this     *)
(* happens a message is removed from the msgs set.                         *)
(***************************************************************************)
Drop(msg) ==
  /\ msg \in msgs
  /\ BoundedLoss => drops < MaxDrops
  /\ msgs' = msgs \ {msg}
  /\ drops' = IF BoundedLoss THEN drops + 1 ELSE drops
  /\ UNCHANGED <<used, trackers, clients>>

(***************************************************************************)
(* Some message in flight is delivered, or dropped. Next quantifies over   *)
(* the messages actually in flight rather than every possible message,    *)
(* which is far cheaper once messages carry stamps. These wrappers exist   *)
(* so TLC still names the step in a trace: a quantifier over a variable    *)
(* inside Next is reported as "Next", a named operator is reported by its  *)
(* name.                                                                   *)
(***************************************************************************)
DeliverAny == \E msg \in msgs : Deliver(msg)

DropAny == \E msg \in msgs : Drop(msg)


(***************************************************************************)
(* `^{\large\textbf{Client Behaviours}}^'                                   *)
(***************************************************************************)

(***************************************************************************)
(* The client subscribes to updates from the tracker.                      *)
(*                                                                         *)
(* This can only be done if the tracker is live, the client isn't already  *)
(* subscribed, and we haven't hit max subscribes.                          *)
(***************************************************************************)
Subscribe(n) ==
  /\ trackers[n].running
  /\ ~clients[n].subscribed
  /\ clients[n].subscribes < MaxSubscribes
  /\ (SubscribeFirst \/ clients[n].synced)
  /\ clients' = [clients EXCEPT ![n] = [@ EXCEPT !.subscribed = TRUE, !.subscribes = @ + 1]]
  /\ UNCHANGED <<trackers, used, drops, msgs>>

(***************************************************************************)
(* The client asks for a sync from the tracker.                            *)
(*                                                                         *)
(* This creates a new state message in the client's inbox.                 *)
(***************************************************************************)
Sync(n) ==
  /\ trackers[n].running
  /\ ~clients[n].synced
  /\ (~SubscribeFirst \/ clients[n].subscribed)
  /\ clients' = [clients EXCEPT ![n].inbox = Append(@, SyncMessage(n)), ![n].synced = TRUE ]
  /\ UNCHANGED <<trackers, used, drops, msgs>>

(***************************************************************************)
(* A client consumes the first message in its inbox.                       *)
(*                                                                         *)
(* If the message is a "state" message the clients refs are set to that    *)
(* refs in the message.                                                    *)
(*                                                                         *)
(* If the message is a "diff" message, the changes are applied to the      *)
(* client state.                                                           *)
(***************************************************************************)
Consume(n) ==
  /\ Len(clients[n].inbox) > 0
  /\ LET msg == Head(clients[n].inbox) 
    IN IF msg.kind = "state"
       THEN clients' = [clients EXCEPT ![n].view = msg.refs, ![n].inbox = Tail(@)]
       ELSE clients' = [clients EXCEPT ![n].view = (@ \ msg.leaves) \cup msg.joins, ![n].inbox = Tail(@)]
  /\ UNCHANGED <<trackers, used, drops, msgs>>


(***************************************************************************)
(* A client unsubscribes from the tracker. This removes all state in the   *)
(* client, except the subscribes count.                                    *)
(***************************************************************************)
Unsubscribe(n) ==
  /\ clients[n].subscribed
  /\ clients' = ResetClient(n)
  /\ UNCHANGED <<trackers, used, drops, msgs>>

(***************************************************************************)
(* `^{\large\textbf{Invariants and Assertions}}^'                          *)
(***************************************************************************)

(***************************************************************************)
(* Next Action can be either tracking or untracking a valid ref on a valid *)
(* node, we're sending a heart beat, or we're handling delivery of a msg,  *)
(* or a message has been dropped.                                          *)
(***************************************************************************)
Next == 
     \/ Tick
     \/ \E n \in Nodes, r \in Refs : Track(n, r) \/ Untrack(n, r)
     \/ \E n \in Nodes : \E m \in Peers(n) : Purge(n, m)
     \/ \E n \in Nodes : Start(n) \/ Stop(n) \/ Crash(n)
     \/ \E n \in Nodes : Subscribe(n) \/ Sync(n) \/ Consume(n) \/ Unsubscribe(n)
     \/ DeliverAny
     \/ DropAny

(***************************************************************************)
(* Fairness rules out runs where something is always possible but never    *)
(* happens. Without it the checker could pick a run where no timer ever    *)
(* fires or no message is ever delivered, and every liveness property      *)
(* would fail for a reason that has nothing to do with the protocol.       *)
(*                                                                         *)
(* Tick, weak fairness: if the timers can keep firing, they do. Tick is    *)
(* only blocked while a message is at its delay limit, and that always     *)
(* clears, so this says the heartbeat periods never stop.                  *)
(*                                                                         *)
(* Delivery, strong fairness, per link: if a link keeps having messages    *)
(* in flight, it keeps delivering some of them. Strong rather than weak    *)
(* because a link is empty between ticks, so delivery is only possible     *)
(* on and off, and weak fairness would let a link drop every message for   *)
(* ever. This is the transport contract the model relies on: a link may    *)
(* lose messages, but it is never dead for good.                           *)
(*                                                                         *)
(* It is stated per link, not per message. A message cannot be stuck in    *)
(* flight for ever while others on the same link get through, because      *)
(* Tick will not advance time while any message has reached MaxDelay.      *)
(* So all we need is that something on the link gets through, and that     *)
(* is a smaller assumption about the network than asking for every         *)
(* possible message to be delivered, which is what an earlier version      *)
(* did. It also made liveness checking far slower.                         *)
(*                                                                         *)
(* Purge, weak fairness: a tracker that can purge a silent peer will do    *)
(* so. Once the counter reaches the threshold it stays there until a       *)
(* message arrives, so weak fairness is enough. Without this a tracker     *)
(* could simply never run the purge step and dead state would stay.        *)
(***************************************************************************)
Fairness ==
  /\ WF_vars(Tick)
  /\ \A s \in Nodes : \A d \in Peers(s) : SF_vars(DeliverOn(s, d))
  /\ \A n \in Nodes : \A m \in Peers(n) : WF_vars(Purge(n, m))


(***************************************************************************)
(* Every ref can only exist in one node's local refs                        *)
(***************************************************************************)
OwnedOnce ==
  \A n \in Nodes : \A m \in Peers(n) : trackers[n].local \cap trackers[m].local = {}

(***************************************************************************)
(* Every replica consists only of refs that have been used.                *)
(***************************************************************************)
ReplicaIsOwned ==
  \A n \in Nodes : \A m \in Peers(n) : Replica(n, m) \subseteq used

(***************************************************************************)
(* If a replica's mark is current its state should match the state of the  *)
(* tracker.                                                                *)
(***************************************************************************)
MarkedReplicaIsCurrent ==
  \A n \in Running : \A m \in RunningPeers(n) :
    trackers[n].peers[m].mark = TrackerStamp(m)
    => trackers[n].peers[m].replica = trackers[m].local

(***************************************************************************)
(* Dead trackers have no state and receive no messages                     *)
(***************************************************************************)
NoTrackerNoState ==
  /\ \A n \in Stopped : trackers[n].local = {}
  /\ \A n \in Stopped : \A m \in Nodes : trackers[n].peers[m] = InitialPeer
  /\ \A n \in Stopped : \A msg \in msgs : msg.dest /= n

(***************************************************************************)
(* Live trackers don't hold on to the state of dead trackers.              *)
(***************************************************************************)
LiveTrackersDontCarryDeadTrackersState ==
  /\ \A n \in Running : \A m \in Stopped : Replica(n, m) = {}

DeadStatesArePurged == <>[]LiveTrackersDontCarryDeadTrackersState

(***************************************************************************)
(* Probe, expected to FAIL: a live tracker is never declared dead.         *)
(*                                                                         *)
(* Drop has no fairness, so a peer's heartbeats can be lost                *)
(* SilenceThreshold times in a row and the peer is purged while alive.     *)
(* The counterexample is the shape of a false positive: a spurious leave,  *)
(* then a spurious join when the next heartbeat lands. Convergence (the    *)
(* repair form) still holds, so the false positive is repaired, not a      *)
(* permanent divergence.                                                   *)
(*                                                                         *)
(* Any finite threshold fails here, because loss is unbounded in the       *)
(* model. The threshold is a tuning parameter, not a correctness one. Do   *)
(* not make this hold by adding fairness to Drop; that weakens the         *)
(* transport assumption rather than improving the protocol.                *)
(*                                                                         *)
(* The conditions on replica are deliberate. A counter at the threshold    *)
(* for a peer we hold nothing for is not a false positive, there is        *)
(* nothing to lose. And a replica that does not match the peer's current   *)
(* entries is a previous incarnation's leftovers (the peer crashed and     *)
(* restarted before we purged it), which purging is right to remove. The   *)
(* false positive is purging a replica that is non-empty and correct.      *)
(***************************************************************************)
FalsePositivesUnreachable ==
  \A n \in Running : \A m \in RunningPeers(n) :
    (Replica(n, m) /= {} /\ Replica(n, m) = trackers[m].local)
      => trackers[n].peers[m].silent_beats < SilenceThreshold

(***************************************************************************)
(* Probe, expected to FAIL: no message in flight is older than what its    *)
(* receiver already holds for the sender. Every counterexample is a        *)
(* message the mark exists to ignore; without the mark, delivering it      *)
(* would take the replica backwards for a period.                          *)
(*                                                                         *)
(* It fails at MaxDelay = 0 through a restart: Stop, Start, Stop on one    *)
(* node with no tick between puts two goodbyes from different incarnations *)
(* in flight together, and the newer can land first. So the incarnation    *)
(* check is needed even on a network that never delivers late. At         *)
(* MaxDelay = 1 it also fails within one incarnation: two snapshots from   *)
(* one sender are in flight together and the newer lands first, which is   *)
(* the version check's job.                                                *)
(*                                                                         *)
(* The step 5 properties cannot see either case, because per-link repair   *)
(* tolerates a replica going backwards just as it tolerates a purge. This  *)
(* probe makes the overtaking visible.                                     *)
(***************************************************************************)
NoStaleInFlight ==
  \A msg \in msgs :
    ~NewerThan(trackers[msg.dest].peers[msg.src].mark, msg.stamp)

(***************************************************************************)
(* If a client is subscribed, synced, and its inbox is empty the its view  *)
(* should match the tracker its connected to.                              *)
(***************************************************************************)
ClientViewsAreCorrect ==
  \A n \in Nodes : 
    (clients[n].subscribed /\ clients[n].synced /\ clients[n].inbox = <<>>)
    => clients[n].view = NodeView(n)

(***************************************************************************)
(* Client inboxes are bounded to length 2, so we don't run forever.        *)
(***************************************************************************)
InboxBounded ==
  \A n \in Nodes: Len(clients[n].inbox) <= 2

(***************************************************************************)
(* We are Converged when all replicas across all nodes match the local set *)
(* of that node.                                                           *)
(***************************************************************************)
Converged ==
  \A n \in Running : \A m \in RunningPeers(n) : Replica(n, m) = trackers[m].local

(***************************************************************************)
(* Repair, per link: for every pair of live trackers, the replica one      *)
(* holds for the other is correct infinitely often. No link stays broken.  *)
(* This is the guarantee under unbounded loss: a live peer can be purged   *)
(* after SilenceThreshold consecutive lost heartbeats, and that can recur  *)
(* forever, but each time the next delivered heartbeat restores it.        *)
(***************************************************************************)
PairRepair ==
  \A n \in Nodes : \A m \in Peers(n) :
    []<>( ~(trackers[n].running /\ trackers[m].running)
          \/ Replica(n, m) = trackers[m].local )

(***************************************************************************)
(* Repair, cluster-wide: every link correct at the same instant,           *)
(* infinitely often. Under unbounded loss this is FALSE: loss can          *)
(* alternate between directions so that whenever one link is restored the  *)
(* other has just been purged, forever. Each link still repairs (PairRepair *)
(* holds) but the cluster is never consistent as a whole. It holds under   *)
(* bounded loss, so it is checked in the stabilisation config.             *)
(*                                                                         *)
(* Up to step 4 this was <>[]Converged. With purging and unbounded loss    *)
(* that form is false for any finite threshold, so it moves to the         *)
(* stabilisation property below, under bounded loss.                       *)
(***************************************************************************)
Convergence ==
  []<>Converged

(***************************************************************************)
(* Stabilisation: once the network stops losing messages, the system       *)
(* settles and stays settled. Only meaningful with BoundedLoss = TRUE; with *)
(* unbounded loss it is expected to fail.                                  *)
(***************************************************************************)
Stabilisation ==
  <>[]Converged

PresenceSpec == Init /\ [][Next]_vars /\ Fairness

THEOREM PresenceSpec => [](TypeOK /\ OwnedOnce /\ ReplicaIsOwned /\ NoTrackerNoState)
THEOREM PresenceSpec => PairRepair
THEOREM PresenceSpec => DeadStatesArePurged
THEOREM BoundedLoss => (PresenceSpec => Convergence /\ Stabilisation)

====================================================================================
