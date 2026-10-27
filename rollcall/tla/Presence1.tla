---------- MODULE Presence1 -------------
(***************************************************************************)
(*  First step of modelling presence in TLA                                *)
(*                                                                         *)
(*  We're just modelling track and untrack in local nodes for now.         *)
(***************************************************************************)

CONSTANTS
  Nodes,  
  \* Refs are the equivalent of a phx_ref, every track call generates a unique one
  Refs,
  UniqueRefs \* Whether unique refs is enforced, enables easy tests

VARIABLES local, \* maps nodes to the refs they hold locally
          used \* Every ref we've ever tracked

ASSUME UniqueRefs \in BOOLEAN

vars == <<local, used>>

Init == 
    /\ local = [n \in Nodes |-> {}]
    /\ used = {}

TypeOK == 
  /\ local \in [Nodes -> SUBSET Refs]
  /\ used \subseteq Refs

(***************************************************************************)
(* Tracking a ref adds it to local for that node and to used               *)
(***************************************************************************)
Track(n, r) == /\ UniqueRefs => r \notin used
              /\ local' = [local EXCEPT ![n] = local[n] \cup {r}]
              /\ used' = used \cup {r}

(***************************************************************************)
(* Untracking a ref from a node removes it from the node's set of refs    *)
(***************************************************************************)
Untrack(n, r) == /\ r \in local[n]
                /\ local' = [local EXCEPT ![n] = local[n] \ {r}]
                /\ UNCHANGED used

(***************************************************************************)
(* We terminate when the nodes are empty and every ref has been used       *)
(***************************************************************************)
Terminating == /\ used = Refs 
              /\ \A n \in Nodes : local[n] = {}
              /\ UNCHANGED vars

(***************************************************************************)
(* Next Action can be either tracking or untracking a valid ref on a valid *)
(* node, or we're terminating                                              *)
(***************************************************************************)
Next == 
     \/ \E n \in Nodes, r \in Refs : Track(n, r) \/ Untrack(n, r)
     \/ Terminating

PresenceSpec == Init /\ [][Next]_vars

OwnedOnce == 
  \A n, m \in Nodes : n /= m => local[n] \cap local[m] = {}


THEOREM PresenceSpec => [](TypeOK /\ OwnedOnce)

==========================================
