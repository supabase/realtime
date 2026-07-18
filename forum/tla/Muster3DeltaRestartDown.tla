------------------------- MODULE Muster3DeltaRestartDown -----------------------
(*****************************************************************************)
(* CAVEAT-7 COMPOSITION #2: the occupancy GC sweep x the multi-group delta    *)
(* selection x the (Finding-B-corrected) coordinator restart.                 *)
(*                                                                           *)
(* MODULE Muster2DeltaRestartDown, verbatim, PLUS the Muster3 DropStale/Reap  *)
(* mechanisms lifted to per-group rows. This checks the sweep against the two *)
(* mechanisms it was never composed with (TLA_FINDINGS caveat 7):             *)
(*                                                                           *)
(*   * SWEEP x DELTA. The add-only delta path is correct only if the receiver *)
(*     keeps its "previous-generation baseline" -- every group the source     *)
(*     holds routing to it that did not move this round. The sweep is the ONE *)
(*     mechanism that removes rows without a message from the source. The     *)
(*     informal fail-safe argument: a baseline group by definition ROUTES TO  *)
(*     the receiver, so the sweep's routes-away guard spares it. But the      *)
(*     guard judges under the RECEIVER's committed view while the source      *)
(*     computes the delta under ITS OWN ring generations -- when the views     *)
(*     diverge mid-churn, SourceAgrees is supposed to make the judge abstain. *)
(*     That interplay (per-group routes-away x view-level agreement x the     *)
(*     wholesale applied_snapshot_seq watermark) is what NoMissedDelivery     *)
(*     checks here.                                                           *)
(*                                                                           *)
(*   * SWEEP x RESTART, in the multi-group setting: the restart wipes the     *)
(*     member_views agreement SourceAgrees reads (fail-safe direction: no     *)
(*     agreement => no sweep) and resets appliedSeq while the swept/reaped    *)
(*     occupancy table SURVIVES -- so post-restart, tombstones and reaped     *)
(*     keys from the OLD incarnation's sweeps meet a wiped watermark. The     *)
(*     single-group deep-dive is MODULE Muster3RestartDown; this module adds  *)
(*     the delta dimension.                                                   *)
(*                                                                           *)
(* Sweep faithfulness notes (see MODULE Muster3's header for the judge/write  *)
(* race argument, unchanged): drop_stale_router_entries judges PER ROW        *)
(* ({group, source}): meta == :present AND source_agrees?(source, row_seq)    *)
(* AND find_node(group) != self. source_agrees? is per SOURCE (the announced  *)
(* view matches ours and row_seq <= the announcement watermark; own rows      *)
(* always agree) -- scope.ex ~L1369-1449. reap_tombstones hard-deletes a      *)
(* tombstone after the retention window; modeled as quiescence of the         *)
(* {router,source} pair, exactly as in Muster3.                               *)
(*                                                                           *)
(* History var (probes only): everSwept[r] -- set once a DropStale fires on   *)
(* router r's table.                                                          *)
(*****************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS Nodes, Groups, MaxSeq, RingRank
ASSUME MaxSeq \in Nat
ASSUME RingRank \in [Groups -> [Nodes -> Nat]]
ASSUME \A g \in Groups : \A a, b \in Nodes :
          (a # b) => RingRank[g][a] # RingRank[g][b]
NoSeq == 0

\* Diverging ring orders: group "a" routes to min, group "b" to max.
RingDiverge3 ==
  ( "a" :> (1 :> 1 @@ 2 :> 2 @@ 3 :> 3) )
  @@
  ( "b" :> (1 :> 3 @@ 2 :> 2 @@ 3 :> 1) )

VARIABLES
  up, holds, view, round, occ, mv, owed, seqCtr, msgs, appliedSeq,
  promoted,        \* restart analog of the B1 gate: FALSE right after a restart
  everRestarted,   \* history var (probes only): set once by Restart
  everSwept        \* history var (probes only): set once by DropStale on r

vars == <<up, holds, view, round, occ, mv, owed, seqCtr, msgs, appliedSeq,
          promoted, everRestarted, everSwept>>

--------------------------------------------------------------------------------
Router(g, V) == CHOOSE n \in V : \A m \in V : RingRank[g][n] <= RingRank[g][m]

\* Ready with the restart singleton clause: a SINGLETON view {r} is trusted only
\* once promoted (a freshly restarted node floods even as a singleton).
Ready(r) ==
  /\ view[r] # {}
  /\ \A m \in view[r] : \/ m = r
                        \/ /\ mv[r][m].known
                           /\ mv[r][m].hv = view[r]
  /\ (view[r] = {r} => promoted[r])

CanDecide(r, senderView) == Ready(r) /\ view[r] = senderView
Present(r, g) == { s \in Nodes : occ[r][g][s].present }

CanBump(s) == seqCtr[s] < MaxSeq
Bump(s)    == seqCtr[s] + 1

Desired(n) == IF round[n].active THEN round[n].target ELSE view[n]

HoldsForRouter(n, V, r) == \E g \in Groups : holds[n][g] /\ Router(g, V) = r

--------------------------------------------------------------------------------
(* Rebalance-snapshot SELECTION (do_rebalance, scope.ex ~L1112-1169). *)

AllHeldTo(n, newV, r) == { g \in Groups : holds[n][g] /\ Router(g, newV) = r }

MovedIn(n, oldV, newV, r) ==
  { g \in Groups : /\ holds[n][g]
                   /\ Router(g, newV) = r
                   /\ Router(g, oldV) # r }

ChangedRouters(n, oldV, newV) ==
  { r \in newV : r # n /\ MovedIn(n, oldV, newV, r) # {} }

IsFull(n, oldV, r, owedSet) == (r \notin oldV) \/ (r \in owedSet)

SnapKind(n, oldV, r, owedSet) == IF IsFull(n, oldV, r, owedSet) THEN "full" ELSE "delta"

SnapPayload(n, oldV, newV, r, owedSet) ==
  IF IsFull(n, oldV, r, owedSet) THEN AllHeldTo(n, newV, r)
                                 ELSE MovedIn(n, oldV, newV, r)

SnapshotMsg(s, r, gs, kind, hv, q) ==
  [t |-> "snapshot", src |-> s, dst |-> r, grps |-> gs, kind |-> kind, hv |-> hv, seq |-> q]

SnapMsgs(n, oldV, newV, owedSet, q) ==
  { SnapshotMsg(n, r,
                SnapPayload(n, oldV, newV, r, owedSet),
                SnapKind(n, oldV, r, owedSet),
                newV, q)
      : r \in ChangedRouters(n, oldV, newV) }

PrepareMsg(s, r, tgt, q) ==
  [t |-> "prepare", src |-> s, dst |-> r, tgt |-> tgt, seq |-> q]
VacantMsg(s, r, g, q)  == [t |-> "vacant", src |-> s, dst |-> r, grp |-> g, seq |-> q]
MarkerMsg(s, r, hv, q) == [t |-> "marker", src |-> s, dst |-> r, hv |-> hv, seq |-> q]

NoRound == [active |-> FALSE, target |-> {}, awaiting |-> {}, seq |-> NoSeq]
BlankMV == [known |-> FALSE, hv |-> {}, seq |-> NoSeq]

--------------------------------------------------------------------------------
Init ==
  /\ up     = [n \in Nodes |-> TRUE]
  /\ holds  = [n \in Nodes |-> [g \in Groups |-> FALSE]]
  /\ view   = [n \in Nodes |-> {n}]
  /\ round  = [n \in Nodes |-> NoRound]
  /\ occ    = [r \in Nodes |-> [g \in Groups |-> [s \in Nodes |->
                  [present |-> FALSE, seq |-> NoSeq]]]]
  /\ mv     = [r \in Nodes |-> [s \in Nodes |-> BlankMV]]
  /\ owed   = [n \in Nodes |-> {}]
  /\ seqCtr = [n \in Nodes |-> 0]
  /\ msgs   = {}
  /\ appliedSeq = [r \in Nodes |-> [s \in Nodes |-> NoSeq]]
  /\ promoted = [n \in Nodes |-> TRUE]
  /\ everRestarted = [n \in Nodes |-> FALSE]
  /\ everSwept = [n \in Nodes |-> FALSE]

--------------------------------------------------------------------------------
(* Group-membership churn. *)

HolderJoin(n, g) ==
  /\ up[n] /\ ~holds[n][g] /\ view[n] # {}
  /\ CanBump(n)
  /\ LET r == Router(g, view[n]) IN
       /\ holds' = [holds EXCEPT ![n][g] = TRUE]
       /\ seqCtr' = [seqCtr EXCEPT ![n] = Bump(n)]
       /\ occ' = [occ EXCEPT ![r][g][n] =
             IF Bump(n) > occ[r][g][n].seq THEN [present |-> TRUE, seq |-> Bump(n)]
             ELSE occ[r][g][n]]
  /\ UNCHANGED <<up, view, round, mv, owed, msgs, appliedSeq, promoted,
                 everRestarted, everSwept>>

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
  /\ UNCHANGED <<up, view, round, mv, owed, appliedSeq, promoted,
                 everRestarted, everSwept>>

--------------------------------------------------------------------------------
(* Cluster-view churn: the B1 prepare round (group-independent) + commit. *)

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
  /\ UNCHANGED <<up, holds, view, occ, mv, owed, appliedSeq, promoted,
                 everRestarted, everSwept>>

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
  /\ UNCHANGED <<up, holds, view, occ, owed, seqCtr, appliedSeq, promoted,
                 everRestarted, everSwept>>

\* Commit the grown view; emit per-router full/delta snapshots. Establishing a
\* committed view promotes the node (it is no longer a fresh converging singleton).
Commit(n) ==
  /\ up[n]
  /\ round[n].active
  /\ round[n].awaiting = {}
  /\ LET target   == round[n].target
         oldV     == view[n]
         selfFold == \E g \in Groups : holds[n][g] /\ Router(g, target) = n
         emitR    == ChangedRouters(n, oldV, target)
         needSeq  == selfFold \/ emitR # {}
     IN /\ (needSeq => CanBump(n))
        /\ view' = [view EXCEPT ![n] = target]
        /\ round' = [round EXCEPT ![n].active = FALSE]
        /\ occ' = [rr \in Nodes |-> [g \in Groups |-> [s \in Nodes |->
              IF rr = n /\ s = n /\ holds[n][g] /\ Router(g, target) = n
              THEN [present |-> TRUE, seq |-> Bump(n)]
              ELSE occ[rr][g][s]]]]
        /\ seqCtr' = IF needSeq THEN [seqCtr EXCEPT ![n] = Bump(n)] ELSE seqCtr
        /\ msgs' = msgs \cup SnapMsgs(n, oldV, target, owed[n], Bump(n))
        /\ owed' = [owed EXCEPT ![n] = (owed[n] \cup emitR) \cap target]
  /\ promoted' = [promoted EXCEPT ![n] = TRUE]
  /\ UNCHANGED <<up, holds, mv, appliedSeq, everRestarted, everSwept>>

NodeDown(n) ==
  /\ up[n]
  /\ \E k \in Nodes : k # n /\ up[k]
  /\ up' = [up EXCEPT ![n] = FALSE]
  /\ UNCHANGED <<holds, view, round, occ, mv, owed, seqCtr, msgs, appliedSeq,
                 promoted, everRestarted, everSwept>>

\* Detect a dead peer d: commit the shrink immediately; wipe d's rows + mv,
\* prune d from an active round, self-fold, re-announce moved groups (full/delta).
\* Establishing the shrunk view promotes n.
DetectDown(n, d) ==
  /\ up[n] /\ ~up[d] /\ n # d
  /\ d \in (view[n] \cup round[n].target \cup round[n].awaiting)
  /\ LET oldV     == view[n]
         nv       == view[n] \ {d}
         selfFold == nv # {} /\ \E g \in Groups : holds[n][g] /\ Router(g, nv) = n
         emitR    == IF nv = {} THEN {} ELSE ChangedRouters(n, oldV, nv)
         needSeq  == selfFold \/ emitR # {}
         nt       == round[n].target \ {d}
     IN /\ (needSeq => CanBump(n))
        /\ view' = [view EXCEPT ![n] = nv]
        /\ round' = [round EXCEPT ![n] =
              IF round[n].active /\ nt # nv
              THEN [active |-> TRUE, target |-> nt,
                    awaiting |-> round[n].awaiting \ {d}, seq |-> round[n].seq]
              ELSE NoRound]
        /\ occ' = [rr \in Nodes |-> [g \in Groups |-> [s \in Nodes |->
              IF rr = n /\ s = d
              THEN [present |-> FALSE, seq |-> NoSeq]
              ELSE IF rr = n /\ s = n /\ selfFold /\ holds[n][g] /\ Router(g, nv) = n
                   THEN [present |-> TRUE, seq |-> Bump(n)]
              ELSE occ[rr][g][s]]]]
        /\ seqCtr' = IF needSeq THEN [seqCtr EXCEPT ![n] = Bump(n)] ELSE seqCtr
        /\ msgs' = msgs \cup (IF nv = {} THEN {} ELSE SnapMsgs(n, oldV, nv, owed[n], Bump(n)))
        /\ owed' = [owed EXCEPT ![n] = (owed[n] \cup emitR) \cap nv]
  /\ mv'   = [mv EXCEPT ![n][d] = BlankMV]
  /\ promoted' = [promoted EXCEPT ![n] = TRUE]
  /\ UNCHANGED <<up, holds, appliedSeq, everRestarted, everSwept>>

--------------------------------------------------------------------------------
(* THE RESTART, verbatim from Muster2DeltaRestartDown (peer-side :DOWN blanks   *)
(* mv[p][n]; old-incarnation in-flight messages dropped, FIFO-faithfully; occ   *)
(* survives; appliedSeq wiped; start :converging).                              *)

Restart(n) ==
  /\ up[n]
  /\ CanBump(n)                          \* init consumes a seq (view_seq watermark)
  /\ view'  = [view  EXCEPT ![n] = {n}]  \* ring reset to [node()]
  /\ round' = [round EXCEPT ![n] = NoRound]                  \* pending_round cleared
  /\ mv'    = [p \in Nodes |->
                 IF p = n THEN [s \in Nodes |-> BlankMV]
                 ELSE [mv[p] EXCEPT ![n] = BlankMV]]
  /\ owed'  = [owed  EXCEPT ![n] = {}]                       \* owed_snapshots cleared
  /\ appliedSeq' = [appliedSeq EXCEPT ![n] = [s \in Nodes |-> NoSeq]]
  /\ promoted' = [promoted EXCEPT ![n] = FALSE]              \* start :converging
  /\ seqCtr' = [seqCtr EXCEPT ![n] = Bump(n)]
  /\ occ' = [occ EXCEPT ![n] = [g \in Groups |-> [s \in Nodes |->
        IF s = n /\ holds[n][g] /\ Bump(n) > occ[n][g][s].seq
        THEN [present |-> TRUE, seq |-> Bump(n)]
        ELSE occ[n][g][s]]]]
  /\ everRestarted' = [everRestarted EXCEPT ![n] = TRUE]
  /\ msgs' = { m \in msgs : m.src # n }
  /\ UNCHANGED <<up, holds, everSwept>>

SingletonPromote(n) ==
  /\ up[n]
  /\ ~promoted[n]
  /\ view[n] = {n}
  /\ promoted' = [promoted EXCEPT ![n] = TRUE]
  /\ UNCHANGED <<up, holds, view, round, occ, mv, owed, seqCtr, msgs, appliedSeq,
                 everRestarted, everSwept>>

--------------------------------------------------------------------------------
(* Steady-state re-assert / heartbeat (no view change). *)

SelfClaim(s, g) ==
  /\ up[s] /\ holds[s][g] /\ view[s] # {}
  /\ Router(g, view[s]) = s
  /\ CanBump(s)
  /\ seqCtr' = [seqCtr EXCEPT ![s] = Bump(s)]
  /\ occ' = [occ EXCEPT ![s][g][s] =
        IF Bump(s) > occ[s][g][s].seq THEN [present |-> TRUE, seq |-> Bump(s)]
        ELSE occ[s][g][s]]
  /\ UNCHANGED <<up, holds, view, round, mv, owed, msgs, appliedSeq,
                 promoted, everRestarted, everSwept>>

SendMarker(s, m) ==
  /\ up[s] /\ view[s] # {}
  /\ ~round[s].active
  /\ m \in view[s] /\ m # s
  /\ m \notin owed[s]
  /\ ~HoldsForRouter(s, view[s], m)
  /\ CanBump(s)
  /\ seqCtr' = [seqCtr EXCEPT ![s] = Bump(s)]
  /\ msgs' = msgs \cup {MarkerMsg(s, m, view[s], Bump(s))}
  /\ UNCHANGED <<up, holds, view, round, occ, mv, owed, appliedSeq,
                 promoted, everRestarted, everSwept>>

--------------------------------------------------------------------------------
DeliverVacant(msg) ==
  /\ msg \in msgs /\ msg.t = "vacant"
  /\ occ' = [occ EXCEPT ![msg.dst][msg.grp][msg.src] =
        IF msg.seq >= occ[msg.dst][msg.grp][msg.src].seq
        THEN [present |-> FALSE, seq |-> msg.seq]
        ELSE occ[msg.dst][msg.grp][msg.src]]
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<up, holds, view, round, mv, owed, seqCtr, appliedSeq,
                 promoted, everRestarted, everSwept>>

\* Apply a rebalance snapshot (full or delta). WHOLESALE per-source seq guard;
\* FULL wipes non-payload predating rows; DELTA never wipes. (See Muster2Delta.)
DeliverSnapshot(msg) ==
  /\ msg \in msgs /\ msg.t = "snapshot"
  /\ LET r == msg.dst
         s == msg.src
     IN IF msg.seq <= appliedSeq[r][s]
        THEN /\ msgs' = msgs \ {msg}
             /\ UNCHANGED <<up, holds, view, round, occ, mv, owed, seqCtr,
                            appliedSeq, promoted, everRestarted, everSwept>>
        ELSE /\ occ' = [rr \in Nodes |-> [g \in Groups |-> [src \in Nodes |->
                   IF rr = r /\ src = s
                   THEN IF g \in msg.grps /\ msg.seq > occ[rr][g][src].seq
                        THEN [present |-> TRUE, seq |-> msg.seq]
                        ELSE IF msg.kind = "full"
                                /\ g \notin msg.grps
                                /\ occ[rr][g][src].seq < msg.seq
                             THEN [present |-> FALSE, seq |-> msg.seq]
                             ELSE occ[rr][g][src]
                   ELSE occ[rr][g][src]]]]
             /\ appliedSeq' = [appliedSeq EXCEPT ![r][s] = msg.seq]
             /\ mv' = [mv EXCEPT ![r][s] =
                   IF msg.seq > mv[r][s].seq
                   THEN [known |-> TRUE, hv |-> msg.hv, seq |-> msg.seq]
                   ELSE mv[r][s]]
             /\ owed' = [owed EXCEPT ![s] = owed[s] \ {r}]
             /\ msgs' = msgs \ {msg}
             /\ UNCHANGED <<up, holds, view, round, seqCtr, promoted,
                            everRestarted, everSwept>>

DeliverMarker(msg) ==
  /\ msg \in msgs /\ msg.t = "marker"
  /\ mv' = [mv EXCEPT ![msg.dst][msg.src] =
        IF msg.seq > mv[msg.dst][msg.src].seq
        THEN [known |-> TRUE, hv |-> msg.hv, seq |-> msg.seq]
        ELSE mv[msg.dst][msg.src]]
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<up, holds, view, round, occ, owed, seqCtr, appliedSeq,
                 promoted, everRestarted, everSwept>>

--------------------------------------------------------------------------------
(* NEW HERE: the GC sweep + tombstone reap (Muster3), lifted to per-group rows. *)

\* source_agrees?/3: own rows always judgeable; a peer's row only once the peer
\* has announced OUR committed view AND the row's seq does not exceed the
\* watermark carried by that announcement.
SourceAgrees(r, s, rowSeq) ==
  \/ s = r
  \/ /\ mv[r][s].known
     /\ mv[r][s].hv = view[r]
     /\ rowSeq <= mv[r][s].seq

\* drop_stale_router_entries: downgrade a :present row to a TOMBSTONE at its
\* EXISTING seq when the source agrees with our committed view and THE GROUP no
\* longer routes to us under that view (the judge is per {group, source} row;
\* agreement is per source). Atomic == faithful (see Muster3's header).
DropStale(r, g, s) ==
  /\ up[r]
  /\ view[r] # {}
  /\ occ[r][g][s].present
  /\ Router(g, view[r]) # r
  /\ SourceAgrees(r, s, occ[r][g][s].seq)
  /\ occ' = [occ EXCEPT ![r][g][s] = [present |-> FALSE, seq |-> occ[r][g][s].seq]]
  /\ everSwept' = [everSwept EXCEPT ![r] = TRUE]
  /\ UNCHANGED <<up, holds, view, round, mv, owed, seqCtr, msgs, appliedSeq,
                 promoted, everRestarted>>

\* reap_tombstones: hard-delete a tombstone back to truly-absent, only once the
\* {router,source} pair is QUIESCENT (retention window outlasts every orphaned
\* RPC -- see Muster3).
Reap(r, g, s) ==
  /\ ~occ[r][g][s].present
  /\ occ[r][g][s].seq # NoSeq
  /\ \A m \in msgs : ~(m.dst = r /\ m.src = s)
  /\ occ' = [occ EXCEPT ![r][g][s] = [present |-> FALSE, seq |-> NoSeq]]
  /\ UNCHANGED <<up, holds, view, round, mv, owed, seqCtr, msgs, appliedSeq,
                 promoted, everRestarted, everSwept>>

--------------------------------------------------------------------------------
Next ==
  \/ \E n \in Nodes, g \in Groups : HolderJoin(n, g)
  \/ \E n \in Nodes, g \in Groups : HolderLeave(n, g)
  \/ \E n, m \in Nodes : Discover(n, m)
  \/ \E n \in Nodes : Commit(n)
  \/ \E n \in Nodes : NodeDown(n)
  \/ \E n, d \in Nodes : DetectDown(n, d)
  \/ \E n \in Nodes : Restart(n)
  \/ \E n \in Nodes : SingletonPromote(n)
  \/ \E s \in Nodes, g \in Groups : SelfClaim(s, g)
  \/ \E s, m \in Nodes : SendMarker(s, m)
  \/ \E msg \in msgs : DeliverPrepare(msg)
  \/ \E msg \in msgs : DeliverVacant(msg)
  \/ \E msg \in msgs : DeliverSnapshot(msg)
  \/ \E msg \in msgs : DeliverMarker(msg)
  \/ \E r \in Nodes, g \in Groups, s \in Nodes : DropStale(r, g, s)
  \/ \E r \in Nodes, g \in Groups, s \in Nodes : Reap(r, g, s)

Spec == Init /\ [][Next]_vars

--------------------------------------------------------------------------------
TypeOK ==
  /\ up \in [Nodes -> BOOLEAN]
  /\ holds \in [Nodes -> [Groups -> BOOLEAN]]
  /\ view \in [Nodes -> SUBSET Nodes]
  /\ seqCtr \in [Nodes -> 0..MaxSeq]
  /\ owed \in [Nodes -> SUBSET Nodes]
  /\ appliedSeq \in [Nodes -> [Nodes -> 0..MaxSeq]]
  /\ promoted \in [Nodes -> BOOLEAN]
  /\ everRestarted \in [Nodes -> BOOLEAN]
  /\ everSwept \in [Nodes -> BOOLEAN]

\* NoMissedDelivery, PER GROUP (unchanged from Muster2Delta).
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
(* Non-vacuity probes (expect TLC to VIOLATE; a violation is the WITNESS that   *)
(* the sweep genuinely interacts with the delta/restart machinery).             *)

\* W1: some sweep fires at all.
NoSweepEver == ~(\E r \in Nodes : everSwept[r])

\* W2: a DELTA snapshot is in flight to a router that has already swept rows --
\* the add-only apply will land on a table the sweep has edited. (Delta is only
\* reachable at MaxSeq>=4; run under the _w2 cfg.) NOT surfaced within a
\* multi-minute MaxSeq=4 search (BFS depth 12) -- kept as a documented probe,
\* not a confirmed witness (same status as Muster2Delta's NoWholesaleDrop /
\* NoBaselineDelta).
NoDeltaToSweptRouter ==
  ~(\E m \in msgs :
      /\ m.t = "snapshot" /\ m.kind = "delta"
      /\ everSwept[m.dst])

\* W3: a DELTA snapshot is dispatched at all in this composition (the weaker,
\* confirmed witness that the MaxSeq=4 safety run covers the add-only path;
\* mirrors Muster2Delta's NoDeltaSent).
NoDeltaSent == ~(\E m \in msgs : m.t = "snapshot" /\ m.kind = "delta")

\* Optional state-space bound for deeper/looser searches.
MsgBound == Cardinality(msgs) <= 3

================================================================================
