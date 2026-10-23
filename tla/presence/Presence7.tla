---------- MODULE Presence7 -------------
EXTENDS Integers

(***************************************************************************)
(* This is the seventh step of modelling presence: the client contract.    *)
(*                                                                         *)
(* It starts as a copy of step 5 with the tracker lifecycle renamed. Join  *)
(* is now Start and Leave is now Stop, with the bound MaxStarts, because   *)
(* join and leave are what the client contract calls an entry appearing    *)
(* and disappearing, and this step adds that contract.                     *)
(*                                                                         *)
(* Time works as in step 5: one Tick fires every live tracker's timer,     *)
(* messages carry their age in ticks, and ordering is never assumed.       *)
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
  MaxDrops

VARIABLES 
  \* maps nodes to the refs they hold locally
  local, 
  \* Every ref we've ever tracked
  used,
  \* every node's copy of every other node's refs
  replica,
  \* inflight heartbeats
  msgs,
  \* whether the tracker is interested, i.e. running, on a node 
  interested,
  \* counter for how many times the tracker has started per node
  starts,
  (***************************************************************************)
  (* Cool variable name. This stores the beats that have passed since a node *)
  (* has heard from each other node                                          *)
  (***************************************************************************)
  silent_beats,
  \* messages dropped so far; only counted when BoundedLoss is TRUE
  drops

ASSUME MaxStarts \in Nat
ASSUME SilenceThreshold \in Nat \ {0}
ASSUME MaxDelay \in Nat
ASSUME PurgeEnabled \in BOOLEAN
ASSUME BoundedLoss \in BOOLEAN
ASSUME MaxDrops \in Nat

(***************************************************************************)
(* The design constraint this step exists to state. A tracker's silence    *)
(* counter for a peer goes up every tick, including the tick in which the  *)
(* peer's latest snapshot was sent and is still in flight. A snapshot sent  *)
(* in tick r can arrive as late as tick r + MaxDelay, by which time the     *)
(* counter reads MaxDelay + 1. The threshold must be strictly above that,   *)
(* or a merely late heartbeat is indistinguishable from a dead peer.        *)
(***************************************************************************)
ASSUME MaxDelay + 1 < SilenceThreshold

vars == <<local, used, replica, msgs, starts, interested, silent_beats, drops>>

(***************************************************************************)
(* The set of all possible messages. Self-addressed messages are excluded. *)
(***************************************************************************)
Messages ==
  { m \in [src: Nodes, dest: Nodes, state: SUBSET Refs, age: 0..MaxDelay] :
      m.src /= m.dest }

Init == 
    /\ local = [n \in Nodes |-> {}]
    /\ replica = [n \in Nodes |-> [m \in Nodes |-> {}]]
    /\ msgs = {}
    /\ used = {}
    /\ interested = [n \in Nodes |-> FALSE]
    /\ starts = [n \in Nodes |-> 0]
    /\ silent_beats = [n \in Nodes |-> [m \in Nodes |-> 0]]
    /\ drops = 0

TypeOK ==
  /\ local \in [Nodes -> SUBSET Refs]
  /\ replica \in [Nodes -> [Nodes -> SUBSET Refs]]
  /\ msgs \subseteq Messages
  /\ used \subseteq Refs
  /\ interested \in [Nodes -> BOOLEAN]
  /\ starts \in [Nodes -> 0..MaxStarts]
  /\ silent_beats \in [Nodes -> [Nodes -> 0..SilenceThreshold]]
  /\ drops \in 0..MaxDrops

(***************************************************************************)
(* Peers gets all the nodes that are not n.                                *)
(***************************************************************************)
Peers(n) == Nodes \ {n}

Interested == {n \in Nodes : interested[n]}

InterestedPeers(n) == Interested \ {n}

Uninterested == {n \in Nodes : ~interested[n]}

(***************************************************************************)
(* Start represents a tracker starting from scratch on a node, the cold    *)
(* start before it has received any track calls.                           *)
(***************************************************************************)
Start(n) == 
  /\ ~interested[n]
  /\ starts[n] < MaxStarts
  /\ interested' = [interested EXCEPT ![n] = TRUE]
  /\ replica' = [replica EXCEPT ![n] = [m \in Nodes |-> {}]]
  /\ starts' = [starts EXCEPT ![n] = starts[n] + 1]
  /\ silent_beats' = [silent_beats EXCEPT ![n] = [m \in Nodes |-> 0]]
  /\ UNCHANGED <<local, used, msgs, drops>>

(***************************************************************************)
(* Stop is the tracker shutting down gracefully, once every client on the  *)
(* node has untracked. It sends a goodbye so peers need not wait for       *)
(* silence to notice.                                                      *)
(***************************************************************************)
Stop(n) ==
  /\ interested[n]
  /\ local[n] = {}
  /\ interested' = [interested EXCEPT ![n] = FALSE]
  /\ replica' = [replica EXCEPT ![n] = [m \in Nodes |-> {}]]
  /\ msgs' = {msg \in msgs : msg.dest /= n}
            (* This is the goodbye message in case of graceful shutdown *)
            \cup { [src |-> n, dest |-> d, state |-> {}, age |-> 0] : d \in InterestedPeers(n) }
  /\ UNCHANGED <<local, starts, used, silent_beats, drops>>

(***************************************************************************)
(* A crash happens when a live node fails and dies. It's local state is    *)
(* wiped out, any messages to it are dropped, and it sends no more         *)
(* messages.                                                               *)
(***************************************************************************)
Crash(n) ==
  /\ interested[n]
  /\ local' = [local EXCEPT ![n] = {}]
  /\ interested' = [interested EXCEPT ![n] = FALSE]
  /\ replica' = [replica EXCEPT ![n] = [m \in Nodes |-> {}]]
  /\ msgs' = {msg \in msgs : msg.dest /= n}
  /\ UNCHANGED <<starts, used, silent_beats, drops>>

(***************************************************************************)
(* Purge is how we detect that a peer node has crashed. If we haven't      *)
(* heard from it in SilenceThreshold beats, we assume it's died and we     *)
(* clear out it state from the nodes local replica.                        *)
(***************************************************************************)
Purge(n, m) ==
  /\ PurgeEnabled
  /\ replica[n][m] /= {}
  /\ interested[n]
  /\ silent_beats[n][m] = SilenceThreshold
  /\ replica' = [replica EXCEPT ![n][m] = {}]
  /\ UNCHANGED <<used, starts, silent_beats, local, interested, msgs, drops>>

(***************************************************************************)
(* Tracking a ref adds it to local for that node and to used               *)
(***************************************************************************)
Track(n, r) == /\ r \notin used
              /\ interested[n]
              /\ local' = [local EXCEPT ![n] = local[n] \cup {r}]
              /\ used' = used \cup {r}
              /\ UNCHANGED <<replica, msgs, starts, interested, silent_beats, drops>>

(***************************************************************************)
(* Untracking a ref from a node removes it from the node's set of refs    *)
(***************************************************************************)
Untrack(n, r) == /\ r \in local[n]
                /\ local' = [local EXCEPT ![n] = local[n] \ {r}]
                /\ UNCHANGED <<used, replica, msgs, starts, interested, silent_beats, drops>>

IncrementBeat(beats) ==
  IF beats < SilenceThreshold
  THEN beats + 1
  ELSE SilenceThreshold

(***************************************************************************)
(* One heartbeat period for the whole cluster: every live tracker's timer  *)
(* fires. Each one sends a snapshot of its own refs to every interested    *)
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
             \cup UNION { { [src |-> n, dest |-> d, state |-> local[n], age |-> 0]
                            : d \in InterestedPeers(n) }
                          : n \in Interested }
  /\ silent_beats' = [n \in Nodes |-> [m \in Nodes |->
                       IF interested[n] THEN IncrementBeat(silent_beats[n][m])
                                        ELSE silent_beats[n][m]]]
  /\ UNCHANGED <<used, replica, local, interested, starts, drops>>


(***************************************************************************)
(* A message is delivered to a node which incorporates the updates into    *)
(* its                                                                     *)
(* replica set for the source node of the message.                         *)
(***************************************************************************)
Deliver(msg) ==
  /\ interested[msg.dest]
  /\ msg \in msgs
  /\ msgs' = msgs \ {msg}
  /\ replica' = [replica EXCEPT ![msg.dest][msg.src] = msg.state]
  /\ silent_beats' = [silent_beats EXCEPT ![msg.dest][msg.src] = 0]
  /\ UNCHANGED <<used, local, interested, starts, drops>>

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
  /\ UNCHANGED <<used, local, replica, interested, starts, silent_beats>>

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
(* Next Action can be either tracking or untracking a valid ref on a valid *)
(* node, we're sending a heart beat, or we're handling delivery of a msg,  *)
(* or a message has been dropped.                                          *)
(***************************************************************************)
Next == 
     \/ \E n \in Nodes, r \in Refs : Track(n, r) \/ Untrack(n, r)
     \/ \E n \in Nodes : \E m \in Peers(n) : Purge(n, m)
     \/ Tick
     \/ \E n \in Nodes : Start(n) \/ Stop(n) \/ Crash(n)
     \/ \E msg \in Messages : Deliver(msg)
     \/ \E msg \in Messages : Drop(msg)

(***************************************************************************)
(* Every ref can only exist in one node's local refs                        *)
(***************************************************************************)
OwnedOnce == 
  \A n \in Nodes : \A m \in Peers(n) : local[n] \cap local[m] = {}

(***************************************************************************)
(* Every replica consists only of refs that have been used.                *)
(***************************************************************************)
ReplicaIsOwned ==
  \A n \in Nodes : \A m \in Peers(n) : replica[n][m] \subseteq used 

(***************************************************************************)
(* Dead trackers have no state and receive no messages                     *)
(***************************************************************************)
NoTrackerNoState == 
  /\ \A n \in Uninterested : local[n] = {}
  /\ \A n \in Uninterested : \A m \in Nodes : replica[n][m] = {}
  /\ \A n \in Uninterested : \A msg \in msgs : msg.dest /= n
  
(***************************************************************************)
(* Live trackers don't hold on to the state of dead trackers.              *)
(***************************************************************************)
LiveTrackersDontCarryDeadTrackersState ==
  /\ \A n \in Interested : \A m \in Uninterested : replica[n][m] = {}

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
  \A n \in Interested : \A m \in InterestedPeers(n) :
    (replica[n][m] /= {} /\ replica[n][m] = local[m])
      => silent_beats[n][m] < SilenceThreshold

(***************************************************************************)
(* We are Converged when all replicas across all nodes match the local set *)
(* of that node.                                                           *)
(***************************************************************************)
Converged ==
  \A n \in Interested : \A m \in InterestedPeers(n) : replica[n][m] = local[m]

(***************************************************************************)
(* Repair, per link: for every pair of live trackers, the replica one      *)
(* holds for the other is correct infinitely often. No link stays broken.  *)
(* This is the guarantee under unbounded loss: a live peer can be purged   *)
(* after SilenceThreshold consecutive lost heartbeats, and that can recur  *)
(* forever, but each time the next delivered heartbeat restores it.        *)
(***************************************************************************)
PairRepair ==
  \A n \in Nodes : \A m \in Peers(n) :
    []<>( ~(interested[n] /\ interested[m]) \/ replica[n][m] = local[m] )

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
