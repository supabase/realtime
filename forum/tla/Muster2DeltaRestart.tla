--------------------------- MODULE Muster2DeltaRestart -------------------------
(*****************************************************************************)
(* MODULE Muster2Delta (multi-group + faithful delta-vs-full snapshot         *)
(* selection) COMPOSED with the coordinator RESTART action from               *)
(* MODULE Muster2Restart. This closes the one cross-mechanism interaction     *)
(* that neither predecessor checked: RESTART x DELTA.                          *)
(*                                                                           *)
(* WHY THIS COMPOSITION IS THE ONE WORTH CHECKING. Every add-on to the B1     *)
(* fix (Muster2) was verified in ISOLATION on top of Muster2: the GC sweep    *)
(* (Muster3), the coordinator restart (Muster2Restart), and multi-group +     *)
(* delta selection (Muster2Delta). The restart and the delta path are the     *)
(* one pair where one mechanism resets EXACTLY the state the other relies on: *)
(*                                                                           *)
(*   * The add-only DELTA path is correct ONLY IF the receiver already holds  *)
(*     the "previous-generation baseline" -- every group the source holds      *)
(*     routing to it that did NOT move this round. Muster2Delta shows the       *)
(*     owed_snapshots gate + the per-source wholesale watermark                *)
(*     (applied_snapshot_seq) preserve that baseline.                          *)
(*   * A RESTART wipes member_views, owed_snapshots AND applied_snapshot_seq   *)
(*     (all coordinator in-memory State, scope.ex ~L58-63), while the          *)
(*     occupancy ETS table SURVIVES (Forum.Supervisor-owned). So a restart     *)
(*     removes precisely the watermark/owed bookkeeping the delta path leans   *)
(*     on, but keeps the baseline rows themselves.                             *)
(*                                                                           *)
(* THE INTERACTION UNDER TEST. Two directions matter:                          *)
(*   (a) The restarted node n emits snapshots on re-pair. do_rebalance's       *)
(*       old_members is [node()] right after init, so every other router reads *)
(*       as "new" and n sends FULL snapshots (scope.ex ~L1150-1152). The claim *)
(*       "a restarted node re-announces FULL, never a delta off a phantom       *)
(*       baseline" is coded but never machine-checked in composition.          *)
(*   (b) A delta sent BY a peer s TO the restarted node n. s did not see n go   *)
(*       :DOWN (n stayed up), so s may still classify n as an old member it     *)
(*       does not owe -> s sends n a DELTA of only the moved-in groups. n's     *)
(*       occ rows for s SURVIVED the restart, so the baseline is intact -- but  *)
(*       n's appliedSeq[s] was WIPED to 0, so the wholesale stale-round guard   *)
(*       no longer pre-empts a reordered round. Does the surviving occ baseline *)
(*       + per-row seq guards still make the delta safe? That is exactly        *)
(*       NoMissedDelivery here.                                                 *)
(*                                                                           *)
(* FAITHFULNESS of Restart in the multi-group setting (extends Muster2Restart *)
(* to per-group occ + appliedSeq):                                             *)
(*   * view[n] := {n}; round[n] := NoRound; mv[n] := all-BlankMV;              *)
(*     owed[n] := {}; promoted[n] := FALSE (start :converging); one seq spent  *)
(*     (init's view_seq watermark).                                            *)
(*   * appliedSeq[n] := all NoSeq -- applied_snapshot_seq is coordinator State, *)
(*     lost on restart (THE new element vs Muster2Restart, which had no         *)
(*     watermark).                                                             *)
(*   * occ[n][g][s] RETAINED for every group g and source s (ETS survives);     *)
(*     self rows occ[n][g][n] re-asserted monotonically for locally-held        *)
(*     groups (reannounce_local_groups_at_init).                               *)
(*   * A restarted singleton is :converging until SingletonPromote / Commit /  *)
(*     DetectDown flips promoted -- the restart analog of the B1 gate.          *)
(*                                                                           *)
(* The GC sweep (Muster3 DropStale) is still omitted -- a sound OVER-           *)
(* approximation for under-delivery (not sweeping leaves MORE present rows).    *)
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
  everRestarted    \* history var (probe/non-vacuity only): set once by Restart

vars == <<up, holds, view, round, occ, mv, owed, seqCtr, msgs, appliedSeq,
          promoted, everRestarted>>

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
GroupsFor(n, V, r) == { g \in Groups : holds[n][g] /\ Router(g, V) = r }

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
  /\ UNCHANGED <<up, view, round, mv, owed, msgs, appliedSeq, promoted, everRestarted>>

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
  /\ UNCHANGED <<up, view, round, mv, owed, appliedSeq, promoted, everRestarted>>

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
  /\ UNCHANGED <<up, holds, view, occ, mv, owed, appliedSeq, promoted, everRestarted>>

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
  /\ UNCHANGED <<up, holds, view, occ, owed, seqCtr, appliedSeq, promoted, everRestarted>>

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
  /\ UNCHANGED <<up, holds, mv, appliedSeq, everRestarted>>

NodeDown(n) ==
  /\ up[n]
  /\ \E k \in Nodes : k # n /\ up[k]
  /\ up' = [up EXCEPT ![n] = FALSE]
  /\ UNCHANGED <<holds, view, round, occ, mv, owed, seqCtr, msgs, appliedSeq,
                 promoted, everRestarted>>

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
  /\ UNCHANGED <<up, holds, appliedSeq, everRestarted>>

--------------------------------------------------------------------------------
(* THE RESTART (multi-group + appliedSeq extension of Muster2Restart Restart). *)
(* The coordinator crashes (prepare/snapshot RPC to an up-but-unreachable peer  *)
(* failed) and the supervisor restarts it. The node stays UP -- peers see no    *)
(* :DOWN, so they keep their occ/mv rows for n and may still send n a DELTA.    *)

Restart(n) ==
  /\ up[n]
  /\ CanBump(n)                          \* init consumes a seq (view_seq watermark)
  /\ view'  = [view  EXCEPT ![n] = {n}]  \* ring reset to [node()]
  /\ round' = [round EXCEPT ![n] = NoRound]                  \* pending_round cleared
  /\ mv'    = [mv    EXCEPT ![n] = [s \in Nodes |-> BlankMV]] \* member_views wiped
  /\ owed'  = [owed  EXCEPT ![n] = {}]                       \* owed_snapshots cleared
  /\ appliedSeq' = [appliedSeq EXCEPT ![n] = [s \in Nodes |-> NoSeq]]
                                         \* applied_snapshot_seq is State -> WIPED
  /\ promoted' = [promoted EXCEPT ![n] = FALSE]              \* start :converging
  /\ seqCtr' = [seqCtr EXCEPT ![n] = Bump(n)]
  \* occ TABLE SURVIVES: retain every occ[n][g][s]; re-assert self rows
  \* monotonically for locally-held groups (reannounce_local_groups_at_init).
  /\ occ' = [occ EXCEPT ![n] = [g \in Groups |-> [s \in Nodes |->
        IF s = n /\ holds[n][g] /\ Bump(n) > occ[n][g][s].seq
        THEN [present |-> TRUE, seq |-> Bump(n)]
        ELSE occ[n][g][s]]]]
  /\ everRestarted' = [everRestarted EXCEPT ![n] = TRUE]
  /\ UNCHANGED <<up, holds, msgs>>

SingletonPromote(n) ==
  /\ up[n]
  /\ ~promoted[n]
  /\ view[n] = {n}
  /\ promoted' = [promoted EXCEPT ![n] = TRUE]
  /\ UNCHANGED <<up, holds, view, round, occ, mv, owed, seqCtr, msgs, appliedSeq,
                 everRestarted>>

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
                 promoted, everRestarted>>

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
                 promoted, everRestarted>>

--------------------------------------------------------------------------------
DeliverVacant(msg) ==
  /\ msg \in msgs /\ msg.t = "vacant"
  /\ occ' = [occ EXCEPT ![msg.dst][msg.grp][msg.src] =
        IF msg.seq >= occ[msg.dst][msg.grp][msg.src].seq
        THEN [present |-> FALSE, seq |-> msg.seq]
        ELSE occ[msg.dst][msg.grp][msg.src]]
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<up, holds, view, round, mv, owed, seqCtr, appliedSeq,
                 promoted, everRestarted>>

\* Apply a rebalance snapshot (full or delta). WHOLESALE per-source seq guard;
\* FULL wipes non-payload predating rows; DELTA never wipes. (See Muster2Delta.)
DeliverSnapshot(msg) ==
  /\ msg \in msgs /\ msg.t = "snapshot"
  /\ LET r == msg.dst
         s == msg.src
     IN IF msg.seq <= appliedSeq[r][s]
        THEN /\ msgs' = msgs \ {msg}
             /\ UNCHANGED <<up, holds, view, round, occ, mv, owed, seqCtr,
                            appliedSeq, promoted, everRestarted>>
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
             /\ UNCHANGED <<up, holds, view, round, seqCtr, promoted, everRestarted>>

DeliverMarker(msg) ==
  /\ msg \in msgs /\ msg.t = "marker"
  /\ mv' = [mv EXCEPT ![msg.dst][msg.src] =
        IF msg.seq > mv[msg.dst][msg.src].seq
        THEN [known |-> TRUE, hv |-> msg.hv, seq |-> msg.seq]
        ELSE mv[msg.dst][msg.src]]
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<up, holds, view, round, occ, owed, seqCtr, appliedSeq,
                 promoted, everRestarted>>

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
(* Non-vacuity witnesses (expect TLC to VIOLATE; a violation is the WITNESS      *)
(* that the restart x delta interaction is actually exercised). Run one at a     *)
(* time via the *_w cfgs.                                                        *)

\* W-restart: a node that HAS restarted recovers into a Ready multi-node router
\* actually delivering to a live remote holder (multi-group RestartRecoversToRouter).
\* Violation => restart recovery is exercised, so the safety pass is not vacuous.
RestartRecoversToRouter ==
  ~( \E r \in Nodes :
       /\ everRestarted[r] /\ up[r]
       /\ Cardinality(view[r]) > 1 /\ Ready(r)
       /\ \E g \in Groups : \E s \in Nodes :
            /\ s # r /\ s \in view[r] /\ up[s] /\ holds[s][g]
            /\ Router(g, view[r]) = r
            /\ s \in Present(r, g) )

\* W-delta-restart: a DELTA snapshot coexists in msgs with a restart having
\* occurred to its source OR destination -- the crux restart x delta state.
\* Violation => a delta genuinely rides alongside a restart in the search.
NoDeltaWithRestart ==
  ~( \E m \in msgs :
       /\ m.t = "snapshot" /\ m.kind = "delta"
       /\ (everRestarted[m.src] \/ everRestarted[m.dst]) )

\* W-delta-to-restarted: a delta is DELIVERED (still in msgs, newer than the
\* wiped watermark) to a node that restarted, and relies on a surviving baseline
\* row it did not carry. Violation => the "delta onto a post-restart surviving
\* baseline" scenario is reached.
NoBaselineDeltaAfterRestart ==
  ~( \E m \in msgs :
       /\ m.t = "snapshot" /\ m.kind = "delta"
       /\ everRestarted[m.dst]
       /\ m.seq > appliedSeq[m.dst][m.src]
       /\ \E g \in Groups :
             /\ g \notin m.grps
             /\ occ[m.dst][g][m.src].present )

\* Optional state-space bound for deeper/looser searches.
MsgBound == Cardinality(msgs) <= 3

================================================================================
