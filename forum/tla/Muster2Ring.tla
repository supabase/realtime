------------------------------ MODULE Muster2Ring ------------------------------
(*****************************************************************************)
(* MODULE Muster2 (the shipped B1 two-phase view-adoption fix) with the ONE  *)
(* asymmetry generalized: the ring router is no longer hard-wired to `min`,   *)
(* it is a CONSTANT total order `RingRank` (an injective Nodes -> Nat). This  *)
(* is the caveat-4 model: does the NoMissedDelivery proof depend on the `min` *)
(* artifact, or on the ring shape at all?                                     *)
(*                                                                           *)
(* THE RELABELING ARGUMENT (why one order is WLOG for a single group).        *)
(*   Node identities are compared NOWHERE in this spec except inside Router   *)
(*   (the sole `<=`/rank use). Init is symmetric (every node a singleton),    *)
(*   and every action quantifies over Nodes uniformly. So for any node-id     *)
(*   permutation pi, replacing RingRank by RingRank o pi^-1 yields an         *)
(*   ISOMORPHIC transition system, and NoMissedDelivery (which quantifies     *)
(*   uniformly over u,r,s) is preserved by pi. Hence the transition systems   *)
(*   for ANY two total-order rings are isomorphic by relabeling, and the      *)
(*   existing N=3 exhaustive result for RingRank = identity (= `min`, in      *)
(*   MODULE Muster2) already implies safety for EVERY single-group            *)
(*   total-order ring. Real consistent hashing IS a fixed total order per     *)
(*   group (which node is closest to g's hash), so `min` is WLOG here; the    *)
(*   genuinely-richer per-group-different-order behaviour is a MULTI-group    *)
(*   concern (caveat 2), out of scope for this single-group model.            *)
(*                                                                           *)
(*   This module exists to (a) let TLC EMPIRICALLY confirm that argument by   *)
(*   running a non-identity RingRank (guarding against a hidden asymmetry I   *)
(*   might have missed), and (b) host the deeper 4-node bounded search with    *)
(*   non-vacuity witnesses (Muster2Ring4.cfg).                                *)
(*****************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS Nodes, MaxSeq, RingRank
ASSUME MaxSeq \in Nat
\* RingRank is an injective ranking: a total order on Nodes. Router = the
\* minimum-rank node present. Identity rank reproduces MODULE Muster2 (`min`).
ASSUME RingRank \in [Nodes -> Nat]
ASSUME \A a, b \in Nodes : (a # b) => RingRank[a] # RingRank[b]
NoSeq == 0

\* Concrete ring orders (cfg picks one via `RingRank <- ...`). Config files can't
\* hold function literals, so the alternatives live here. Node id 1 is NOT the
\* top-of-ring in any of these, so the run genuinely exercises a non-`min` ring.
RingRev3  == (1 :> 3) @@ (2 :> 2) @@ (3 :> 1)                 \* N=3, node 3 top
RingShuf4 == (1 :> 2) @@ (2 :> 4) @@ (3 :> 1) @@ (4 :> 3)     \* N=4, node 3 top

VARIABLES
  up, holds, view, round, occ, mv, owed, seqCtr, msgs

vars == <<up, holds, view, round, occ, mv, owed, seqCtr, msgs>>

--------------------------------------------------------------------------------
Router(V) == CHOOSE n \in V : \A m \in V : RingRank[n] <= RingRank[m]

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
(* Non-vacuity witnesses. Each is an invariant that we EXPECT TLC to VIOLATE  *)
(* (same probe pattern as Muster2Restart_probe): a reported violation is the  *)
(* WITNESS that the search actually reached the state that makes the safety    *)
(* run meaningful rather than vacuous. Run these one at a time.               *)

\* W1: two live nodes have simultaneously-active prepare rounds. Violation =>
\* the bounded search reaches CONCURRENT/cascading prepare rounds -- the exact
\* machinery B1 introduced that only appears with >=4 nodes.
NoConcurrentRounds ==
  ~ (\E a, b \in Nodes :
        a # b /\ up[a] /\ up[b] /\ round[a].active /\ round[b].active)

\* W2: a lagging :ready router (Ready, routes its own view to itself) coexists
\* with a strictly-more-advanced live peer. Violation => the search reaches the
\* Finding-A "stale-ready router behind an advanced peer" shape that the fix
\* must render safe (so NoMissedDelivery holding here is not vacuous).
NoLaggingReadyRouter ==
  ~ (\E r, a \in Nodes :
        r # a /\ up[r] /\ up[a]
        /\ Ready(r) /\ Router(view[r]) = r
        /\ view[r] \subseteq view[a] /\ view[r] # view[a])

\* W3: some node's committed view reached size >= 3. Violation => the 4-node
\* bounded search reaches multi-hop convergence depth (a node that has grown
\* twice), not stalled at tiny views. NOTE: size >= 4 (full convergence) is
\* UNREACHABLE at MaxSeq=2 -- growing the view is a Discover, each Discover
\* spends a seq (CanBump), so 2 seq => at most 2 growths => committed view size
\* <= 3. Full 4-node convergence would need MaxSeq >= 3.
NoWideView ==
  ~ (\E n \in Nodes : Cardinality(view[n]) >= 3)

\* State-space bound for the 4-node search (a full 4-node exhaustive run is
\* infeasible). Looser than MODULE Muster2Bounded's <=2, so the search goes
\* deeper -- far enough to reach the W1/W2/W3 witnesses below.
MsgBound == Cardinality(msgs) <= 3

================================================================================
