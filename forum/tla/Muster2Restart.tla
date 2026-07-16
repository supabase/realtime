---------------------------- MODULE Muster2Restart ----------------------------
(*****************************************************************************)
(* Muster2 (the shipped B1 two-phase view-adoption fix) PLUS a coordinator    *)
(* RESTART action -- the crash-on-prepare-timeout / crash-on-snapshot-failure *)
(* escape hatch that neither Muster2 (safety) nor Muster2Live (liveness)       *)
(* exercise. In the code, a prepare or snapshot RPC to an up-but-unreachable   *)
(* peer fails, the coordinator `raise`s (scope.ex ~964 / ~921), and the        *)
(* supervisor restarts it under the SAME live node name.                       *)
(*                                                                           *)
(* This is NOT the "node name reuse across deployments" case that the user     *)
(* assumption excludes: the node stays UP (peers see no :DOWN); only the        *)
(* coordinator GenServer restarts. Modeled faithfully to init/1 (scope.ex      *)
(* ~435) and reannounce_local_groups_at_init:                                  *)
(*                                                                           *)
(*   * The occupancy table is owned by a long-lived sibling (Forum.Supervisor) *)
(*     so it SURVIVES the restart: occ[n][s] rows are RETAINED (stale rows      *)
(*     become over-delivery, which the property intentionally ignores; the     *)
(*     under-delivery question is whether a needed row can be missing).        *)
(*   * The ring resets to [node()]: view[n] := {n}.                            *)
(*   * member_views is wiped: mv[n] := all-unknown. The node forgets every      *)
(*     peer's agreement, so it cannot be a "stale-ready router" on a grown view *)
(*     -- it must re-pair before it can be Ready again.                         *)
(*   * pending_round / owed_snapshots are coordinator state -> cleared.         *)
(*   * Self rows are re-asserted monotonically for locally-held groups          *)
(*     (reannounce_local_groups_at_init); local membership (holds[n]) survives  *)
(*     the restart (rebuilt from the partition tables).                         *)
(*   * Status starts :converging, NOT :ready -- even as a singleton {n}. A      *)
(*     bounded, init-only singleton-promotion timer restores :ready ONLY if the *)
(*     node is genuinely alone. This is the restart analog of the B1 gate: a    *)
(*     restarted node floods until it either re-pairs (grows + peers agree) or  *)
(*     is confirmed alone. Modeled by `promoted`: FALSE right after a restart,  *)
(*     set TRUE by SingletonPromote (still alone) or by any legitimate view      *)
(*     establishment (Commit / DetectDown).                                     *)
(*                                                                           *)
(* In-flight messages addressed to n survive the restart and are delivered to   *)
(* the new incarnation -- faithful, because occupancy/marker/vacant writes go   *)
(* to the registered scope name (or straight to the surviving ETS table via     *)
(* :erpc), not to the dead pid. So a coordinator restart does not by itself      *)
(* lose an in-flight occupancy write.                                           *)
(*                                                                           *)
(* Question: does the crash/restart path preserve NoMissedDelivery? i.e. can a  *)
(* restarted node (retained stale table + wiped agreements + ring reset) ever   *)
(* be CanDecide while missing a live in-view holder?                            *)
(*****************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS Nodes, MaxSeq
ASSUME MaxSeq \in Nat
NoSeq == 0

VARIABLES
  up, holds, view, round, occ, mv, owed, seqCtr, msgs, promoted,
  everRestarted   \* history var (probe/non-vacuity only): set once by Restart

vars == <<up, holds, view, round, occ, mv, owed, seqCtr, msgs, promoted, everRestarted>>

--------------------------------------------------------------------------------
Router(V) == CHOOSE n \in V : \A m \in V : n <= m

\* A node is Ready when every member of its committed view agrees on that view.
\* Extra restart clause: a SINGLETON view {r} is only trusted once promoted --
\* a freshly restarted node is :converging (floods) even as a singleton until
\* the init-only promotion timer confirms it is genuinely alone. For any
\* multi-node view the singleton clause is vacuous (and by the time a restarted
\* node holds a multi-node committed view it has already been promoted by Commit).
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
  /\ everRestarted = [n \in Nodes |-> FALSE]

--------------------------------------------------------------------------------
(* Group-membership churn (unchanged from Muster2). *)

HolderJoin(n) ==
  /\ up[n] /\ ~holds[n] /\ view[n] # {}
  /\ CanBump(n)
  /\ LET r == Router(view[n]) IN
       /\ holds' = [holds EXCEPT ![n] = TRUE]
       /\ seqCtr' = [seqCtr EXCEPT ![n] = Bump(n)]
       /\ occ' = [occ EXCEPT ![r][n] =
             IF Bump(n) > occ[r][n].seq THEN [present |-> TRUE, seq |-> Bump(n)]
             ELSE occ[r][n]]
  /\ UNCHANGED <<up, view, round, mv, owed, msgs, promoted, everRestarted>>

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
  /\ UNCHANGED <<up, view, round, mv, owed, promoted, everRestarted>>

--------------------------------------------------------------------------------
(* Cluster-view churn (unchanged from Muster2 except carrying `promoted`). *)

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
  /\ UNCHANGED <<up, holds, view, occ, mv, owed, promoted, everRestarted>>

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
  /\ UNCHANGED <<up, holds, view, occ, owed, seqCtr, promoted, everRestarted>>

\* Commit establishes a real (possibly multi-node) committed view -> promoted.
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
  /\ UNCHANGED <<up, holds, mv, owed, msgs, everRestarted>>

NodeDown(n) ==
  /\ up[n]
  /\ \E k \in Nodes : k # n /\ up[k]
  /\ up' = [up EXCEPT ![n] = FALSE]
  /\ UNCHANGED <<holds, view, round, occ, mv, owed, seqCtr, msgs, promoted, everRestarted>>

\* Shrinking to a legitimate view (a peer really died) leaves us on an
\* established view -> promoted (this is NOT the fresh-restart converging state).
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
  /\ UNCHANGED <<up, holds, msgs, everRestarted>>

--------------------------------------------------------------------------------
(* THE RESTART. The coordinator crashes (prepare/snapshot RPC to an           *)
(* up-but-unreachable peer failed) and the supervisor restarts it. The node   *)
(* stays UP -- peers see no :DOWN, so they keep their occ/mv rows for n.       *)

Restart(n) ==
  /\ up[n]
  /\ CanBump(n)                          \* init consumes a seq (view_seq watermark)
  /\ view'  = [view  EXCEPT ![n] = {n}]  \* ring reset to [node()]
  /\ round' = [round EXCEPT ![n] = NoRound]              \* pending_round cleared
  /\ mv'    = [mv    EXCEPT ![n] = [s \in Nodes |-> BlankMV]] \* member_views wiped
  /\ owed'  = [owed  EXCEPT ![n] = {}]                   \* owed_snapshots cleared
  /\ promoted' = [promoted EXCEPT ![n] = FALSE]          \* start :converging
  /\ seqCtr' = [seqCtr EXCEPT ![n] = Bump(n)]
  \* occ TABLE SURVIVES: retain every occ[n][s] (s # n); re-assert the self row
  \* monotonically for a locally-held group (reannounce_local_groups_at_init).
  /\ occ' = [occ EXCEPT ![n][n] =
        IF holds[n] /\ Bump(n) > occ[n][n].seq
        THEN [present |-> TRUE, seq |-> Bump(n)]
        ELSE occ[n][n]]
  /\ everRestarted' = [everRestarted EXCEPT ![n] = TRUE]
  /\ UNCHANGED <<up, holds, msgs>>

\* Bounded, init-only singleton self-promotion: only fires while genuinely alone
\* (view still {n}); restores :ready when the scope really has downsized to one.
SingletonPromote(n) ==
  /\ up[n]
  /\ ~promoted[n]
  /\ view[n] = {n}
  /\ promoted' = [promoted EXCEPT ![n] = TRUE]
  /\ UNCHANGED <<up, holds, view, round, occ, mv, owed, seqCtr, msgs, everRestarted>>

--------------------------------------------------------------------------------
(* Post-commit re-announce (unchanged from Muster2 except carrying promoted). *)

SelfClaim(s) ==
  /\ up[s] /\ holds[s] /\ view[s] # {}
  /\ Router(view[s]) = s
  /\ CanBump(s)
  /\ seqCtr' = [seqCtr EXCEPT ![s] = Bump(s)]
  /\ occ' = [occ EXCEPT ![s][s] =
        IF Bump(s) > occ[s][s].seq THEN [present |-> TRUE, seq |-> Bump(s)]
        ELSE occ[s][s]]
  /\ UNCHANGED <<up, holds, view, round, mv, owed, msgs, promoted, everRestarted>>

SendSnapshot(s, r) ==
  /\ up[s] /\ holds[s] /\ view[s] # {}
  /\ ~round[s].active
  /\ r \in view[s] /\ r # s
  /\ Router(view[s]) = r
  /\ CanBump(s)
  /\ seqCtr' = [seqCtr EXCEPT ![s] = Bump(s)]
  /\ owed' = [owed EXCEPT ![s] = owed[s] \cup {r}]
  /\ msgs' = msgs \cup {SnapshotMsg(s, r, view[s], Bump(s))}
  /\ UNCHANGED <<up, holds, view, round, occ, mv, promoted, everRestarted>>

SendMarker(s, m) ==
  /\ up[s] /\ view[s] # {}
  /\ ~round[s].active
  /\ m \in view[s] /\ m # s
  /\ m \notin owed[s]
  /\ ~(holds[s] /\ Router(view[s]) = m)
  /\ CanBump(s)
  /\ seqCtr' = [seqCtr EXCEPT ![s] = Bump(s)]
  /\ msgs' = msgs \cup {MarkerMsg(s, m, view[s], Bump(s))}
  /\ UNCHANGED <<up, holds, view, round, occ, mv, owed, promoted, everRestarted>>

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
  /\ UNCHANGED <<up, holds, view, round, mv, owed, seqCtr, promoted, everRestarted>>

DeliverSnapshot(msg) ==
  /\ msg \in msgs /\ msg.t = "snapshot"
  /\ occ' = [occ EXCEPT ![msg.dst][msg.src] = ApplyPresent(msg.dst, msg.src, msg.seq)]
  /\ mv'  = [mv  EXCEPT ![msg.dst][msg.src] = ApplyMV(msg.dst, msg.src, msg.hv, msg.seq)]
  /\ owed' = [owed EXCEPT ![msg.src] = owed[msg.src] \ {msg.dst}]
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<up, holds, view, round, seqCtr, promoted, everRestarted>>

DeliverMarker(msg) ==
  /\ msg \in msgs /\ msg.t = "marker"
  /\ mv' = [mv EXCEPT ![msg.dst][msg.src] = ApplyMV(msg.dst, msg.src, msg.hv, msg.seq)]
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<up, holds, view, round, occ, owed, seqCtr, promoted, everRestarted>>

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

\* Reachability probe (NON-VACUITY CHECK, not a real safety property). Asserts
\* the recovery state is UNreachable so TLC prints a witness trace when it IS
\* reached: a node that HAS restarted later recovers into a Ready multi-node
\* router actually delivering to a live remote holder. A violation here is GOOD --
\* it proves restart RECOVERY is exercised and the NoMissedDelivery pass is not
\* vacuous (a restart that merely sidelines a node forever would pass trivially).
\* Checked via Muster2Restart_probe.cfg.
RestartRecoversToRouter ==
  ~( \E r \in Nodes :
       /\ everRestarted[r] /\ up[r]
       /\ Cardinality(view[r]) > 1 /\ Ready(r)
       /\ \E s \in Nodes : s # r /\ s \in view[r] /\ up[s] /\ holds[s]
                           /\ s \in Present(r) )

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

================================================================================
