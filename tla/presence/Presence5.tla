---------- MODULE Presence5 -------------
EXTENDS Integers

(***************************************************************************)
(* This is the fifth step of modelling presence.                           *)
(*                                                                         *)
(* In this step we're modelling what happens when a node crashes, and      *)
(* resolving the issue purging stale state on other nodes.                 *)
(***************************************************************************)

CONSTANTS
  Nodes,  
  (***************************************************************************)
  (* Refs are the equivalent of a phx_ref, every track call generates a      *)
  (* unique one                                                              *)
  (***************************************************************************)
  Refs,
  (***************************************************************************)
  (* Bound that we allow on joins per tracker                                *)
  (***************************************************************************)
  MaxJoins,
  (***************************************************************************)
  (* How much time has passed before we assume a node is dead, if we haven't *)
  (* heard from it. This is measured in "heartbeats" since we have no        *)
  (* concept of time in TLA+                                                 *)
  (***************************************************************************)
  SilenceThreshold,
  (***************************************************************************)
  (* A probe that allows us to check how the system behaves if purging is    *)
  (* disabled. This should fail the checker when false due to crashed node   *)
  (* state not being removed.                                                *)
  (***************************************************************************)
  PurgeEnabled

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
  \* counter for how many joins we've seen per tracker
  joins,
  (***************************************************************************)
  (* Cool variable name. This stores the beats that have passed since a node *)
  (* has heard from each other node                                          *)
  (***************************************************************************)
  silent_beats

ASSUME MaxJoins \in Nat
ASSUME SilenceThreshold \in Nat \ {0}
ASSUME PurgeEnabled \in BOOLEAN

vars == <<local, used, replica, msgs, joins, interested, silent_beats>>

(***************************************************************************)
(* The set of all possible messages. Self-addressed messages are excluded: *)
(* no action creates one, and every member of this set is a strong         *)
(* fairness conjunct, which is what makes liveness checking slow.          *)
(***************************************************************************)
Messages ==
  { m \in [src: Nodes, dest: Nodes, state: SUBSET Refs] : m.src /= m.dest }

Init == 
    /\ local = [n \in Nodes |-> {}]
    /\ replica = [n \in Nodes |-> [m \in Nodes |-> {}]]
    /\ msgs = {}
    /\ used = {}
    /\ interested = [n \in Nodes |-> FALSE]
    /\ joins = [n \in Nodes |-> 0]
    /\ silent_beats = [n \in Nodes |-> [m \in Nodes |-> 0]]

TypeOK == 
  /\ local \in [Nodes -> SUBSET Refs]
  /\ replica \in [Nodes -> [Nodes -> SUBSET Refs]]
  /\ msgs \subseteq Messages
  /\ used \subseteq Refs
  /\ interested \in [Nodes -> BOOLEAN]
  /\ joins \in [Nodes -> 0..MaxJoins]
  /\ silent_beats \in [Nodes -> [Nodes -> 0..SilenceThreshold]]

(***************************************************************************)
(* Peers gets all the nodes that are not n.                                *)
(***************************************************************************)
Peers(n) == Nodes \ {n}

Interested == {n \in Nodes : interested[n]}

InterestedPeers(n) == Interested \ {n}

Uninterested == {n \in Nodes : ~interested[n]}

(***************************************************************************)
(* Join represents a node starting from scratch, it's the cold start       *)
(* before it's received any track calls.                                   *)
(***************************************************************************)
Join(n) == 
  /\ ~interested[n]
  /\ joins[n] < MaxJoins
  /\ interested' = [interested EXCEPT ![n] = TRUE]
  /\ replica' = [replica EXCEPT ![n] = [m \in Nodes |-> {}]]
  /\ joins' = [joins EXCEPT ![n] = joins[n] + 1]
  /\ silent_beats' = [silent_beats EXCEPT ![n] = [m \in Nodes |-> 0]]
  /\ UNCHANGED <<local, used, msgs>>

(***************************************************************************)
(* This happens when all clients on a node untrack and the tracker on that *)
(* node shuts down                                                         *)
(***************************************************************************)
Leave(n) ==
  /\ interested[n]
  /\ local[n] = {}
  /\ interested' = [interested EXCEPT ![n] = FALSE]
  /\ replica' = [replica EXCEPT ![n] = [m \in Nodes |-> {}]]
  /\ msgs' = {msg \in msgs : msg.dest /= n}
            (* This is the goodbye message in case of graceful shutdown *)
            \cup { [src |-> n, dest |-> d, state |-> {}] : d \in InterestedPeers(n) }
  /\ UNCHANGED <<local, joins, used, silent_beats>>

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
  /\ UNCHANGED <<joins, used, silent_beats>>

(***************************************************************************)
(* Purge is how we detect that a peer node has crashed. If we haven't      *)
(* heard from it in SilenceThreshold beats, we assume it's died and we     *)
(* clear out it state from the nodes local replica.                        *)
(***************************************************************************)
Purge(n, m) ==
  /\ replica[n][m] /= {}
  /\ interested[n]
  /\ silent_beats[n][m] = SilenceThreshold
  /\ replica' = [replica EXCEPT ![n][m] = {}]
  /\ UNCHANGED <<used, joins, silent_beats, local, interested, msgs>>

(***************************************************************************)
(* Tracking a ref adds it to local for that node and to used               *)
(***************************************************************************)
Track(n, r) == /\ r \notin used
              /\ interested[n]
              /\ local' = [local EXCEPT ![n] = local[n] \cup {r}]
              /\ used' = used \cup {r}
              /\ UNCHANGED <<replica, msgs, joins, interested, silent_beats>>

(***************************************************************************)
(* Untracking a ref from a node removes it from the node's set of refs    *)
(***************************************************************************)
Untrack(n, r) == /\ r \in local[n]
                /\ local' = [local EXCEPT ![n] = local[n] \ {r}]
                /\ UNCHANGED <<used, replica, msgs, joins, interested, silent_beats>>

(***************************************************************************)
(* Heartbeat sent by a node to another node.                               *)
(*                                                                         *)
(* This includes the source nodes local refs. Note that the message has a  *)
(* source destination pair, even though we'd broadcast these in the        *)
(* implementation, we model this as a pair-wise message, since every       *)
(* broadcast message goes from one source to every destination.            *)
(***************************************************************************)
IncrementBeat(beats) ==
  IF beats < SilenceThreshold 
  THEN beats + 1
  ELSE SilenceThreshold

Heartbeat(n) ==
  /\ interested[n]
  /\ msgs' = msgs \cup { [src |-> n, dest |-> d, state |-> local[n]] : d \in InterestedPeers(n) }
  /\ silent_beats' = [silent_beats EXCEPT ![n] = [m \in Nodes |-> (IncrementBeat(silent_beats[n][m]))]]
  /\ UNCHANGED <<used, replica, local, interested, joins>>


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
  /\ UNCHANGED <<used, local, interested, joins>>

(***************************************************************************)
(* We model lossy transmission by adding a Drop(msg) action, when this     *)
(* happens a message is removed from the msgs set.                         *)
(***************************************************************************)
Drop(msg) ==
  /\ msg \in msgs
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<used, local, replica, interested, joins, silent_beats>>

(***************************************************************************)
(* Fairness makes sure that nodes send heartbeats and that messages get    *)
(* delivered. Delivery changed to strong fairness otherwise we get         *)
(* partitioning with weak delivery, strong fairness ensures retries        *)
(* eventually work. We also make sure that nodes get to Purge dead peers.  *)
(***************************************************************************)
Fairness ==
  /\ \A n \in Nodes : WF_vars(Heartbeat(n))
  /\ \A msg \in Messages : SF_vars(Deliver(msg))
  /\ \A n, m \in Nodes : WF_vars(Purge(n, m))

(***************************************************************************)
(* Next Action can be either tracking or untracking a valid ref on a valid *)
(* node, we're sending a heart beat, or we're handling delivery of a msg,  *)
(* or a message has been dropped.                                          *)
(***************************************************************************)
Next == 
     \/ \E n \in Nodes, r \in Refs : Track(n, r) \/ Untrack(n, r)
     \/ \E n \in Nodes : \E m \in Peers(n) : Purge(n, m)
     \/ \E n \in Nodes : Heartbeat(n) \/ Join(n) \/ Leave(n) \/ Crash(n)
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
(* then a spurious join when the next heartbeat lands. Convergence still   *)
(* holds, so the false positive is a transient, not a divergence.          *)
(*                                                                         *)
(* Any finite threshold fails here, because loss is unbounded in the       *)
(* model. The threshold is a tuning parameter, not a correctness one. Do   *)
(* not make this hold by adding fairness to Drop; that weakens the         *)
(* transport assumption rather than improving the protocol.                *)
(***************************************************************************)
FalsePositivesUnreachable ==
  \A n \in Interested : \A m \in InterestedPeers(n) :
    silent_beats[n][m] < SilenceThreshold

(***************************************************************************)
(* We are Converged when all replicas across all nodes match the local set *)
(* of that node.                                                           *)
(***************************************************************************)
Converged ==
  \A n \in Interested : \A m \in InterestedPeers(n) : replica[n][m] = local[m]

(***************************************************************************)
(* The system eventually converges.                                        *)
(***************************************************************************)
Convergence ==
  <>[]Converged



PresenceSpec == Init /\ [][Next]_vars /\ Fairness

THEOREM PresenceSpec => [](TypeOK /\ OwnedOnce /\ ReplicaIsOwned /\ NoTrackerNoState)
THEOREM PresenceSpec => Convergence

====================================================================================
