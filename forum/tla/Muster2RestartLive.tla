-------------------------- MODULE Muster2RestartLive --------------------------
(*****************************************************************************)
(* LIVENESS of the crash-on-prepare-timeout ESCAPE HATCH -- the one B1        *)
(* mechanism neither Muster2 (safety) nor Muster2Live (liveness) exercise.    *)
(*                                                                           *)
(* Muster2Live never DROPS a message, so every prepare is delivered = acked   *)
(* and the hatch is never needed; its own caveat says the up-but-unreachable  *)
(* peer case (prepare never acks) is out of scope. This module closes that:   *)
(*                                                                           *)
(*   * DropPrepare(msg) -- a prepare RPC to an up-but-unreachable peer FAILS   *)
(*     (the message is discarded, never delivered, never acked). An UNFAIR     *)
(*     fault: it may or may not happen.                                        *)
(*   * A round with a dropped prepare is WEDGED: its awaited member can never   *)
(*     ack, so awaiting never empties and Commit is never enabled -- exactly    *)
(*     the stall the hatch exists to break.                                     *)
(*   * RestartOnTimeout(n) -- the coordinator crashes because a prepare RPC     *)
(*     worker returned failure (scope.ex ~964) and the supervisor restarts it.  *)
(*     Enabled precisely when a round is wedged (an awaited member's prepare is  *)
(*     no longer outstanding, i.e. it was dropped). WEAK-FAIR: a wedged round   *)
(*     is eventually resolved by a restart.                                     *)
(*                                                                           *)
(* After a restart the ring is {n} and a re-grow Discover from a singleton has  *)
(* an EMPTY audience, so it commits with no prepare -- the restart cannot itself *)
(* wedge. Round creation (Discover) is the only seq-consuming round source, so  *)
(* it is bounded; the restart self-reassert, like Commit/DetectDown, is         *)
(* DECOUPLED from CanBump (a real crash needs no seq).                          *)
(*                                                                           *)
(* Property checked: RoundsResolve -- every active round a live node holds is   *)
(* eventually resolved (committed, pruned, or cleared by a restart). This is    *)
(* the machine-checkable statement of "the crash-on-timeout hatch ensures no    *)
(* prepare round wedges forever." <>[]RoundsQuiet is ALSO checked (it holds     *)
(* under the model's bounded seq, which bounds the drop/restart/re-grow loop);  *)
(* under truly unbounded seq a permanently-unreachable-but-up peer would loop,  *)
(* but in the field such a peer eventually goes :DOWN (DetectDown prunes it) --  *)
(* out of scope here, as in Muster2Live.                                         *)
(*****************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS Nodes, MaxSeq
ASSUME MaxSeq \in Nat
NoSeq == 0

VARIABLES
  up, holds, view, round, occ, mv, owed, seqCtr, msgs, promoted

vars == <<up, holds, view, round, occ, mv, owed, seqCtr, msgs, promoted>>

--------------------------------------------------------------------------------
Router(V) == CHOOSE n \in V : \A m \in V : n <= m

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

\* A prepare for n's current round to member d is still in flight (deliverable).
PrepareOutstanding(n, d) ==
  \E msg \in msgs : /\ msg.t = "prepare"
                    /\ msg.src = n /\ msg.dst = d /\ msg.seq = round[n].seq
\* n's round is WEDGED: an awaited member's prepare was dropped (not outstanding,
\* and awaited => not yet acked). It can never complete normally.
Wedged(n) ==
  /\ round[n].active
  /\ \E d \in round[n].awaiting : ~PrepareOutstanding(n, d)

--------------------------------------------------------------------------------
Init ==
  /\ up       = [n \in Nodes |-> TRUE]
  /\ holds    = [n \in Nodes |-> FALSE]
  /\ view     = [n \in Nodes |-> {n}]
  /\ round    = [n \in Nodes |-> NoRound]
  /\ occ      = [r \in Nodes |-> [s \in Nodes |-> [present |-> FALSE, seq |-> NoSeq]]]
  /\ mv       = [r \in Nodes |-> [s \in Nodes |-> BlankMV]]
  /\ owed     = [n \in Nodes |-> {}]
  /\ seqCtr   = [n \in Nodes |-> 0]
  /\ msgs     = {}
  /\ promoted = [n \in Nodes |-> TRUE]

--------------------------------------------------------------------------------
(* CHURN (seq-consuming, UNFAIR). *)

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

SelfClaim(s) ==
  /\ up[s] /\ holds[s] /\ view[s] # {}
  /\ Router(view[s]) = s
  /\ CanBump(s)
  /\ seqCtr' = [seqCtr EXCEPT ![s] = Bump(s)]
  /\ occ' = [occ EXCEPT ![s][s] =
        IF Bump(s) > occ[s][s].seq THEN [present |-> TRUE, seq |-> Bump(s)]
        ELSE occ[s][s]]
  /\ UNCHANGED <<up, holds, view, round, mv, owed, msgs, promoted>>

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

NodeDown(n) ==
  /\ up[n]
  /\ \E k \in Nodes : k # n /\ up[k]
  /\ up' = [up EXCEPT ![n] = FALSE]
  /\ UNCHANGED <<holds, view, round, occ, mv, owed, seqCtr, msgs, promoted>>

\* The FAULT: a prepare RPC to an up-but-unreachable peer fails. UNFAIR.
DropPrepare(msg) ==
  /\ msg \in msgs /\ msg.t = "prepare"
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<up, holds, view, round, occ, mv, owed, seqCtr, promoted>>

--------------------------------------------------------------------------------
(* CONVERGENCE-DRIVING (FAIR). Commit / DetectDown / Restart self re-assert     *)
(* DECOUPLED from CanBump (write at current seqCtr[n], no bump).                 *)

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

Commit(n) ==
  /\ up[n]
  /\ round[n].active
  /\ round[n].awaiting = {}
  /\ LET target == round[n].target
         fold   == holds[n] /\ Router(target) = n
     IN /\ view' = [view EXCEPT ![n] = target]
        /\ round' = [round EXCEPT ![n].active = FALSE]
        /\ occ' = IF fold
                  THEN [occ EXCEPT ![n][n] = [present |-> TRUE, seq |-> seqCtr[n]]]
                  ELSE occ
  /\ promoted' = [promoted EXCEPT ![n] = TRUE]
  /\ UNCHANGED <<up, holds, mv, owed, seqCtr, msgs>>

DetectDown(n, d) ==
  /\ up[n] /\ ~up[d] /\ n # d
  /\ d \in (view[n] \cup round[n].target \cup round[n].awaiting)
  /\ LET nv   == view[n] \ {d}
         fold == holds[n] /\ nv # {} /\ Router(nv) = n
         nt   == round[n].target \ {d}
     IN /\ view' = [view EXCEPT ![n] = nv]
        /\ round' = [round EXCEPT ![n] =
              IF round[n].active /\ nt # nv
              THEN [active |-> TRUE, target |-> nt,
                    awaiting |-> round[n].awaiting \ {d}, seq |-> round[n].seq]
              ELSE NoRound]
        /\ occ' = IF fold
                  THEN [occ EXCEPT ![n][d] = [present |-> FALSE, seq |-> NoSeq],
                                   ![n][n] = [present |-> TRUE, seq |-> seqCtr[n]]]
                  ELSE [occ EXCEPT ![n][d] = [present |-> FALSE, seq |-> NoSeq]]
  /\ mv'   = [mv EXCEPT ![n][d] = BlankMV]
  /\ owed' = [owed EXCEPT ![n] = owed[n] \ {d}]
  /\ promoted' = [promoted EXCEPT ![n] = TRUE]
  /\ UNCHANGED <<up, holds, seqCtr, msgs>>

\* THE HATCH: crash-on-prepare-timeout. Enabled only when the round is wedged
\* (a dropped prepare). Restart effect; self-reassert decoupled from CanBump.
RestartOnTimeout(n) ==
  /\ up[n]
  /\ Wedged(n)
  /\ view'  = [view  EXCEPT ![n] = {n}]
  /\ round' = [round EXCEPT ![n] = NoRound]
  /\ mv'    = [mv    EXCEPT ![n] = [s \in Nodes |-> BlankMV]]
  /\ owed'  = [owed  EXCEPT ![n] = {}]
  /\ promoted' = [promoted EXCEPT ![n] = FALSE]
  /\ occ' = [occ EXCEPT ![n][n] =
        IF holds[n] THEN [present |-> TRUE, seq |-> seqCtr[n]] ELSE occ[n][n]]
  /\ UNCHANGED <<up, holds, seqCtr, msgs>>

SingletonPromote(n) ==
  /\ up[n] /\ ~promoted[n] /\ view[n] = {n}
  /\ promoted' = [promoted EXCEPT ![n] = TRUE]
  /\ UNCHANGED <<up, holds, view, round, occ, mv, owed, seqCtr, msgs>>

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

DeliverSnapshot(msg) ==
  /\ msg \in msgs /\ msg.t = "snapshot"
  /\ occ' = [occ EXCEPT ![msg.dst][msg.src] = ApplyPresent(msg.dst, msg.src, msg.seq)]
  /\ mv'  = [mv  EXCEPT ![msg.dst][msg.src] = ApplyMV(msg.dst, msg.src, msg.hv, msg.seq)]
  /\ owed' = [owed EXCEPT ![msg.src] = owed[msg.src] \ {msg.dst}]
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<up, holds, view, round, seqCtr, promoted>>

DeliverMarker(msg) ==
  /\ msg \in msgs /\ msg.t = "marker"
  /\ mv' = [mv EXCEPT ![msg.dst][msg.src] = ApplyMV(msg.dst, msg.src, msg.hv, msg.seq)]
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<up, holds, view, round, occ, owed, seqCtr, promoted>>

--------------------------------------------------------------------------------
Next ==
  \/ \E n \in Nodes : HolderJoin(n)
  \/ \E n \in Nodes : HolderLeave(n)
  \/ \E n, m \in Nodes : Discover(n, m)
  \/ \E n \in Nodes : Commit(n)
  \/ \E n \in Nodes : NodeDown(n)
  \/ \E n, d \in Nodes : DetectDown(n, d)
  \/ \E n \in Nodes : RestartOnTimeout(n)
  \/ \E n \in Nodes : SingletonPromote(n)
  \/ \E s \in Nodes : SelfClaim(s)
  \/ \E s, r \in Nodes : SendSnapshot(s, r)
  \/ \E s, m \in Nodes : SendMarker(s, m)
  \/ \E msg \in msgs : DeliverPrepare(msg)
  \/ \E msg \in msgs : DropPrepare(msg)
  \/ \E msg \in msgs : DeliverVacant(msg)
  \/ \E msg \in msgs : DeliverSnapshot(msg)
  \/ \E msg \in msgs : DeliverMarker(msg)

Fairness ==
  /\ \A n \in Nodes : WF_vars(Commit(n))
  /\ \A n, d \in Nodes : WF_vars(DetectDown(n, d))
  /\ \A n \in Nodes : WF_vars(RestartOnTimeout(n))
  /\ \A n \in Nodes : WF_vars(SingletonPromote(n))
  /\ WF_vars(\E msg \in msgs : DeliverPrepare(msg))
  /\ WF_vars(\E msg \in msgs : DeliverSnapshot(msg))
  /\ WF_vars(\E msg \in msgs : DeliverMarker(msg))
  /\ WF_vars(\E msg \in msgs : DeliverVacant(msg))

LiveSpec == Init /\ [][Next]_vars /\ Fairness

--------------------------------------------------------------------------------
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

\* Non-vacuity probes (assert UNreachable so TLC prints a witness when reached).
\* NoWedgeReached: a round actually wedges (a prepare was dropped).
NoWedgeReached == ~(\E n \in Nodes : up[n] /\ Wedged(n))
\* NoTimeoutRestart: the hatch actually fired (a node is in the post-restart
\* converging state: singleton view, not promoted).
NoTimeoutRestart == ~(\E n \in Nodes : up[n] /\ view[n] = {n} /\ ~promoted[n])

RoundsQuiet == \A n \in Nodes : up[n] => ~round[n].active
Liveness == <>[]RoundsQuiet
\* The hatch's guarantee: no prepare round wedges forever.
RoundsResolve == \A n \in Nodes : (up[n] /\ round[n].active) ~> (~up[n] \/ ~round[n].active)

================================================================================
