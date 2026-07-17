------------------------------ MODULE Muster2Multi ------------------------------
(*****************************************************************************)
(* MODULE Muster2 (the shipped B1 two-phase view-adoption fix) generalized   *)
(* from ONE group to MANY (caveat 2). This is the multi-group model.          *)
(*                                                                           *)
(* WHY MULTI-GROUP IS A DISTINCT CONCERN (not covered by Muster2Ring's        *)
(* relabeling argument). The single-group relabeling proof shows the router   *)
(* order is WLOG *for one group* because node ids are compared only inside    *)
(* Router. With several groups, real consistent hashing routes DIFFERENT      *)
(* groups to DIFFERENT nodes UNDER THE SAME VIEW -- there is no single total  *)
(* order to relabel to. This model gives each group its own ring order        *)
(* (RingRank[g]) so that, e.g., under view {1,2,3} group "a" routes to node 1 *)
(* and group "b" routes to node 3. It then asks the same question per group:  *)
(*   does the B1 gate still close Finding A for EVERY group simultaneously?   *)
(*                                                                           *)
(* WHAT IS PER-GROUP vs SHARED (faithful to the code):                        *)
(*   * SHARED (node / cluster-view level, group-independent):                 *)
(*       view[n]      committed routing view (the ring all shards read)       *)
(*       round[n]     the B1 prepare round -- a VIEW transition affects every *)
(*                    group the node holds at once (do_rebalance re-routes    *)
(*                    all groups on one view swap)                            *)
(*       mv[r][s]     member_views -- agreement about the cluster VIEW, not   *)
(*                    about any one group                                     *)
(*       owed[s]      owed_snapshots -- per-{holder,router}: one rebalance     *)
(*                    snapshot to r batches EVERY group s holds routing to r  *)
(*       seqCtr[n]    next_seq() is ONE monotonic counter per node, shared    *)
(*                    across groups (the occ register is keyed per            *)
(*                    {group,source} but the seq values come from this        *)
(*                    single counter)                                        *)
(*       Ready/CanDecide  status :ready + view_hash agreement -- per node,    *)
(*                    NOT per group                                          *)
(*   * PER-GROUP:                                                             *)
(*       holds[n][g]  n has >=1 local member of g                             *)
(*       occ[r][g][s] r's occupancy register for {group g, source s}          *)
(*                                                                           *)
(* NEW multi-group machinery exercised here (the caveat-2 targets):           *)
(*   1. per-group-different router order (RingRank[g]);                        *)
(*   2. a rebalance snapshot carries the SET of groups s holds that route to  *)
(*      r (SendSnapshot / DeliverSnapshot over `gs`) -- the batched-snapshot   *)
(*      set logic;                                                            *)
(*   3. Commit / DetectDown re-assert self rows for EVERY held group now       *)
(*      routing to self on the new view (do_rebalance's per-group self-upsert *)
(*      loop); DetectDown wipes the dead peer's rows in ALL groups.           *)
(*                                                                           *)
(* Setting Groups to a singleton and RingRank[g] = identity recovers exactly  *)
(* MODULE Muster2.                                                            *)
(*****************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS Nodes, Groups, MaxSeq, RingRank
ASSUME MaxSeq \in Nat
\* RingRank[g] is an injective ranking of Nodes (a total order per group).
\* Router of g = the minimum-rank present node for THAT group's order.
ASSUME RingRank \in [Groups -> [Nodes -> Nat]]
ASSUME \A g \in Groups : \A a, b \in Nodes :
          (a # b) => RingRank[g][a] # RingRank[g][b]
NoSeq == 0

\* Concrete diverging ring orders (cfg picks one via `RingRank <- ...`). Group
\* "a" uses identity (routes to min); group "b" uses the reverse (routes to
\* max). So under a shared view the two groups route to OPPOSITE ends of the
\* cluster -- the whole point of the multi-group model.
RingDiverge3 ==
  ( "a" :> (1 :> 1 @@ 2 :> 2 @@ 3 :> 3) )
  @@
  ( "b" :> (1 :> 3 @@ 2 :> 2 @@ 3 :> 1) )

VARIABLES
  up, holds, view, round, occ, mv, owed, seqCtr, msgs

vars == <<up, holds, view, round, occ, mv, owed, seqCtr, msgs>>

--------------------------------------------------------------------------------
Router(g, V) == CHOOSE n \in V : \A m \in V : RingRank[g][n] <= RingRank[g][m]

Ready(r) ==
  /\ view[r] # {}
  /\ \A m \in view[r] : \/ m = r
                        \/ /\ mv[r][m].known
                           /\ mv[r][m].hv = view[r]

CanDecide(r, senderView) == Ready(r) /\ view[r] = senderView
Present(r, g) == { s \in Nodes : occ[r][g][s].present }

CanBump(s) == seqCtr[s] < MaxSeq
Bump(s)    == seqCtr[s] + 1

Desired(n) == IF round[n].active THEN round[n].target ELSE view[n]

\* Does n hold any group that routes to r under view V?
HoldsForRouter(n, V, r) == \E g \in Groups : holds[n][g] /\ Router(g, V) = r
\* The set of groups n holds that route to r under view V (a snapshot's payload).
GroupsFor(n, V, r) == { g \in Groups : holds[n][g] /\ Router(g, V) = r }

PrepareMsg(s, r, tgt, q) ==
  [t |-> "prepare", src |-> s, dst |-> r, tgt |-> tgt, seq |-> q]
VacantMsg(s, r, g, q)     == [t |-> "vacant",   src |-> s, dst |-> r, grp |-> g, seq |-> q]
SnapshotMsg(s, r, gs, hv, q) == [t |-> "snapshot", src |-> s, dst |-> r, grps |-> gs, hv |-> hv, seq |-> q]
MarkerMsg(s, r, hv, q)    == [t |-> "marker",   src |-> s, dst |-> r, hv |-> hv, seq |-> q]

NoRound == [active |-> FALSE, target |-> {}, awaiting |-> {}, seq |-> NoSeq]

--------------------------------------------------------------------------------
Init ==
  /\ up     = [n \in Nodes |-> TRUE]
  /\ holds  = [n \in Nodes |-> [g \in Groups |-> FALSE]]
  /\ view   = [n \in Nodes |-> {n}]
  /\ round  = [n \in Nodes |-> NoRound]
  /\ occ    = [r \in Nodes |-> [g \in Groups |-> [s \in Nodes |->
                  [present |-> FALSE, seq |-> NoSeq]]]]
  /\ mv     = [r \in Nodes |-> [s \in Nodes |-> [known |-> FALSE, hv |-> {}, seq |-> NoSeq]]]
  /\ owed   = [n \in Nodes |-> {}]
  /\ seqCtr = [n \in Nodes |-> 0]
  /\ msgs   = {}

--------------------------------------------------------------------------------
(* Group-membership churn (per group). Becoming a holder is atomic with        *)
(* notifying that group's committed-view router.                               *)

HolderJoin(n, g) ==
  /\ up[n] /\ ~holds[n][g] /\ view[n] # {}
  /\ CanBump(n)
  /\ LET r == Router(g, view[n]) IN
       /\ holds' = [holds EXCEPT ![n][g] = TRUE]
       /\ seqCtr' = [seqCtr EXCEPT ![n] = Bump(n)]
       /\ occ' = [occ EXCEPT ![r][g][n] =
             IF Bump(n) > occ[r][g][n].seq THEN [present |-> TRUE, seq |-> Bump(n)]
             ELSE occ[r][g][n]]
  /\ UNCHANGED <<up, view, round, mv, owed, msgs>>

HolderLeave(n, g) ==
  /\ up[n] /\ holds[n][g] /\ view[n] # {}
  /\ CanBump(n)
  /\ holds' = [holds EXCEPT ![n][g] = FALSE]
  /\ seqCtr' = [seqCtr EXCEPT ![n] = Bump(n)]
  /\ LET r == Router(g, view[n]) IN
       IF r = n
       THEN /\ occ' = [occ EXCEPT ![n][g][n] =
                   IF Bump(n) >= occ[n][g][n].seq THEN [present |-> FALSE, seq |-> Bump(n)]
                   ELSE occ[n][g][n]]
            /\ UNCHANGED msgs
       ELSE /\ msgs' = msgs \cup {VacantMsg(n, r, g, Bump(n))}
            /\ UNCHANGED occ
  /\ UNCHANGED <<up, view, round, mv, owed>>

--------------------------------------------------------------------------------
(* Cluster-view churn. The prepare round is a VIEW transition -- group-        *)
(* independent (audience = old committed-view members, the only possible       *)
(* stale routers for ANY group across this transition).                        *)

Discover(n, m) ==
  /\ up[n] /\ up[m] /\ n # m
  /\ m \notin view[n]
  /\ m \notin Desired(n)
  /\ CanBump(n)
  /\ LET newTarget == Desired(n) \cup {m}
         audience  == view[n] \ {n}
     IN /\ seqCtr' = [seqCtr EXCEPT ![n] = Bump(n)]
        /\ round' = [round EXCEPT ![n] =
              [active |-> TRUE, target |-> newTarget, awaiting |-> audience, seq |-> Bump(n)]]
        /\ msgs' = msgs \cup
              { PrepareMsg(n, r, newTarget, Bump(n)) : r \in audience }
  /\ UNCHANGED <<up, holds, view, occ, mv, owed>>

DeliverPrepare(msg) ==
  /\ msg \in msgs /\ msg.t = "prepare"
  /\ mv' = [mv EXCEPT ![msg.dst][msg.src] =
        IF msg.seq > mv[msg.dst][msg.src].seq
        THEN [known |-> FALSE, hv |-> {}, seq |-> msg.seq]
        ELSE mv[msg.dst][msg.src]]
  /\ round' =
        IF /\ round[msg.src].active
           /\ round[msg.src].target = msg.tgt
           /\ round[msg.src].seq = msg.seq
        THEN [round EXCEPT ![msg.src].awaiting = round[msg.src].awaiting \ {msg.dst}]
        ELSE round
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<up, holds, view, occ, owed, seqCtr>>

\* Commit the grown view. do_rebalance re-asserts the local self row for EVERY
\* held group now routed to self, synchronously, before status leaves
\* :rebalancing. All such self rows are distinct {group,source=n} registers, so
\* asserting them at one shared bumped seq is faithful (per-register monotonicity
\* is all that matters; the relative order among a node's own groups never does).
Commit(n) ==
  /\ up[n]
  /\ round[n].active
  /\ round[n].awaiting = {}
  /\ LET target == round[n].target
         fold   == \E g \in Groups : holds[n][g] /\ Router(g, target) = n
     IN /\ (fold => CanBump(n))
        /\ view' = [view EXCEPT ![n] = target]
        /\ round' = [round EXCEPT ![n].active = FALSE]
        /\ occ' = [rr \in Nodes |-> [g \in Groups |-> [s \in Nodes |->
              IF rr = n /\ s = n /\ holds[n][g] /\ Router(g, target) = n
              THEN [present |-> TRUE, seq |-> Bump(n)]
              ELSE occ[rr][g][s]]]]
        /\ seqCtr' = IF fold THEN [seqCtr EXCEPT ![n] = Bump(n)] ELSE seqCtr
  /\ UNCHANGED <<up, holds, mv, owed, msgs>>

NodeDown(n) ==
  /\ up[n]
  /\ \E k \in Nodes : k # n /\ up[k]
  /\ up' = [up EXCEPT ![n] = FALSE]
  /\ UNCHANGED <<holds, view, round, occ, mv, owed, seqCtr, msgs>>

\* Detect a dead peer d: commit the shrink immediately. Wipe d's occupancy rows
\* in EVERY group and its member_views entry (un-readies us for any view with d),
\* prune d from an active round, and fold the per-group self re-assert for groups
\* we now route to ourselves on the shrunk view.
DetectDown(n, d) ==
  /\ up[n] /\ ~up[d] /\ n # d
  /\ d \in (view[n] \cup round[n].target \cup round[n].awaiting)
  /\ LET nv   == view[n] \ {d}
         fold == nv # {} /\ \E g \in Groups : holds[n][g] /\ Router(g, nv) = n
         nt   == round[n].target \ {d}
     IN /\ (fold => CanBump(n))
        /\ view' = [view EXCEPT ![n] = nv]
        /\ round' = [round EXCEPT ![n] =
              IF round[n].active /\ nt # nv
              THEN [active |-> TRUE, target |-> nt,
                    awaiting |-> round[n].awaiting \ {d}, seq |-> round[n].seq]
              ELSE NoRound]
        /\ occ' = [rr \in Nodes |-> [g \in Groups |-> [s \in Nodes |->
              IF rr = n /\ s = d
              THEN [present |-> FALSE, seq |-> NoSeq]
              ELSE IF rr = n /\ s = n /\ fold /\ holds[n][g] /\ Router(g, nv) = n
                   THEN [present |-> TRUE, seq |-> Bump(n)]
              ELSE occ[rr][g][s]]]]
        /\ seqCtr' = IF fold THEN [seqCtr EXCEPT ![n] = Bump(n)] ELSE seqCtr
  /\ mv'   = [mv EXCEPT ![n][d] = [known |-> FALSE, hv |-> {}, seq |-> NoSeq]]
  /\ owed' = [owed EXCEPT ![n] = owed[n] \ {d}]
  /\ UNCHANGED <<up, holds, msgs>>

--------------------------------------------------------------------------------
(* Post-commit re-announce. A snapshot to r batches every group s holds that   *)
(* routes to r (do_rebalance sends one snapshot per target router covering all  *)
(* its groups); a bare marker carries only the view agreement.                 *)

SelfClaim(s, g) ==
  /\ up[s] /\ holds[s][g] /\ view[s] # {}
  /\ Router(g, view[s]) = s
  /\ CanBump(s)
  /\ seqCtr' = [seqCtr EXCEPT ![s] = Bump(s)]
  /\ occ' = [occ EXCEPT ![s][g][s] =
        IF Bump(s) > occ[s][g][s].seq THEN [present |-> TRUE, seq |-> Bump(s)]
        ELSE occ[s][g][s]]
  /\ UNCHANGED <<up, holds, view, round, mv, owed, msgs>>

SendSnapshot(s, r) ==
  /\ up[s] /\ view[s] # {}
  /\ ~round[s].active   \* in transition: assert nothing until committed
  /\ r \in view[s] /\ r # s
  /\ GroupsFor(s, view[s], r) # {}   \* something to snapshot (>=1 held group routes to r)
  /\ CanBump(s)
  /\ seqCtr' = [seqCtr EXCEPT ![s] = Bump(s)]
  /\ owed' = [owed EXCEPT ![s] = owed[s] \cup {r}]
  /\ msgs' = msgs \cup {SnapshotMsg(s, r, GroupsFor(s, view[s], r), view[s], Bump(s))}
  /\ UNCHANGED <<up, holds, view, round, occ, mv>>

SendMarker(s, m) ==
  /\ up[s] /\ view[s] # {}
  /\ ~round[s].active   \* in transition: assert nothing until committed
  /\ m \in view[s] /\ m # s
  /\ m \notin owed[s]
  /\ ~HoldsForRouter(s, view[s], m)   \* if we hold a group routing to m we owe it a snapshot, not a bare marker
  /\ CanBump(s)
  /\ seqCtr' = [seqCtr EXCEPT ![s] = Bump(s)]
  /\ msgs' = msgs \cup {MarkerMsg(s, m, view[s], Bump(s))}
  /\ UNCHANGED <<up, holds, view, round, occ, mv, owed>>

--------------------------------------------------------------------------------
DeliverVacant(msg) ==
  /\ msg \in msgs /\ msg.t = "vacant"
  /\ occ' = [occ EXCEPT ![msg.dst][msg.grp][msg.src] =
        IF msg.seq >= occ[msg.dst][msg.grp][msg.src].seq
        THEN [present |-> FALSE, seq |-> msg.seq]
        ELSE occ[msg.dst][msg.grp][msg.src]]
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<up, holds, view, round, mv, owed, seqCtr>>

\* A rebalance snapshot: assert present (seq-guarded) for every group it carries,
\* AND record the sender's view agreement (mv). owed cleared once it lands.
DeliverSnapshot(msg) ==
  /\ msg \in msgs /\ msg.t = "snapshot"
  /\ occ' = [rr \in Nodes |-> [g \in Groups |-> [s \in Nodes |->
        IF rr = msg.dst /\ s = msg.src /\ g \in msg.grps /\ msg.seq > occ[rr][g][s].seq
        THEN [present |-> TRUE, seq |-> msg.seq]
        ELSE occ[rr][g][s]]]]
  /\ mv'  = [mv EXCEPT ![msg.dst][msg.src] =
        IF msg.seq > mv[msg.dst][msg.src].seq
        THEN [known |-> TRUE, hv |-> msg.hv, seq |-> msg.seq]
        ELSE mv[msg.dst][msg.src]]
  /\ owed' = [owed EXCEPT ![msg.src] = owed[msg.src] \ {msg.dst}]
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<up, holds, view, round, seqCtr>>

DeliverMarker(msg) ==
  /\ msg \in msgs /\ msg.t = "marker"
  /\ mv' = [mv EXCEPT ![msg.dst][msg.src] =
        IF msg.seq > mv[msg.dst][msg.src].seq
        THEN [known |-> TRUE, hv |-> msg.hv, seq |-> msg.seq]
        ELSE mv[msg.dst][msg.src]]
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<up, holds, view, round, occ, owed, seqCtr>>

--------------------------------------------------------------------------------
Next ==
  \/ \E n \in Nodes, g \in Groups : HolderJoin(n, g)
  \/ \E n \in Nodes, g \in Groups : HolderLeave(n, g)
  \/ \E n, m \in Nodes : Discover(n, m)
  \/ \E n \in Nodes : Commit(n)
  \/ \E n \in Nodes : NodeDown(n)
  \/ \E n, d \in Nodes : DetectDown(n, d)
  \/ \E s \in Nodes, g \in Groups : SelfClaim(s, g)
  \/ \E s, r \in Nodes : SendSnapshot(s, r)
  \/ \E s, m \in Nodes : SendMarker(s, m)
  \/ \E msg \in msgs : DeliverPrepare(msg)
  \/ \E msg \in msgs : DeliverVacant(msg)
  \/ \E msg \in msgs : DeliverSnapshot(msg)
  \/ \E msg \in msgs : DeliverMarker(msg)

Spec == Init /\ [][Next]_vars

--------------------------------------------------------------------------------
TypeOK ==
  /\ up \in [Nodes -> BOOLEAN]
  /\ holds \in [Nodes -> [Groups -> BOOLEAN]]
  /\ view \in [Nodes -> SUBSET Nodes]
  /\ seqCtr \in [Nodes -> 0..MaxSeq]
  /\ owed \in [Nodes -> SUBSET Nodes]

\* NoMissedDelivery, PER GROUP: for every group g and every live sender u whose
\* view routes g to a router r that may trust its table, every live holder s of g
\* in the shared view is in r's delivery set for g.
NoMissedDelivery ==
  \A g \in Groups :
    \A u \in Nodes :
      \A r \in Nodes :
        ( /\ up[u] /\ up[r]
          /\ view[u] # {}
          /\ Router(g, view[u]) = r
          /\ CanDecide(r, view[u]) )
        => \A s \in Nodes :
              ( /\ up[s] /\ holds[s][g]
                /\ s \in view[r] )
              => s \in Present(r, g)

--------------------------------------------------------------------------------
(* Non-vacuity witnesses (invariants we EXPECT TLC to VIOLATE; a reported      *)
(* violation is the WITNESS that the search reached the state that makes the    *)
(* multi-group safety run meaningful). Run one at a time.                       *)

\* W1: a READY router's committed multi-node view routes two groups to DIFFERENT
\* nodes. Violation => per-group router DIVERGENCE is actually reached in a state
\* where routing decisions are trusted -- the crux of the multi-group concern.
NoDivergentReadyRouter ==
  ~ (\E r \in Nodes, g1, g2 \in Groups :
        /\ up[r] /\ Ready(r) /\ Cardinality(view[r]) >= 2
        /\ Router(g1, view[r]) # Router(g2, view[r]))

\* W2: two different live nodes are simultaneously holding two different groups.
\* Violation => the search reaches genuinely concurrent multi-group occupancy
\* (not just one group at a time).
NoMultiGroupHold ==
  ~ (\E a, b \in Nodes, g1, g2 \in Groups :
        a # b /\ g1 # g2 /\ up[a] /\ up[b] /\ holds[a][g1] /\ holds[b][g2])

\* W3: a lagging :ready router (Ready, routes some group's view to itself) with a
\* strictly-more-advanced live peer AND a live holder of a group somewhere -- the
\* Finding-A shape, now in the multi-group setting.
NoLaggingReadyRouter ==
  ~ (\E r, a \in Nodes, g \in Groups :
        /\ r # a /\ up[r] /\ up[a]
        /\ Ready(r) /\ Router(g, view[r]) = r
        /\ view[r] \subseteq view[a] /\ view[r] # view[a])

\* Optional state-space bound for deeper/looser searches.
MsgBound == Cardinality(msgs) <= 3

================================================================================
