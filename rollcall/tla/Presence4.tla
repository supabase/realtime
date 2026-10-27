---------- MODULE Presence4 -------------
EXTENDS Integers

(*******************************************************************************)
(* This is the fourth step of modelling presence.                              *)
(*                                                                             *)
(* In this step we add interest: a tracker exists on a node only while it has  *)
(* clients, and heartbeats go only to nodes with a tracker.                    *)
(*                                                                             *)
(* The witness switches from step 3 (UniqueRefs, PeriodicHeartbeat, dirty)     *)
(* are not carried forward; their lessons are recorded in Presence3 and NOTES. *)
(*******************************************************************************)

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
  MaxJoins

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
  joins

ASSUME MaxJoins \in Nat

vars == <<local, used, replica, msgs, joins, interested>>

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

TypeOK == 
  /\ local \in [Nodes -> SUBSET Refs]
  /\ replica \in [Nodes -> [Nodes -> SUBSET Refs]]
  /\ msgs \subseteq Messages
  /\ used \subseteq Refs
  /\ interested \in [Nodes -> BOOLEAN]
  /\ joins \in [Nodes -> 0..MaxJoins]

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
  /\ UNCHANGED <<local, joins, used>>

(***************************************************************************)
(* Tracking a ref adds it to local for that node and to used               *)
(***************************************************************************)
Track(n, r) == /\ r \notin used
              /\ interested[n]
              /\ local' = [local EXCEPT ![n] = local[n] \cup {r}]
              /\ used' = used \cup {r}
              /\ UNCHANGED <<replica, msgs, joins, interested>>

(***************************************************************************)
(* Untracking a ref from a node removes it from the node's set of refs    *)
(***************************************************************************)
Untrack(n, r) == /\ r \in local[n]
                /\ local' = [local EXCEPT ![n] = local[n] \ {r}]
                /\ UNCHANGED <<used, replica, msgs, joins, interested>>

(***************************************************************************)
(* Heartbeat sent by a node to another node.                               *)
(*                                                                         *)
(* This includes the source nodes local refs. Note that the message has a  *)
(* source destination pair, even though we'd broadcast these in the        *)
(* implementation, we model this as a pair-wise message, since every       *)
(* broadcast message goes from one source to every destination.            *)
(***************************************************************************)
Heartbeat(n) ==
  /\ interested[n]
  /\ msgs' = msgs \cup { [src |-> n, dest |-> d, state |-> local[n]] : d \in InterestedPeers(n) }
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
  /\ UNCHANGED <<used, local, interested, joins>>

(***************************************************************************)
(* We model lossy transmission by adding a Drop(msg) action, when this     *)
(* happens a message is removed from the msgs set.                         *)
(***************************************************************************)
Drop(msg) ==
  /\ msg \in msgs
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<used, local, replica, interested, joins>>

(***************************************************************************)
(* Fairness makes sure that nodes send heartbeats and that messages get    *)
(* delivered. Delivery changed to strong fairness otherwise we get         *)
(* partitioning with weak delivery, strong fairness ensures retries        *)
(* eventually work.                                                        *)
(***************************************************************************)
Fairness ==
  /\ \A n \in Nodes : WF_vars(Heartbeat(n))
  /\ \A msg \in Messages : SF_vars(Deliver(msg))

(***************************************************************************)
(* Next Action can be either tracking or untracking a valid ref on a valid *)
(* node, we're sending a heart beat, or we're handling delivery of a msg,  *)
(* or a message has been dropped.                                          *)
(***************************************************************************)
Next == 
     \/ \E n \in Nodes, r \in Refs : Track(n, r) \/ Untrack(n, r)
     \/ \E n \in Nodes : Heartbeat(n) \/ Join(n) \/ Leave(n)
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
(* This won't actually pass at the moment, because when a tracker dies     *)
(* after it just sends it heartbeat, other trackers have no way of         *)
(* knowing... yet, we'll solve this in step 5, options are a leave message *)
(* or purging state after a period of silence.                             *)
(***************************************************************************)
LiveTrackersDontCarryDeadTrackersState ==
  /\ \A n \in Interested : \A m \in Uninterested : replica[n][m] = {}

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

THEOREM PresenceSpec => [](TypeOK /\ OwnedOnce /\ ReplicaIsOwned)
THEOREM PresenceSpec => Convergence

====================================================================================
