--------------------------- MODULE Muster3RestartDown ---------------------------
(*****************************************************************************)
(* CAVEAT-7 COMPOSITION #1: the occupancy GC sweep x the coordinator restart. *)
(*                                                                           *)
(* MODULE Muster3 (Muster2/B1 + DropStale/Reap, verified only on the          *)
(* no-restart single-group base) COMPOSED with the coordinator crash/restart  *)
(* action in its CORRECTED, Finding-B-faithful form (peers monitor the        *)
(* coordinator PID, so a restart-in-place delivers a peer-side :DOWN that     *)
(* blanks the restarted node's member_views agreement everywhere, and Erlang  *)
(* monitor+dist ordering puts that :DOWN after every old-incarnation message  *)
(* -- both taken verbatim from Muster2DeltaRestartDown's Restart).            *)
(*                                                                           *)
(* WHY THIS COMPOSITION. TLA_FINDINGS caveat 7 ranks it worth building        *)
(* because Finding B itself came from exactly this kind of cross-mechanism    *)
(* composition, and the informal argument for sweep x restart is fail-safe    *)
(* only informally: the sweep's under-delivery lever is its judge --          *)
(* SourceAgrees (the row's source has announced OUR committed view, row seq   *)
(* under the announcement watermark) AND routes-away (the group does not      *)
(* route to us under our committed view). A restart wipes the very            *)
(* member_views agreement SourceAgrees reads:                                 *)
(*                                                                           *)
(*   * on the RESTARTED node n: mv[n] is wiped, so n cannot judge any remote  *)
(*     row until the source re-announces n's (new) committed view -- but n's  *)
(*     RETAINED occupancy table is full of stale pre-restart rows at old      *)
(*     seqs, and n's own rows are ALWAYS judgeable (s = r).                   *)
(*   * on every PEER p: the :DOWN blanks mv[p][n], so p cannot judge n's      *)
(*     rows until n's new incarnation re-announces -- while p may still be    *)
(*     :ready on the old shared view.                                        *)
(*                                                                           *)
(* The question NoMissedDelivery asks: can the sweep, fed post-restart        *)
(* agreement state, tombstone a row a Ready router still needs?               *)
(*                                                                           *)
(* Everything else is verbatim from its source module: HolderJoin/Leave,      *)
(* Discover/DeliverPrepare/Commit (B1), NodeDown/DetectDown, SelfClaim,       *)
(* SendSnapshot/SendMarker, Deliver*, DropStale/Reap from Muster3; Restart /  *)
(* SingletonPromote / the promoted-gated Ready from Muster2DeltaRestartDown   *)
(* (specialized to one group: the self re-assert touches occ[n][n] iff        *)
(* holds[n]).                                                                 *)
(*                                                                           *)
(* History vars (probes only; excluded from the safety story):                *)
(*   everRestarted[n] -- set once by Restart(n).                              *)
(*   everSwept        -- set once by any DropStale.                           *)
(*   sweptPostRestart -- set by a DropStale firing after some restart.        *)
(*****************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS Nodes, MaxSeq
ASSUME MaxSeq \in Nat
NoSeq == 0

VARIABLES
  up, holds, view, round, occ, mv, owed, seqCtr, msgs,
  promoted,         \* restart analog of the B1 gate: FALSE right after a restart
  everRestarted,    \* history (probes only)
  everSwept,        \* history (probes only)
  sweptPostRestart  \* history (probes only)

vars == <<up, holds, view, round, occ, mv, owed, seqCtr, msgs,
          promoted, everRestarted, everSwept, sweptPostRestart>>

histUnch == UNCHANGED <<everRestarted, everSwept, sweptPostRestart>>

--------------------------------------------------------------------------------
Router(V) == CHOOSE n \in V : \A m \in V : n <= m

\* Ready with the restart singleton clause: a SINGLETON view {r} is trusted only
\* once promoted (a freshly restarted node floods even as a singleton).
Ready(r) ==
  /\ view[r] # {}
  /\ \A m \in view[r] : \/ m = r
                        \/ /\ mv[r][m].known
                           /\ mv[r][m].hv = view[r]
  /\ (view[r] = {r} => promoted[r])

CanDecide(r, senderView) == Ready(r) /\ view[r] = senderView
Present(r) == { s \in Nodes : occ[r][s].present }

CanBump(s) == seqCtr[s] < MaxSeq
Bump(s)    == seqCtr[s] + 1

Desired(n) == IF round[n].active THEN round[n].target ELSE view[n]

PrepareMsg(s, r, tgt, q) ==
  [t |-> "prepare", src |-> s, dst |-> r, tgt |-> tgt, seq |-> q]
VacantMsg(s, r, q)   == [t |-> "vacant",   src |-> s, dst |-> r, seq |-> q]
SnapshotMsg(s, r, hv, q) == [t |-> "snapshot", src |-> s, dst |-> r, hv |-> hv, seq |-> q]
MarkerMsg(s, r, hv, q)   == [t |-> "marker",   src |-> s, dst |-> r, hv |-> hv, seq |-> q]

NoRound == [active |-> FALSE, target |-> {}, awaiting |-> {}, seq |-> NoSeq]
BlankMV == [known |-> FALSE, hv |-> {}, seq |-> NoSeq]

--------------------------------------------------------------------------------
Init ==
  /\ up     = [n \in Nodes |-> TRUE]
  /\ holds  = [n \in Nodes |-> FALSE]
  /\ view   = [n \in Nodes |-> {n}]
  /\ round  = [n \in Nodes |-> NoRound]
  /\ occ    = [r \in Nodes |-> [s \in Nodes |-> [present |-> FALSE, seq |-> NoSeq]]]
  /\ mv     = [r \in Nodes |-> [s \in Nodes |-> BlankMV]]
  /\ owed   = [n \in Nodes |-> {}]
  /\ seqCtr = [n \in Nodes |-> 0]
  /\ msgs   = {}
  /\ promoted = [n \in Nodes |-> TRUE]
  /\ everRestarted = [n \in Nodes |-> FALSE]
  /\ everSwept = FALSE
  /\ sweptPostRestart = FALSE

--------------------------------------------------------------------------------
HolderJoin(n) ==
  /\ up[n] /\ ~holds[n] /\ view[n] # {}
  /\ CanBump(n)
  /\ LET r == Router(view[n]) IN
       /\ holds' = [holds EXCEPT ![n] = TRUE]
       /\ seqCtr' = [seqCtr EXCEPT ![n] = Bump(n)]
       /\ occ' = [occ EXCEPT ![r][n] =
             IF Bump(n) > occ[r][n].seq THEN [present |-> TRUE, seq |-> Bump(n)]
             ELSE occ[r][n]]
  /\ UNCHANGED <<up, view, round, mv, owed, msgs, promoted>>
  /\ histUnch

HolderLeave(n) ==
  /\ up[n] /\ holds[n] /\ view[n] # {}
  /\ CanBump(n)
  /\ holds' = [holds EXCEPT ![n] = FALSE]
  /\ seqCtr' = [seqCtr EXCEPT ![n] = Bump(n)]
  /\ LET r == Router(view[n]) IN
       IF r = n
       THEN /\ occ' = [occ EXCEPT ![n][n] =
                   IF Bump(n) >= occ[n][n].seq THEN [present |-> FALSE, seq |-> Bump(n)]
                   ELSE occ[n][n]]
            /\ UNCHANGED msgs
       ELSE /\ msgs' = msgs \cup {VacantMsg(n, r, Bump(n))}
            /\ UNCHANGED occ
  /\ UNCHANGED <<up, view, round, mv, owed, promoted>>
  /\ histUnch

--------------------------------------------------------------------------------
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
  /\ UNCHANGED <<up, holds, view, occ, mv, owed, promoted>>
  /\ histUnch

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
  /\ UNCHANGED <<up, holds, view, occ, owed, seqCtr, promoted>>
  /\ histUnch

\* Establishing a committed view promotes the node (no longer a fresh
\* converging singleton).
Commit(n) ==
  /\ up[n]
  /\ round[n].active
  /\ round[n].awaiting = {}
  /\ LET target == round[n].target
         fold   == holds[n] /\ Router(target) = n
     IN /\ (fold => CanBump(n))
        /\ view' = [view EXCEPT ![n] = target]
        /\ round' = [round EXCEPT ![n].active = FALSE]
        /\ occ' = IF fold
                  THEN [occ EXCEPT ![n][n] = [present |-> TRUE, seq |-> Bump(n)]]
                  ELSE occ
        /\ seqCtr' = IF fold THEN [seqCtr EXCEPT ![n] = Bump(n)] ELSE seqCtr
  /\ promoted' = [promoted EXCEPT ![n] = TRUE]
  /\ UNCHANGED <<up, holds, mv, owed, msgs>>
  /\ histUnch

NodeDown(n) ==
  /\ up[n]
  /\ \E k \in Nodes : k # n /\ up[k]
  /\ up' = [up EXCEPT ![n] = FALSE]
  /\ UNCHANGED <<holds, view, round, occ, mv, owed, seqCtr, msgs, promoted>>
  /\ histUnch

DetectDown(n, d) ==
  /\ up[n] /\ ~up[d] /\ n # d
  /\ d \in (view[n] \cup round[n].target \cup round[n].awaiting)
  /\ LET nv   == view[n] \ {d}
         fold == holds[n] /\ nv # {} /\ Router(nv) = n
         nt   == round[n].target \ {d}
     IN /\ (fold => CanBump(n))
        /\ view' = [view EXCEPT ![n] = nv]
        /\ round' = [round EXCEPT ![n] =
              IF round[n].active /\ nt # nv
              THEN [active |-> TRUE, target |-> nt,
                    awaiting |-> round[n].awaiting \ {d}, seq |-> round[n].seq]
              ELSE NoRound]
        /\ occ' = IF fold
                  THEN [occ EXCEPT ![n][d] = [present |-> FALSE, seq |-> NoSeq],
                                   ![n][n] = [present |-> TRUE, seq |-> Bump(n)]]
                  ELSE [occ EXCEPT ![n][d] = [present |-> FALSE, seq |-> NoSeq]]
        /\ seqCtr' = IF fold THEN [seqCtr EXCEPT ![n] = Bump(n)] ELSE seqCtr
  /\ mv'   = [mv EXCEPT ![n][d] = BlankMV]
  /\ owed' = [owed EXCEPT ![n] = owed[n] \ {d}]
  /\ promoted' = [promoted EXCEPT ![n] = TRUE]
  /\ UNCHANGED <<up, holds, msgs>>
  /\ histUnch

--------------------------------------------------------------------------------
(* THE RESTART (single-group specialization of Muster2DeltaRestartDown's).     *)
(* The coordinator crashes (crash-on-prepare-timeout / snapshot-failure hatch)  *)
(* and the supervisor restarts it under the same live node name.               *)

Restart(n) ==
  /\ up[n]
  /\ CanBump(n)                          \* init consumes a seq (view_seq watermark)
  /\ view'  = [view  EXCEPT ![n] = {n}]  \* ring reset to [node()]
  /\ round' = [round EXCEPT ![n] = NoRound]                  \* pending_round cleared
  \* member_views wiped on n itself AND (peer-side coordinator-pid :DOWN) n's
  \* agreement blanked on every peer p -- the synchronous, most-generous model
  \* of the :DOWN every peer receives when n's coordinator restarts (Finding B).
  /\ mv'    = [p \in Nodes |->
                 IF p = n THEN [s \in Nodes |-> BlankMV]
                 ELSE [mv[p] EXCEPT ![n] = BlankMV]]
  /\ owed'  = [owed  EXCEPT ![n] = {}]                       \* owed_snapshots cleared
  /\ promoted' = [promoted EXCEPT ![n] = FALSE]              \* start :converging
  /\ seqCtr' = [seqCtr EXCEPT ![n] = Bump(n)]
  \* occ TABLE SURVIVES (Forum.Supervisor-owned ETS): retain every occ[n][s];
  \* re-assert the self row monotonically (reannounce_local_groups_at_init).
  /\ occ' = [occ EXCEPT ![n] = [s \in Nodes |->
        IF s = n /\ holds[n] /\ Bump(n) > occ[n][s].seq
        THEN [present |-> TRUE, seq |-> Bump(n)]
        ELSE occ[n][s]]]
  \* FIFO faithfulness: the :DOWN is Erlang-ordered AFTER every old-incarnation
  \* message, so drop n's in-flight sends (see Muster2DeltaRestartDown).
  /\ msgs' = { m \in msgs : m.src # n }
  /\ everRestarted' = [everRestarted EXCEPT ![n] = TRUE]
  /\ UNCHANGED <<up, holds, everSwept, sweptPostRestart>>

SingletonPromote(n) ==
  /\ up[n]
  /\ ~promoted[n]
  /\ view[n] = {n}
  /\ promoted' = [promoted EXCEPT ![n] = TRUE]
  /\ UNCHANGED <<up, holds, view, round, occ, mv, owed, seqCtr, msgs>>
  /\ histUnch

--------------------------------------------------------------------------------
SelfClaim(s) ==
  /\ up[s] /\ holds[s] /\ view[s] # {}
  /\ Router(view[s]) = s
  /\ CanBump(s)
  /\ seqCtr' = [seqCtr EXCEPT ![s] = Bump(s)]
  /\ occ' = [occ EXCEPT ![s][s] =
        IF Bump(s) > occ[s][s].seq THEN [present |-> TRUE, seq |-> Bump(s)]
        ELSE occ[s][s]]
  /\ UNCHANGED <<up, holds, view, round, mv, owed, msgs, promoted>>
  /\ histUnch

SendSnapshot(s, r) ==
  /\ up[s] /\ holds[s] /\ view[s] # {}
  /\ ~round[s].active
  /\ r \in view[s] /\ r # s
  /\ Router(view[s]) = r
  /\ CanBump(s)
  /\ seqCtr' = [seqCtr EXCEPT ![s] = Bump(s)]
  /\ owed' = [owed EXCEPT ![s] = owed[s] \cup {r}]
  /\ msgs' = msgs \cup {SnapshotMsg(s, r, view[s], Bump(s))}
  /\ UNCHANGED <<up, holds, view, round, occ, mv, promoted>>
  /\ histUnch

SendMarker(s, m) ==
  /\ up[s] /\ view[s] # {}
  /\ ~round[s].active
  /\ m \in view[s] /\ m # s
  /\ m \notin owed[s]
  /\ ~(holds[s] /\ Router(view[s]) = m)
  /\ CanBump(s)
  /\ seqCtr' = [seqCtr EXCEPT ![s] = Bump(s)]
  /\ msgs' = msgs \cup {MarkerMsg(s, m, view[s], Bump(s))}
  /\ UNCHANGED <<up, holds, view, round, occ, mv, owed, promoted>>
  /\ histUnch

--------------------------------------------------------------------------------
ApplyPresent(r, s, q) ==
  IF q > occ[r][s].seq THEN [present |-> TRUE, seq |-> q] ELSE occ[r][s]
ApplyTomb(r, s, q) ==
  IF q >= occ[r][s].seq THEN [present |-> FALSE, seq |-> q] ELSE occ[r][s]
ApplyMV(r, s, hv, q) ==
  IF q > mv[r][s].seq THEN [known |-> TRUE, hv |-> hv, seq |-> q] ELSE mv[r][s]

DeliverVacant(msg) ==
  /\ msg \in msgs /\ msg.t = "vacant"
  /\ occ' = [occ EXCEPT ![msg.dst][msg.src] = ApplyTomb(msg.dst, msg.src, msg.seq)]
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<up, holds, view, round, mv, owed, seqCtr, promoted>>
  /\ histUnch

DeliverSnapshot(msg) ==
  /\ msg \in msgs /\ msg.t = "snapshot"
  /\ occ' = [occ EXCEPT ![msg.dst][msg.src] = ApplyPresent(msg.dst, msg.src, msg.seq)]
  /\ mv'  = [mv  EXCEPT ![msg.dst][msg.src] = ApplyMV(msg.dst, msg.src, msg.hv, msg.seq)]
  /\ owed' = [owed EXCEPT ![msg.src] = owed[msg.src] \ {msg.dst}]
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<up, holds, view, round, seqCtr, promoted>>
  /\ histUnch

DeliverMarker(msg) ==
  /\ msg \in msgs /\ msg.t = "marker"
  /\ mv' = [mv EXCEPT ![msg.dst][msg.src] = ApplyMV(msg.dst, msg.src, msg.hv, msg.seq)]
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<up, holds, view, round, occ, owed, seqCtr, promoted>>
  /\ histUnch

--------------------------------------------------------------------------------
(* The GC sweep and tombstone reap, verbatim from Muster3 (see that module's   *)
(* header for the judge/write-race faithfulness argument), plus the history    *)
(* bits for the probes.                                                        *)

SourceAgrees(r, s) ==
  \/ s = r
  \/ /\ mv[r][s].known
     /\ mv[r][s].hv = view[r]
     /\ occ[r][s].seq <= mv[r][s].seq

DropStale(r, s) ==
  /\ up[r]
  /\ view[r] # {}
  /\ occ[r][s].present
  /\ Router(view[r]) # r
  /\ SourceAgrees(r, s)
  /\ occ' = [occ EXCEPT ![r][s] = [present |-> FALSE, seq |-> occ[r][s].seq]]
  /\ everSwept' = TRUE
  /\ sweptPostRestart' = (sweptPostRestart \/ \E k \in Nodes : everRestarted[k])
  /\ UNCHANGED <<up, holds, view, round, mv, owed, seqCtr, msgs, promoted,
                 everRestarted>>

Reap(r, s) ==
  /\ ~occ[r][s].present
  /\ occ[r][s].seq # NoSeq
  /\ \A m \in msgs : ~(m.dst = r /\ m.src = s)
  /\ occ' = [occ EXCEPT ![r][s] = [present |-> FALSE, seq |-> NoSeq]]
  /\ UNCHANGED <<up, holds, view, round, mv, owed, seqCtr, msgs, promoted>>
  /\ histUnch

--------------------------------------------------------------------------------
Next ==
  \/ \E n \in Nodes : HolderJoin(n)
  \/ \E n \in Nodes : HolderLeave(n)
  \/ \E n, m \in Nodes : Discover(n, m)
  \/ \E n \in Nodes : Commit(n)
  \/ \E n \in Nodes : NodeDown(n)
  \/ \E n, d \in Nodes : DetectDown(n, d)
  \/ \E n \in Nodes : Restart(n)
  \/ \E n \in Nodes : SingletonPromote(n)
  \/ \E s \in Nodes : SelfClaim(s)
  \/ \E s, r \in Nodes : SendSnapshot(s, r)
  \/ \E s, m \in Nodes : SendMarker(s, m)
  \/ \E msg \in msgs : DeliverPrepare(msg)
  \/ \E msg \in msgs : DeliverVacant(msg)
  \/ \E msg \in msgs : DeliverSnapshot(msg)
  \/ \E msg \in msgs : DeliverMarker(msg)
  \/ \E r, s \in Nodes : DropStale(r, s)
  \/ \E r, s \in Nodes : Reap(r, s)

Spec == Init /\ [][Next]_vars

--------------------------------------------------------------------------------
TypeOK ==
  /\ up \in [Nodes -> BOOLEAN]
  /\ holds \in [Nodes -> BOOLEAN]
  /\ view \in [Nodes -> SUBSET Nodes]
  /\ seqCtr \in [Nodes -> 0..MaxSeq]
  /\ owed \in [Nodes -> SUBSET Nodes]
  /\ promoted \in [Nodes -> BOOLEAN]
  /\ everRestarted \in [Nodes -> BOOLEAN]
  /\ everSwept \in BOOLEAN
  /\ sweptPostRestart \in BOOLEAN

NoMissedDelivery ==
  \A u \in Nodes :
    \A r \in Nodes :
      ( /\ up[u] /\ up[r]
        /\ view[u] # {}
        /\ Router(view[u]) = r
        /\ CanDecide(r, view[u]) )
      => \A s \in Nodes :
            ( /\ up[s] /\ holds[s]
              /\ s \in view[r] )
            => s \in Present(r)

--------------------------------------------------------------------------------
(* Non-vacuity probes (expect TLC to VIOLATE; a violation is the WITNESS that   *)
(* the sweep x restart interaction is actually exercised). One per *_w cfg.     *)

\* W1: some sweep fires at all.
NoSweep == ~everSwept

\* W2: a sweep fires in a run where a coordinator restart has already happened
\* -- the sweep is judging post-restart agreement state.
NoSweepAfterRestart == ~sweptPostRestart

\* Optional bound for deeper partial searches.
MsgBound == Cardinality(msgs) <= 3

================================================================================
