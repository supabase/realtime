---------- MODULE Presence3 -------------
(*******************************************************************************)
(* This is the third step of modelling precence.                               *)
(*                                                                             *)
(* In this step we build on replication and heartbeats to add a lossy network. *)
(*******************************************************************************)

CONSTANTS
  Nodes,  
  (***************************************************************************)
  (* Refs are the equivalent of a phx_ref, every track call generates a      *)
  (* unique one                                                              *)
  (***************************************************************************)
  Refs,
   
 (***************************************************************************)
 (* These constants switch mechanisms on or off so we can see the spec fail *)
 (* and show that these design choices are needed.                          *)
 (***************************************************************************)

  (***************************************************************************)
  (* Whether unique refs is enforced, enables easy tests                     *)
  (***************************************************************************)
  UniqueRefs,
  (***************************************************************************)
  (* Boolean allowing us to control whether we're doing a period heartbeat   *)
  (* vs a send on change. We need to do a heartbeat, send on change fails to *)
  (* converge with a lossy network.                                          *)
  (***************************************************************************)
  PeriodicHeartbeat


VARIABLES 
  \* maps nodes to the refs they hold locally
  local, 
  \* Every ref we've ever tracked
  used,
  \* every node's copy of every other node's refs
  replica,
  \* inflight heartbeats
  msgs,
  \* dirty flags let us similate heart on change if PeriodicHeartbeat is false
  dirty

ASSUME UniqueRefs \in BOOLEAN
ASSUME PeriodicHeartbeat \in BOOLEAN

vars == <<local, used, replica, msgs, dirty>>

(***************************************************************************)
(* The set of all possible messages                                        *)
(***************************************************************************)
Messages == [src:Nodes, dest: Nodes, state: SUBSET Refs]

Init == 
    /\ local = [n \in Nodes |-> {}]
    /\ replica = [n \in Nodes |-> [m \in Nodes |-> {}]]
    /\ msgs = {}
    /\ used = {}
    /\ dirty = [n \in Nodes |-> FALSE]

TypeOK == 
  /\ local \in [Nodes -> SUBSET Refs]
  /\ replica \in [Nodes -> [Nodes -> SUBSET Refs]]
  /\ msgs \subseteq Messages
  /\ used \subseteq Refs
  /\ dirty \in [Nodes -> BOOLEAN]

(***************************************************************************)
(* Peers gets all the nodes that are not n.                                *)
(***************************************************************************)
Peers(n) == Nodes \ {n}

(***************************************************************************)
(* Tracking a ref adds it to local for that node and to used               *)
(***************************************************************************)
Track(n, r) == /\ UniqueRefs => r \notin used
              /\ local' = [local EXCEPT ![n] = local[n] \cup {r}]
              /\ used' = used \cup {r}
              /\ dirty' = [dirty EXCEPT ![n] = TRUE]
              /\ UNCHANGED <<replica, msgs>>

(***************************************************************************)
(* Untracking a ref from a node removes it from the node's set of refs    *)
(***************************************************************************)
Untrack(n, r) == /\ r \in local[n]
                /\ local' = [local EXCEPT ![n] = local[n] \ {r}]
                /\ dirty' = [dirty EXCEPT ![n] = TRUE]
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
  /\ PeriodicHeartbeat \/ dirty[n]
  /\ msgs' = msgs \cup { [src |-> n, dest |-> d, state |-> local[n]] : d \in Peers(n) }
  /\ dirty' = [dirty EXCEPT ![n] = FALSE]
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
  /\ UNCHANGED <<used, local, dirty>>

(***************************************************************************)
(* We model lossy transmission by adding a Drop(msg) action, when this     *)
(* happens a message is removed from the msgs set.                         *)
(***************************************************************************)
Drop(msg) ==
  /\ msg \in msgs
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<used, local, replica, dirty>>

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
