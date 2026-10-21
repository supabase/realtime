---------- MODULE Presence4 -------------
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
  Refs

VARIABLES 
  \* maps nodes to the refs they hold locally
  local, 
  \* Every ref we've ever tracked
  used,
  \* every node's copy of every other node's refs
  replica,
  \* inflight heartbeats
  msgs

vars == <<local, used, replica, msgs>>

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

TypeOK == 
  /\ local \in [Nodes -> SUBSET Refs]
  /\ replica \in [Nodes -> [Nodes -> SUBSET Refs]]
  /\ msgs \subseteq Messages
  /\ used \subseteq Refs

(***************************************************************************)
(* Peers gets all the nodes that are not n.                                *)
(***************************************************************************)
Peers(n) == Nodes \ {n}

(***************************************************************************)
(* Tracking a ref adds it to local for that node and to used               *)
(***************************************************************************)
Track(n, r) == /\ r \notin used
              /\ local' = [local EXCEPT ![n] = local[n] \cup {r}]
              /\ used' = used \cup {r}
              /\ UNCHANGED <<replica, msgs>>

(***************************************************************************)
(* Untracking a ref from a node removes it from the node's set of refs    *)
(***************************************************************************)
Untrack(n, r) == /\ r \in local[n]
                /\ local' = [local EXCEPT ![n] = local[n] \ {r}]
                /\ UNCHANGED <<used, replica, msgs>>

(***************************************************************************)
(* Heartbeat sent by a node to another node.                               *)
(*                                                                         *)
(* This includes the source nodes local refs. Note that the message has a  *)
(* source destination pair, even though we'd broadcast these in the        *)
(* implementation, we model this as a pair-wise message, since every       *)
(* broadcast message goes from one source to every destination.            *)
(***************************************************************************)
Heartbeat(n) ==
  /\ msgs' = msgs \cup { [src |-> n, dest |-> d, state |-> local[n]] : d \in Peers(n) }
  /\ UNCHANGED <<used, replica, local>>

(***************************************************************************)
(* A message is delivered to a node which incorporates the updates into    *)
(* its                                                                     *)
(* replica set for the source node of the message.                         *)
(***************************************************************************)
Deliver(msg) ==
  /\ msg \in msgs
  /\ msgs' = msgs \ {msg}
  /\ replica' = [replica EXCEPT ![msg.dest][msg.src] = msg.state]
  /\ UNCHANGED <<used, local>>

(***************************************************************************)
(* We model lossy transmission by adding a Drop(msg) action, when this     *)
(* happens a message is removed from the msgs set.                         *)
(***************************************************************************)
Drop(msg) ==
  /\ msg \in msgs
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<used, local, replica>>

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
     \/ \E n \in Nodes : Heartbeat(n)
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
(* We are Converged when all replicas across all nodes match the local set *)
(* of that node.                                                           *)
(***************************************************************************)
Converged ==
  \A n \in Nodes : \A m \in Peers(n) : replica[n][m] = local[m]

(***************************************************************************)
(* The system eventually converges.                                        *)
(***************************************************************************)
Convergence ==
  <>[]Converged

PresenceSpec == Init /\ [][Next]_vars /\ Fairness

THEOREM PresenceSpec => [](TypeOK /\ OwnedOnce /\ ReplicaIsOwned)
THEOREM PresenceSpec => Convergence

====================================================================================
