------------------------ MODULE Muster2RestartDownAsync ------------------------
(*****************************************************************************)
(* The ASYNC peer-side coordinator-pid :DOWN -- the Finding B residual that   *)
(* Muster2DeltaRestartDown collapsed to zero latency ("a documented next      *)
(* step, not yet built" in TLA_FINDINGS.md). Single-group (Finding B          *)
(* reproduces single-group, see Muster2Restart_s4.cfg), built on              *)
(* MODULE Muster2Restart.                                                     *)
(*                                                                           *)
(* WHAT THE SYNC MODEL SIMPLIFIED (all three corrected here, faithful to      *)
(* scope.ex ~L815-883 and recompute_members ~L1476):                          *)
(*                                                                           *)
(*   1. LATENCY. The :DOWN is a mailbox message at each peer; between the     *)
(*      restart and the peer PROCESSING it, the peer keeps the old            *)
(*      incarnation's agreement and can be a stale-ready router               *)
(*      (`Muster.targets` reads persistent_term/ETS directly, not the        *)
(*      coordinator mailbox). Modeled by downQ[p][n]: the set of dead         *)
(*      incarnations of n whose :DOWN p has not yet processed.                *)
(*   2. ATTRIBUTION. The handler wipes ONLY entries written by the dying pid  *)
(*      (`:ets.match_delete(occ, {{:_, peer_node}, :_, :_, pid})`, and the    *)
(*      member_views / applied_snapshot_seq pops are pid-guarded). Data       *)
(*      already re-written by the NEW incarnation survives. Modeled by an     *)
(*      `inc` stamp on every occ row / mv entry / message.                    *)
(*   3. MEMBERSHIP. `members` is derived from the `peers` PID map, so         *)
(*      processing the :DOWN when no newer incarnation of n is registered is  *)
(*      a PURE SHRINK (recompute_members -> do_rebalance): the peer drops n   *)
(*      from its committed view exactly as if n had died -- NOT merely an     *)
(*      agreement blank (what the sync model did). If a newer incarnation IS  *)
(*      already registered (its discover raced ahead of the :DOWN -- real:    *)
(*      different senders, no dist ordering), membership is unchanged and     *)
(*      only the attributed wipe happens. Modeled by regd[p][n] (the          *)
(*      incarnation of n that p currently has in `peers`, 0 = none) and the   *)
(*      Reregister action (the new incarnation's discover landing while n is  *)
(*      still in p's view; the ack piggyback is modeled as withheld --        *)
(*      mid-round / owed, the common case right after a restart -- so it      *)
(*      registers without asserting a view; the asserting variant is          *)
(*      Reregister followed by an ordinary marker).                           *)
(*                                                                           *)
(* CHANNEL ORDERING (replaces the sync model's drop-all-old-msgs):            *)
(*   * markers are sent BY the coordinator pid (announce_view runs in the     *)
(*     coordinator), and Erlang orders signals per sender/receiver pair, so   *)
(*     an incarnation's markers are delivered BEFORE its :DOWN. Enforced as   *)
(*     a guard on DeliverDown (no same-incarnation marker still in flight).   *)
(*   * prepares (note_transition), snapshots (receive_node_state) and         *)
(*     vacants are dispatched from WORKER processes / :erpc -- NOT ordered    *)
(*     with the coordinator's :DOWN (scope.ex ~L820-832 says exactly this:    *)
(*     "fresh DATA can land ... before this handler ever runs for the OLD    *)
(*     pid's DOWN" -- and symmetrically, OLD data can land after it). They    *)
(*     stay fully unordered, INCLUDING across the restart.                    *)
(*   * only discover/discover_ack register (create a monitor); markers,       *)
(*     prepares, snapshots and vacants do NOT (scope.ex: only register_peer   *)
(*     call sites are the discover/ack handlers). So a dead incarnation's     *)
(*     late DATA re-establishing state after its :DOWN gets NO second :DOWN;  *)
(*     it heals only by newest-seq-wins when the live incarnation announces.  *)
(*                                                                           *)
(* KNOWN SIMPLIFICATIONS (documented, judged benign):                         *)
(*   * Discover/Reregister register the CURRENT incarnation only (a stale     *)
(*     old-incarnation discover would monitor a dead pid -> instant :DOWN ->  *)
(*     net no-op plus a transient already covered by the pending-DOWN case).  *)
(*   * When the :DOWN pops the old pid while a newer incarnation is           *)
(*     registered and a prepare round is active, the code re-runs             *)
(*     begin_view_change (supersede, fresh seq) or cancel_view_change; here   *)
(*     the round is left unchanged (the in-flight prepares still carry their  *)
(*     invalidation; the supersede only re-stamps it at a higher seq).        *)
(*                                                                           *)
(* QUESTIONS. (a) Is NoMissedDelivery violated in the async window? (The doc  *)
(* predicts yes -- a Finding-A-class transient.) (b) Is every miss            *)
(* attributable to residue of a DEAD incarnation at the router -- either a    *)
(* still-queued :DOWN or a dead incarnation's agreement entry -- i.e. is the  *)
(* window bounded by :DOWN processing + the live incarnation's next           *)
(* announce? That is MissImpliesStaleResidue. The stronger                    *)
(* MissImpliesPendingDown (queued :DOWN only) additionally asks whether the   *)
(* unmonitored-data-channel re-assert path can extend the window PAST the     *)
(* :DOWN.                                                                     *)
(*****************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS Nodes, MaxSeq
ASSUME MaxSeq \in Nat
NoSeq == 0
MaxInc == MaxSeq + 1   \* each restart consumes a seq, so incarnations are bounded

VARIABLES
  up, holds, view, round, occ, mv, owed, seqCtr, msgs, promoted,
  inc,     \* inc[n]: n's current coordinator incarnation (1 = original)
  regd,    \* regd[p][n]: incarnation of n in p's `peers` map (0 = none)
  downQ    \* downQ[p][n]: dead incarnations of n whose :DOWN p has not processed

vars == <<up, holds, view, round, occ, mv, owed, seqCtr, msgs, promoted,
          inc, regd, downQ>>

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

\* Every message carries the writer's incarnation (the writer pid in the code).
PrepareMsg(s, r, tgt, q) ==
  [t |-> "prepare", src |-> s, dst |-> r, tgt |-> tgt, seq |-> q, inc |-> inc[s]]
VacantMsg(s, r, q)   == [t |-> "vacant",   src |-> s, dst |-> r, seq |-> q, inc |-> inc[s]]
SnapshotMsg(s, r, hv, q) ==
  [t |-> "snapshot", src |-> s, dst |-> r, hv |-> hv, seq |-> q, inc |-> inc[s]]
MarkerMsg(s, r, hv, q) ==
  [t |-> "marker",   src |-> s, dst |-> r, hv |-> hv, seq |-> q, inc |-> inc[s]]

NoRound == [active |-> FALSE, target |-> {}, awaiting |-> {}, seq |-> NoSeq]
BlankMV  == [known |-> FALSE, hv |-> {}, seq |-> NoSeq, inc |-> 0]
BlankOcc == [present |-> FALSE, seq |-> NoSeq, inc |-> 0]

--------------------------------------------------------------------------------
Init ==
  /\ up       = [n \in Nodes |-> TRUE]
  /\ holds    = [n \in Nodes |-> FALSE]
  /\ view     = [n \in Nodes |-> {n}]
  /\ round    = [n \in Nodes |-> NoRound]
  /\ occ      = [r \in Nodes |-> [s \in Nodes |-> BlankOcc]]
  /\ mv       = [r \in Nodes |-> [s \in Nodes |-> BlankMV]]
  /\ owed     = [n \in Nodes |-> {}]
  /\ seqCtr   = [n \in Nodes |-> 0]
  /\ msgs     = {}
  /\ promoted = [n \in Nodes |-> TRUE]
  /\ inc      = [n \in Nodes |-> 1]
  /\ regd     = [p \in Nodes |-> [n \in Nodes |-> 0]]
  /\ downQ    = [p \in Nodes |-> [n \in Nodes |-> {}]]

--------------------------------------------------------------------------------
(* Group-membership churn (Muster2Restart, plus inc stamps). *)

HolderJoin(n) ==
  /\ up[n] /\ ~holds[n] /\ view[n] # {}
  /\ CanBump(n)
  /\ LET r == Router(view[n]) IN
       /\ holds' = [holds EXCEPT ![n] = TRUE]
       /\ seqCtr' = [seqCtr EXCEPT ![n] = Bump(n)]
       /\ occ' = [occ EXCEPT ![r][n] =
             IF Bump(n) > occ[r][n].seq
             THEN [present |-> TRUE, seq |-> Bump(n), inc |-> inc[n]]
             ELSE occ[r][n]]
  /\ UNCHANGED <<up, view, round, mv, owed, msgs, promoted, inc, regd, downQ>>

HolderLeave(n) ==
  /\ up[n] /\ holds[n] /\ view[n] # {}
  /\ CanBump(n)
  /\ holds' = [holds EXCEPT ![n] = FALSE]
  /\ seqCtr' = [seqCtr EXCEPT ![n] = Bump(n)]
  /\ LET r == Router(view[n]) IN
       IF r = n
       THEN /\ occ' = [occ EXCEPT ![n][n] =
                   IF Bump(n) >= occ[n][n].seq
                   THEN [present |-> FALSE, seq |-> Bump(n), inc |-> inc[n]]
                   ELSE occ[n][n]]
            /\ UNCHANGED msgs
       ELSE /\ msgs' = msgs \cup {VacantMsg(n, r, Bump(n))}
            /\ UNCHANGED occ
  /\ UNCHANGED <<up, view, round, mv, owed, promoted, inc, regd, downQ>>

--------------------------------------------------------------------------------
(* Cluster-view churn. Discover registers the discovered node's CURRENT       *)
(* incarnation (the discover/ack handshake carries and monitors the pid).     *)

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
        /\ regd' = [regd EXCEPT ![n][m] = inc[m]]
  /\ UNCHANGED <<up, holds, view, occ, mv, owed, promoted, inc, downQ>>

\* The live incarnation's discover reaches p while n is STILL in p's committed
\* view (p has not yet processed the old pid's :DOWN, or never got one): p
\* registers (monitors) the new pid; membership is unchanged. The ack piggyback
\* is withheld (mid-round / owed -- the usual state right after a restart), so
\* member_views is not touched here; an asserting variant is this action
\* followed by an ordinary marker.
Reregister(p, n) ==
  /\ up[p] /\ up[n] /\ p # n
  /\ n \in view[p]
  /\ regd[p][n] # inc[n]
  /\ regd' = [regd EXCEPT ![p][n] = inc[n]]
  /\ UNCHANGED <<up, holds, view, round, occ, mv, owed, seqCtr, msgs, promoted,
                 inc, downQ>>

DeliverPrepare(msg) ==
  /\ msg \in msgs /\ msg.t = "prepare"
  /\ mv' = [mv EXCEPT ![msg.dst][msg.src] =
        IF msg.seq > mv[msg.dst][msg.src].seq
        THEN [known |-> FALSE, hv |-> {}, seq |-> msg.seq, inc |-> msg.inc]
        ELSE mv[msg.dst][msg.src]]
  /\ round' =
        IF /\ round[msg.src].active
           /\ round[msg.src].target = msg.tgt
           /\ round[msg.src].seq = msg.seq
        THEN [round EXCEPT ![msg.src].awaiting = round[msg.src].awaiting \ {msg.dst}]
        ELSE round
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<up, holds, view, occ, owed, seqCtr, promoted, inc, regd, downQ>>

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
                  THEN [occ EXCEPT ![n][n] = [present |-> TRUE, seq |-> Bump(n), inc |-> inc[n]]]
                  ELSE occ
        /\ seqCtr' = IF fold THEN [seqCtr EXCEPT ![n] = Bump(n)] ELSE seqCtr
  /\ promoted' = [promoted EXCEPT ![n] = TRUE]
  /\ UNCHANGED <<up, holds, mv, owed, msgs, inc, regd, downQ>>

NodeDown(n) ==
  /\ up[n]
  /\ \E k \in Nodes : k # n /\ up[k]
  /\ up' = [up EXCEPT ![n] = FALSE]
  /\ UNCHANGED <<holds, view, round, occ, mv, owed, seqCtr, msgs, promoted,
                 inc, regd, downQ>>

\* Real node death (permanent). Wipes all of d's rows (every incarnation is
\* dead and the node never returns), clears the registration and any queued
\* restart-:DOWNs for d (this IS d's terminal :DOWN, processed).
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
                  THEN [occ EXCEPT ![n][d] = BlankOcc,
                                   ![n][n] = [present |-> TRUE, seq |-> Bump(n), inc |-> inc[n]]]
                  ELSE [occ EXCEPT ![n][d] = BlankOcc]
        /\ seqCtr' = IF fold THEN [seqCtr EXCEPT ![n] = Bump(n)] ELSE seqCtr
  /\ mv'   = [mv EXCEPT ![n][d] = BlankMV]
  /\ owed' = [owed EXCEPT ![n] = owed[n] \ {d}]
  /\ regd' = [regd EXCEPT ![n][d] = 0]
  /\ downQ' = [downQ EXCEPT ![n][d] = {}]
  /\ promoted' = [promoted EXCEPT ![n] = TRUE]
  /\ UNCHANGED <<up, holds, msgs, inc>>

--------------------------------------------------------------------------------
(* THE RESTART. As Muster2Restart, plus: the incarnation advances; every peer  *)
(* that has the dying incarnation registered gets a :DOWN QUEUED (not applied  *)
(* -- that is the async window); in-flight messages are KEPT (worker/erpc      *)
(* channels are not ordered with the coordinator's death; the coordinator-     *)
(* sent markers are ordered by the DeliverDown guard instead). The restarting  *)
(* node's own peers map and mailbox die with the process: its own regd row     *)
(* and pending :DOWNs are cleared.                                             *)

Restart(n) ==
  /\ up[n]
  /\ CanBump(n)                          \* init consumes a seq (view_seq watermark)
  /\ view'  = [view  EXCEPT ![n] = {n}]
  /\ round' = [round EXCEPT ![n] = NoRound]
  /\ mv'    = [mv    EXCEPT ![n] = [s \in Nodes |-> BlankMV]]
  /\ owed'  = [owed  EXCEPT ![n] = {}]
  /\ promoted' = [promoted EXCEPT ![n] = FALSE]
  /\ seqCtr' = [seqCtr EXCEPT ![n] = Bump(n)]
  /\ occ' = [occ EXCEPT ![n][n] =
        IF holds[n] /\ Bump(n) > occ[n][n].seq
        THEN [present |-> TRUE, seq |-> Bump(n), inc |-> inc[n] + 1]
        ELSE occ[n][n]]
  /\ inc' = [inc EXCEPT ![n] = inc[n] + 1]
  /\ regd' = [regd EXCEPT ![n] = [m \in Nodes |-> 0]]        \* peers map lost
  /\ downQ' = [p \in Nodes |->
        IF p = n
        THEN [m \in Nodes |-> {}]                            \* own mailbox lost
        ELSE [downQ[p] EXCEPT ![n] =
                IF regd[p][n] = inc[n]                       \* p monitors the dying pid
                THEN downQ[p][n] \cup {inc[n]}
                ELSE downQ[p][n]]]
  /\ UNCHANGED <<up, holds, msgs>>

SingletonPromote(n) ==
  /\ up[n]
  /\ ~promoted[n]
  /\ view[n] = {n}
  /\ promoted' = [promoted EXCEPT ![n] = TRUE]
  /\ UNCHANGED <<up, holds, view, round, occ, mv, owed, seqCtr, msgs,
                 inc, regd, downQ>>

--------------------------------------------------------------------------------
(* PROCESSING the queued :DOWN at peer p for n's dead incarnation i.           *)
(* Guard: an incarnation's coordinator-sent MARKERS are delivered before its   *)
(* :DOWN (same sender pid -> Erlang signal order); worker-sent prepares/       *)
(* snapshots/vacants are NOT constrained.                                      *)
(* Effect (scope.ex :DOWN handler): wipe occ row / mv entry ONLY if written    *)
(* by incarnation i (pid attribution); pop the pid -- if no newer incarnation  *)
(* is registered, membership loses n: a PURE SHRINK exactly like DetectDown    *)
(* (do_rebalance via recompute_members), including the self-fold. If a newer   *)
(* incarnation is already registered, membership is unchanged (attributed      *)
(* wipe only).                                                                 *)

DeliverDown(p, n, i) ==
  /\ up[p]
  /\ i \in downQ[p][n]
  /\ ~\E m \in msgs : m.t = "marker" /\ m.src = n /\ m.dst = p /\ m.inc = i
  /\ downQ' = [downQ EXCEPT ![p][n] = downQ[p][n] \ {i}]
  /\ LET occWiped == IF occ[p][n].inc = i THEN BlankOcc ELSE occ[p][n]
         mvWiped  == IF mv[p][n].inc = i THEN BlankMV ELSE mv[p][n]
         popped   == regd[p][n] = i
         shrink   == popped /\ n \in (view[p] \cup round[p].target \cup round[p].awaiting)
     IN IF ~shrink
        THEN /\ occ' = [occ EXCEPT ![p][n] = occWiped]
             /\ mv'  = [mv  EXCEPT ![p][n] = mvWiped]
             /\ regd' = IF popped THEN [regd EXCEPT ![p][n] = 0] ELSE regd
             /\ UNCHANGED <<view, round, owed, seqCtr, promoted>>
        ELSE LET nv   == view[p] \ {n}
                 fold == holds[p] /\ nv # {} /\ Router(nv) = p
                 nt   == round[p].target \ {n}
             IN /\ (fold => CanBump(p))
                /\ view' = [view EXCEPT ![p] = nv]
                /\ round' = [round EXCEPT ![p] =
                      IF round[p].active /\ nt # nv
                      THEN [active |-> TRUE, target |-> nt,
                            awaiting |-> round[p].awaiting \ {n}, seq |-> round[p].seq]
                      ELSE NoRound]
                /\ occ' = IF fold
                          THEN [occ EXCEPT ![p][n] = occWiped,
                                           ![p][p] = [present |-> TRUE, seq |-> Bump(p), inc |-> inc[p]]]
                          ELSE [occ EXCEPT ![p][n] = occWiped]
                /\ seqCtr' = IF fold THEN [seqCtr EXCEPT ![p] = Bump(p)] ELSE seqCtr
                /\ mv'   = [mv EXCEPT ![p][n] = mvWiped]
                /\ owed' = [owed EXCEPT ![p] = owed[p] \ {n}]
                /\ regd' = [regd EXCEPT ![p][n] = 0]
                /\ promoted' = [promoted EXCEPT ![p] = TRUE]
  /\ UNCHANGED <<up, holds, msgs, inc>>

--------------------------------------------------------------------------------
(* Post-commit re-announce (inc-stamped). *)

SelfClaim(s) ==
  /\ up[s] /\ holds[s] /\ view[s] # {}
  /\ Router(view[s]) = s
  /\ CanBump(s)
  /\ seqCtr' = [seqCtr EXCEPT ![s] = Bump(s)]
  /\ occ' = [occ EXCEPT ![s][s] =
        IF Bump(s) > occ[s][s].seq
        THEN [present |-> TRUE, seq |-> Bump(s), inc |-> inc[s]]
        ELSE occ[s][s]]
  /\ UNCHANGED <<up, holds, view, round, mv, owed, msgs, promoted, inc, regd, downQ>>

SendSnapshot(s, r) ==
  /\ up[s] /\ holds[s] /\ view[s] # {}
  /\ ~round[s].active
  /\ r \in view[s] /\ r # s
  /\ Router(view[s]) = r
  /\ CanBump(s)
  /\ seqCtr' = [seqCtr EXCEPT ![s] = Bump(s)]
  /\ owed' = [owed EXCEPT ![s] = owed[s] \cup {r}]
  /\ msgs' = msgs \cup {SnapshotMsg(s, r, view[s], Bump(s))}
  /\ UNCHANGED <<up, holds, view, round, occ, mv, promoted, inc, regd, downQ>>

SendMarker(s, m) ==
  /\ up[s] /\ view[s] # {}
  /\ ~round[s].active
  /\ m \in view[s] /\ m # s
  /\ m \notin owed[s]
  /\ ~(holds[s] /\ Router(view[s]) = m)
  /\ CanBump(s)
  /\ seqCtr' = [seqCtr EXCEPT ![s] = Bump(s)]
  /\ msgs' = msgs \cup {MarkerMsg(s, m, view[s], Bump(s))}
  /\ UNCHANGED <<up, holds, view, round, occ, mv, owed, promoted, inc, regd, downQ>>

--------------------------------------------------------------------------------
ApplyPresent(r, s, q, i) ==
  IF q > occ[r][s].seq THEN [present |-> TRUE, seq |-> q, inc |-> i] ELSE occ[r][s]
ApplyTomb(r, s, q, i) ==
  IF q >= occ[r][s].seq THEN [present |-> FALSE, seq |-> q, inc |-> i] ELSE occ[r][s]
ApplyMV(r, s, hv, q, i) ==
  IF q > mv[r][s].seq THEN [known |-> TRUE, hv |-> hv, seq |-> q, inc |-> i] ELSE mv[r][s]

DeliverVacant(msg) ==
  /\ msg \in msgs /\ msg.t = "vacant"
  /\ occ' = [occ EXCEPT ![msg.dst][msg.src] =
        ApplyTomb(msg.dst, msg.src, msg.seq, msg.inc)]
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<up, holds, view, round, mv, owed, seqCtr, promoted, inc, regd, downQ>>

DeliverSnapshot(msg) ==
  /\ msg \in msgs /\ msg.t = "snapshot"
  /\ occ' = [occ EXCEPT ![msg.dst][msg.src] =
        ApplyPresent(msg.dst, msg.src, msg.seq, msg.inc)]
  /\ mv'  = [mv  EXCEPT ![msg.dst][msg.src] =
        ApplyMV(msg.dst, msg.src, msg.hv, msg.seq, msg.inc)]
  /\ owed' = [owed EXCEPT ![msg.src] = owed[msg.src] \ {msg.dst}]
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<up, holds, view, round, seqCtr, promoted, inc, regd, downQ>>

DeliverMarker(msg) ==
  /\ msg \in msgs /\ msg.t = "marker"
  /\ mv' = [mv EXCEPT ![msg.dst][msg.src] =
        ApplyMV(msg.dst, msg.src, msg.hv, msg.seq, msg.inc)]
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<up, holds, view, round, occ, owed, seqCtr, promoted, inc, regd, downQ>>

--------------------------------------------------------------------------------
Next ==
  \/ \E n \in Nodes : HolderJoin(n)
  \/ \E n \in Nodes : HolderLeave(n)
  \/ \E n, m \in Nodes : Discover(n, m)
  \/ \E p, n \in Nodes : Reregister(p, n)
  \/ \E n \in Nodes : Commit(n)
  \/ \E n \in Nodes : NodeDown(n)
  \/ \E n, d \in Nodes : DetectDown(n, d)
  \/ \E n \in Nodes : Restart(n)
  \/ \E p, n \in Nodes : \E i \in downQ[p][n] : DeliverDown(p, n, i)
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
  /\ inc \in [Nodes -> 1..MaxInc]
  /\ regd \in [Nodes -> [Nodes -> 0..MaxInc]]
  /\ downQ \in [Nodes -> [Nodes -> SUBSET (1..MaxSeq)]]

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
(* THE CHARACTERIZATION. NoMissedDelivery is EXPECTED to fail here (the async  *)
(* window is real); the question is whether every miss is bounded by dead-     *)
(* incarnation residue at the router.                                          *)

MissWitness(u, r, s) ==
  /\ up[u] /\ up[r]
  /\ view[u] # {}
  /\ Router(view[u]) = r
  /\ CanDecide(r, view[u])
  /\ up[s] /\ holds[s]
  /\ s \in view[r]
  /\ s \notin Present(r)

\* REFUTED candidate (kept as a documented witness generator): "at every miss
\* the router still has an UNPROCESSED :DOWN for a view member". VIOLATED --
\* two real extensions past the :DOWN exist: (a) the dying incarnation was
\* never registered by the router (no monitor -> no :DOWN, ever), its late
\* marker re-asserts agreement after the router registered the LIVE incarnation
\* with a WITHHELD ack piggyback (the new incarnation owes the router a
\* snapshot right after its re-grow -- scope.ex ~L743); heals when that owed
\* snapshot lands. (b) See MissImpliesStaleResidue below.
MissImpliesPendingDown ==
  \A u, r, s \in Nodes :
    MissWitness(u, r, s) =>
      \E d \in view[r] \ {r} : downQ[r][d] # {}

\* REFUTED candidate too: "at every miss the router carries residue of a DEAD
\* incarnation (queued :DOWN or dead-incarnation agreement entry)". VIOLATED by
\* a second-order shape with NO dead-incarnation residue at the router: node 1
\* restarts; peer node 2 processes the :DOWN with the new pid not yet
\* registered -> PURE SHRINK to {2}, re-homing the group onto itself; node 2's
\* pre-shrink marker (live incarnation, asserting {1,2}) then lands at the
\* restarted node 1, which meanwhile re-committed {1,2} -- node 1 is
\* stale-ready while the holder sits on {2}. The restart-triggered shrink is a
\* view change racing exactly like Finding A's discovery (and every commit here
\* has an EMPTY B1 audience -- singletons -- so the prepare gate never engages).
\* Heals when the handshake re-grows node 2 and its owed snapshot lands.
MissImpliesStaleResidue ==
  \A u, r, s \in Nodes :
    MissWitness(u, r, s) =>
      \E d \in view[r] \ {r} :
        \/ downQ[r][d] # {}
        \/ (mv[r][d].known /\ mv[r][d].inc < inc[d])

\* THE CHARACTERIZATION THAT HOLDS: every miss is an ASYMMETRIC-CONVERGENCE
\* window -- the missed holder's committed view differs from the router's
\* (the holder is mid-churn relative to the router; the router's agreement
\* about it is stale). This is precisely Finding A's class: transient and
\* self-healing (the holder's convergence back to the router's view must
\* re-announce through the B1/owed-snapshot machinery, which un-readies the
\* router or delivers the missing row). A miss between two nodes SETTLED on
\* the same committed view would be a genuinely new, non-transient bug class;
\* this invariant says restarts + async :DOWNs never produce one.
MissImpliesViewDivergence ==
  \A u, r, s \in Nodes :
    MissWitness(u, r, s) => view[s] # view[r]

--------------------------------------------------------------------------------
(* Non-vacuity probe (expect VIOLATED = witness): a Ready router coexists with  *)
(* a :DOWN still queued for one of its view members -- the async window is      *)
(* actually reached in a trusted-routing state.                                 *)
NoReadyWithPendingDown ==
  ~( \E r \in Nodes :
       /\ up[r] /\ Ready(r) /\ Cardinality(view[r]) > 1
       /\ \E d \in view[r] \ {r} : downQ[r][d] # {} )

\* Optional bound for deeper searches.
MsgBound == Cardinality(msgs) <= 3

================================================================================
