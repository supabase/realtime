------------------------------- MODULE Muster3 -------------------------------
(*****************************************************************************)
(* MODULE Muster2 (the shipped B1 two-phase view adoption) PLUS the occupancy *)
(* garbage-collection sweep that TLA_FINDINGS.md caveat 1 flagged as the      *)
(* highest-priority unmodeled mechanism:                                      *)
(*                                                                           *)
(*   * DropStale  == drop_stale_router_entries/1 (scope.ex ~1369): the        *)
(*     periodic + on-:ready + post-rebalance sweep that DOWNGRADES a :present  *)
(*     occupancy row to a TOMBSTONE (at its EXISTING seq) when the row's       *)
(*     source agrees with our view AND the group no longer routes to us.       *)
(*     This is the only modeled mechanism that can turn a present row absent   *)
(*     on the router WITHOUT a message from the source, so it is the only new  *)
(*     candidate for UNDER-delivery (wrongly dropping a live row).             *)
(*                                                                           *)
(*   * Reap       == reap_tombstones/1 (scope.ex ~1693): the time-windowed     *)
(*     HARD delete of a tombstone, resetting the key to truly-absent (seq 0)   *)
(*     so a later legitimate claim can insert_new. Modeled faithfully to the   *)
(*     design assumption that the retention window (a multiple of rpc_timeout) *)
(*     outlasts any orphaned in-flight RPC: a tombstone may be reaped only     *)
(*     once its {router,source} key is QUIESCENT (no in-flight message could   *)
(*     still land for it). Firing reap earlier would model a "window too       *)
(*     short" timing bug, a separate concern the design explicitly rules out.  *)
(*                                                                           *)
(* Register encoding (unchanged from MODULE Muster/Muster2): occ[r][s] is      *)
(* [present, seq]. present=TRUE => a live row. present=FALSE with seq>0 => a    *)
(* TOMBSTONE (blocks a stale lower-seq INSERT via the strict-> guard in         *)
(* ApplyPresent). present=FALSE with seq=0 (NoSeq) => truly ABSENT (a fresh     *)
(* INSERT of any seq wins). Reap is exactly the tombstone->absent transition.  *)
(*                                                                           *)
(* KEY FIDELITY NOTE ON THE JUDGE/WRITE RACE. In the real code the sweep does  *)
(* an :ets.select (judge: routes-away + source-agrees) and then a seq-guarded  *)
(* :ets.select_replace (write: only if still :present at the SAME seq). The    *)
(* only thing that can change between judge and write is the ROW (occupied/4    *)
(* and vacant_batch/4 write ETS directly from :erpc workers); view[r] cannot   *)
(* change, because the sweep runs to completion inside one coordinator         *)
(* handle_info and the committed view only moves in another handle_info. A     *)
(* single atomic DropStale step is therefore FAITHFUL: any concurrent claim is *)
(* a separate Deliver* step ordered either before this one (higher seq => the  *)
(* present/seq precondition here fails => no-op, matching the guarded          *)
(* select_replace) or after it (a fresh higher-seq occupied/snapshot overwrites *)
(* the tombstone via ApplyPresent's strict >, matching the live re-claim        *)
(* surviving). No two-step split is needed to expose the race.                 *)
(*****************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS Nodes, MaxSeq
ASSUME MaxSeq \in Nat
NoSeq == 0

VARIABLES
  up, holds, view, round, occ, mv, owed, seqCtr, msgs

vars == <<up, holds, view, round, occ, mv, owed, seqCtr, msgs>>

--------------------------------------------------------------------------------
Router(V) == CHOOSE n \in V : \A m \in V : n <= m

Ready(r) ==
  /\ view[r] # {}
  /\ \A m \in view[r] : \/ m = r
                        \/ /\ mv[r][m].known
                           /\ mv[r][m].hv = view[r]

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

--------------------------------------------------------------------------------
Init ==
  /\ up     = [n \in Nodes |-> TRUE]
  /\ holds  = [n \in Nodes |-> FALSE]
  /\ view   = [n \in Nodes |-> {n}]
  /\ round  = [n \in Nodes |-> NoRound]
  /\ occ    = [r \in Nodes |-> [s \in Nodes |-> [present |-> FALSE, seq |-> NoSeq]]]
  /\ mv     = [r \in Nodes |-> [s \in Nodes |-> [known |-> FALSE, hv |-> {}, seq |-> NoSeq]]]
  /\ owed   = [n \in Nodes |-> {}]
  /\ seqCtr = [n \in Nodes |-> 0]
  /\ msgs   = {}

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
  /\ UNCHANGED <<up, view, round, mv, owed, msgs>>

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
  /\ UNCHANGED <<up, view, round, mv, owed>>

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
  /\ UNCHANGED <<up, holds, mv, owed, msgs>>

NodeDown(n) ==
  /\ up[n]
  /\ \E k \in Nodes : k # n /\ up[k]
  /\ up' = [up EXCEPT ![n] = FALSE]
  /\ UNCHANGED <<holds, view, round, occ, mv, owed, seqCtr, msgs>>

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
  /\ mv'   = [mv EXCEPT ![n][d] = [known |-> FALSE, hv |-> {}, seq |-> NoSeq]]
  /\ owed' = [owed EXCEPT ![n] = owed[n] \ {d}]
  /\ UNCHANGED <<up, holds, msgs>>

--------------------------------------------------------------------------------
SelfClaim(s) ==
  /\ up[s] /\ holds[s] /\ view[s] # {}
  /\ Router(view[s]) = s
  /\ CanBump(s)
  /\ seqCtr' = [seqCtr EXCEPT ![s] = Bump(s)]
  /\ occ' = [occ EXCEPT ![s][s] =
        IF Bump(s) > occ[s][s].seq THEN [present |-> TRUE, seq |-> Bump(s)]
        ELSE occ[s][s]]
  /\ UNCHANGED <<up, holds, view, round, mv, owed, msgs>>

SendSnapshot(s, r) ==
  /\ up[s] /\ holds[s] /\ view[s] # {}
  /\ ~round[s].active
  /\ r \in view[s] /\ r # s
  /\ Router(view[s]) = r
  /\ CanBump(s)
  /\ seqCtr' = [seqCtr EXCEPT ![s] = Bump(s)]
  /\ owed' = [owed EXCEPT ![s] = owed[s] \cup {r}]
  /\ msgs' = msgs \cup {SnapshotMsg(s, r, view[s], Bump(s))}
  /\ UNCHANGED <<up, holds, view, round, occ, mv>>

SendMarker(s, m) ==
  /\ up[s] /\ view[s] # {}
  /\ ~round[s].active
  /\ m \in view[s] /\ m # s
  /\ m \notin owed[s]
  /\ ~(holds[s] /\ Router(view[s]) = m)
  /\ CanBump(s)
  /\ seqCtr' = [seqCtr EXCEPT ![s] = Bump(s)]
  /\ msgs' = msgs \cup {MarkerMsg(s, m, view[s], Bump(s))}
  /\ UNCHANGED <<up, holds, view, round, occ, mv, owed>>

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
  /\ UNCHANGED <<up, holds, view, round, mv, owed, seqCtr>>

DeliverSnapshot(msg) ==
  /\ msg \in msgs /\ msg.t = "snapshot"
  /\ occ' = [occ EXCEPT ![msg.dst][msg.src] = ApplyPresent(msg.dst, msg.src, msg.seq)]
  /\ mv'  = [mv  EXCEPT ![msg.dst][msg.src] = ApplyMV(msg.dst, msg.src, msg.hv, msg.seq)]
  /\ owed' = [owed EXCEPT ![msg.src] = owed[msg.src] \ {msg.dst}]
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<up, holds, view, round, seqCtr>>

DeliverMarker(msg) ==
  /\ msg \in msgs /\ msg.t = "marker"
  /\ mv' = [mv EXCEPT ![msg.dst][msg.src] = ApplyMV(msg.dst, msg.src, msg.hv, msg.seq)]
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<up, holds, view, round, occ, owed, seqCtr>>

--------------------------------------------------------------------------------
(* NEW: the occupancy GC sweep and tombstone reap.                            *)

\* source_agrees?/3 : our own rows are always judgeable; a peer's row is
\* judgeable only once the peer has announced OUR view AND the row's seq does
\* not exceed the watermark carried by that announcement (occupied/vacant write
\* the table straight from :erpc workers and never touch member_views, so the
\* table can be AHEAD of member_views).
SourceAgrees(r, s) ==
  \/ s = r
  \/ /\ mv[r][s].known
     /\ mv[r][s].hv = view[r]
     /\ occ[r][s].seq <= mv[r][s].seq

\* drop_stale_router_entries: downgrade a :present row to a TOMBSTONE at its
\* EXISTING seq when the source agrees with our committed view and the group no
\* longer routes to us under that view. Atomic == faithful (see header). Only a
\* :present row is touched; an existing tombstone is left alone (else its GC
\* clock would be refreshed forever).
DropStale(r, s) ==
  /\ up[r]
  /\ view[r] # {}
  /\ occ[r][s].present
  /\ Router(view[r]) # r
  /\ SourceAgrees(r, s)
  /\ occ' = [occ EXCEPT ![r][s] = [present |-> FALSE, seq |-> occ[r][s].seq]]
  /\ UNCHANGED <<up, holds, view, round, mv, owed, seqCtr, msgs>>

\* reap_tombstones: hard-delete a tombstone (present=FALSE, seq>0) back to
\* truly-absent. Faithful to the retention-window design: only when the key is
\* QUIESCENT (no in-flight message could still land for {r,s}), modeling
\* "window outlasts every orphaned RPC". Present rows and already-absent rows
\* are never reaped.
Reap(r, s) ==
  /\ ~occ[r][s].present
  /\ occ[r][s].seq # NoSeq
  /\ \A m \in msgs : ~(m.dst = r /\ m.src = s)
  /\ occ' = [occ EXCEPT ![r][s] = [present |-> FALSE, seq |-> NoSeq]]
  /\ UNCHANGED <<up, holds, view, round, mv, owed, seqCtr, msgs>>

--------------------------------------------------------------------------------
Next ==
  \/ \E n \in Nodes : HolderJoin(n)
  \/ \E n \in Nodes : HolderLeave(n)
  \/ \E n, m \in Nodes : Discover(n, m)
  \/ \E n \in Nodes : Commit(n)
  \/ \E n \in Nodes : NodeDown(n)
  \/ \E n, d \in Nodes : DetectDown(n, d)
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

\* Same safety property: no missed delivery.
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

\* Bound in-flight messages for tractable bounded search (used at 4 nodes).
MsgBound == Cardinality(msgs) <= 3

================================================================================
