------------------------------- MODULE Muster2 -------------------------------
(*****************************************************************************)
(* B1: two-phase (prepare -> commit) view adoption on top of the Muster      *)
(* routing model. Goal: check that gating the RING SWAP on an acknowledged   *)
(* view announcement to the OLD view's members closes Finding A              *)
(* (NoMissedDelivery), while the cluster still converges (Liveness).         *)
(*                                                                           *)
(* Difference from MODULE Muster:                                            *)
(*   * `view[n]` is now the COMMITTED routing view (the ring the shards read *)
(*     and that Router/ready?/CanDecide use). It only advances via Commit.   *)
(*   * Discovering a new peer starts (or supersedes) a PREPARE round: the     *)
(*     node announces its new target view to every member of its OLD          *)
(*     committed view and must have each of them RECORD the move (a prepare   *)
(*     landing = the peer processed it = it acks) before it may Commit.       *)
(*     Only the old-committed-view members can be stale routers relative to   *)
(*     this transition (they are exactly the nodes that could hold a stale    *)
(*     member_views entry for us), so that is the whole audience.             *)
(*   * A membership change mid-round SUPERSEDES it (new target, fresh seq,    *)
(*     re-prepare); stale-seq prepares can't complete the new round.          *)
(*   * DetectDown commits the shrink immediately: wiping the dead peer's mv    *)
(*     entry already un-readies every node still on a view containing it, so  *)
(*     a shrink cannot produce a stale-ready router (only growth can).        *)
(*                                                                           *)
(* Prepare/ack is modeled as messages: dispatching a prepare adds messages;   *)
(* delivering one records the peer's member-view (seq-guarded) AND, if it     *)
(* matches the source's current round, removes the peer from `awaiting`       *)
(* (the ack, its network delay collapsed -- only ever delaying Commit, which  *)
(* is safe). This mirrors the real design: the prepare RPC is dispatched from *)
(* a worker (coordinator never blocks), the reply is the ack, and Commit runs *)
(* once every worker reported :ok.                                            *)
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

\* The view a node is currently trying to reach (its round target if a round is
\* active, otherwise its committed view).
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
(* Group-membership churn. Becoming a holder is atomic with notifying the     *)
(* current (committed-view) router -- see MODULE Muster.                      *)

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
(* Cluster-view churn. *)

\* Discover a live peer -> start or SUPERSEDE a prepare round toward the grown
\* target. Committed `view` is NOT touched here; it only moves on Commit. The
\* audience is the OLD committed view's members (the only possible stale routers
\* for this transition). A singleton (view = {n}) has an empty audience, so its
\* round is immediately committable.
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

\* A peer processed our prepare and acked. The prepare INVALIDATES the source's
\* member-view at the peer (known := FALSE), seq-stamped at the round seq: it
\* says "I am leaving my current view; stop counting me as agreeing to it" -- NOT
\* "I am on the target" (that would make the peer trust us on a view we are not
\* routing under yet, the mirror bug). A stale, lower-seq asserting marker cannot
\* override it; the peer only re-trusts us after we COMMIT and assert the new view
\* at a higher seq. If it matches our CURRENT round (target + seq) it clears the
\* peer from awaiting.
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

\* Every old-view member has recorded our move -> swap the committed view. Fold
\* in the self occupancy re-assert for a held group now routed to self (as
\* do_rebalance does, synchronously, before status leaves :rebalancing).
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

\* Detect a dead peer: commit the shrink IMMEDIATELY (no prepare round). Wiping
\* d's member-view entry un-readies us for any view containing d, so we cannot
\* remain a stale-ready router across the shrink. Also prune d from an active
\* round, and fold the self re-assert if we become our own router.
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
(* Post-commit re-announce to the (committed) router / members, same as        *)
(* MODULE Muster: snapshot (data+marker atomic) to the router we hold g for,   *)
(* bare markers to others, self-row re-assert when we are our own router.       *)

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
  /\ ~round[s].active   \* in transition: assert nothing until committed
  /\ r \in view[s] /\ r # s
  /\ Router(view[s]) = r
  /\ CanBump(s)
  /\ seqCtr' = [seqCtr EXCEPT ![s] = Bump(s)]
  /\ owed' = [owed EXCEPT ![s] = owed[s] \cup {r}]
  /\ msgs' = msgs \cup {SnapshotMsg(s, r, view[s], Bump(s))}
  /\ UNCHANGED <<up, holds, view, round, occ, mv>>

SendMarker(s, m) ==
  /\ up[s] /\ view[s] # {}
  /\ ~round[s].active   \* in transition: assert nothing until committed
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

Spec == Init /\ [][Next]_vars

--------------------------------------------------------------------------------
TypeOK ==
  /\ up \in [Nodes -> BOOLEAN]
  /\ holds \in [Nodes -> BOOLEAN]
  /\ view \in [Nodes -> SUBSET Nodes]
  /\ seqCtr \in [Nodes -> 0..MaxSeq]
  /\ owed \in [Nodes -> SUBSET Nodes]

\* Same safety property as MODULE Muster: no missed delivery.
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
