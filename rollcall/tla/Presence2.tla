---------- MODULE Presence2 -------------
(***************************************************************************)
(* This is the second step of modelling precence.                          *)
(*                                                                         *)
(* In this step we add replication using heartbeats with snapshots,        *)
(* assuming a perfect network.                                             *)
(***************************************************************************)

CONSTANTS
  Nodes,  
  (***************************************************************************)
  (* Refs are the equivalent of a phx_ref, every track call generates a      *)
  (* unique one                                                              *)
  (***************************************************************************)
  Refs,
  (***************************************************************************)
  (* Whether unique refs is enforced, enables easy tests                     *)
  (***************************************************************************)
  UniqueRefs

VARIABLES 
  \* maps nodes to the refs they hold locally
  local, 
  \* Every ref we've ever tracked
  used,
  \* every node's copy of every other node's refs
  replica,
  \* inflight heartbeats
  msgs

ASSUME UniqueRefs \in BOOLEAN

vars == <<local, used, replica, msgs>>

(***************************************************************************)
(* The set of all possible messages                                        *)
(***************************************************************************)
Messages == [src:Nodes, dest: Nodes, state: SUBSET Refs]

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
(* Tracking a ref adds it to local for that node and to used               *)
(***************************************************************************)
Track(n, r) == /\ UniqueRefs => r \notin used
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
  /\ msgs' = msgs \cup { [src |-> n, dest |-> d, state |-> local[n]] : d \in Nodes \ {n}}
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
(* Fairness makes sure that nodes send heartbeats and that messages get    *)
(* delivered.                                                              *)
(***************************************************************************)
Fairness ==
  /\ \A n \in Nodes : WF_vars(Heartbeat(n))
  /\ \A msg \in Messages : WF_vars(Deliver(msg))

(***************************************************************************)
(* Next Action can be either tracking or untracking a valid ref on a valid *)
(* node, we're sending a heart beat, or we're handling delivery of a msg   *)
(***************************************************************************)
Next == 
     \/ \E n \in Nodes, r \in Refs : Track(n, r) \/ Untrack(n, r)
     \/ \E n \in Nodes : Heartbeat(n)
     \/ \E msg \in msgs : Deliver(msg)

(***************************************************************************)
(* Every ref can only exist in one node's local refs                        *)
(***************************************************************************)
OwnedOnce == 
  \A n, m \in Nodes : n /= m => local[n] \cap local[m] = {}

(***************************************************************************)
(* Every replica consists only of refs that have been used.                *)
(***************************************************************************)
ReplicaIsOwned ==
  \A n, m \in Nodes : n /= m => replica[n][m] \subseteq used 

(***************************************************************************)
(* We are Converged when all replicas across all nodes match the local set *)
(* of that node.                                                           *)
(***************************************************************************)
Converged ==
  \A n, m \in Nodes : n /= m => replica[n][m] = local[m]

(***************************************************************************)
(* The system eventually converges.                                        *)
(***************************************************************************)
Convergence ==
  <>[]Converged

PresenceSpec == Init /\ [][Next]_vars /\ Fairness

THEOREM PresenceSpec => [](TypeOK /\ OwnedOnce)

(***************************************************************************)
(* These spec are expected to fail:                                        *)
(***************************************************************************)

(***************************************************************************)
(* The same spec without fairness will cause the messages to never be      *)
(* sent.                                                                   *)
(***************************************************************************)
UnfairSpec == Init /\ [][Next]_vars

(***************************************************************************)
(* Replicas should not be empty, this counter example shows they fill.     *)
(***************************************************************************)
ReplicasEmpty == \A n, m \in Nodes : replica[n][m] = {}

====================================================================================
