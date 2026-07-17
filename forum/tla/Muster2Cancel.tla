---------------------------- MODULE Muster2Cancel ----------------------------
(*****************************************************************************)
(* GROW-THEN-SHRINK-BACK cancel finding (the bug fixed by cancel_view_change  *)
(* in lib/forum/muster/scope.ex). A node grows its view, PREPAREs the old-    *)
(* view members (invalidating their member_views entry for it at the round's  *)
(* seq), then the growth peer leaves again BEFORE the round commits, so        *)
(* membership is back to the committed view and the round is CANCELLED. An old- *)
(* view member that already acked is left invalidated at a seq ABOVE the        *)
(* cancelling node's committed view_seq, so a bare heartbeat marker (which      *)
(* carries the lower view_seq) can never re-establish agreement: that member    *)
(* stays :converging forever in an otherwise-stable cluster.                    *)
(*                                                                           *)
(* WHY MODULE Muster2Live DOES NOT CATCH THIS. Muster2Live models the periodic *)
(* re-announce (`SendMarker`) with a FRESH per-message seq (`Bump(s)`), so a    *)
(* heartbeat marker always eventually OUT-SEQS a stale invalidation and heals   *)
(* it -- the exact failure is abstracted away. In the real system the heartbeat *)
(* marker carries the node's COMMITTED `view_seq` (scope.ex announce_view),     *)
(* which is NOT advanced merely by running a round, while the prepare           *)
(* invalidation is stamped at `next_seq()` (> view_seq). This module makes that *)
(* distinction explicit:                                                        *)
(*                                                                           *)
(*   * `viewSeq[n]` -- the committed view generation, advanced ONLY at Commit   *)
(*     (and, with the fix, at cancel). This is what a heartbeat marker carries. *)
(*   * A round's prepare invalidation is stamped at the round seq (a fresh      *)
(*     Bump taken at Discover, hence strictly ABOVE viewSeq[n]).                *)
(*   * `Heartbeat(s)` (fair) re-announces markers carrying `viewSeq[s]`, NOT a  *)
(*     fresh bump. This is the periodic announce_view.                          *)
(*                                                                           *)
(* THE FIX is a CONSTANT `Fix`. When a round is cancelled (DetectDown drops it  *)
(* because membership returned to the committed view), Fix=TRUE bumps           *)
(* `viewSeq[n]` past the round seq (mirroring cancel_view_change's              *)
(* `view_seq: next_seq()` + re-announce). Fix=FALSE is the pre-fix code.        *)
(*                                                                           *)
(* Run with -deadlock (quiescence is expected, not a bug). CONFIRMED results     *)
(* (Nodes={1,2,3}, MaxSeq=3, StateConstraint bound):                            *)
(*   Fix=FALSE (Muster2Cancel.cfg):                                             *)
(*     NoStranded VIOLATED in ~4s (trace: 1,2 pair -> 1 grows toward 3 -> 3     *)
(*     down -> 1 cancels -> 2's ack strands 2 for 1 permanently);              *)
(*     Repair (liveness) VIOLATED (~2min): infinite heartbeat loop, never heals.*)
(*   Fix=TRUE  (Muster2Cancel_fixed.cfg):                                       *)
(*     NoStranded holds (exhaustive, ~1.9M states, ~30s);                       *)
(*     Repair holds (bounded, ~20min).                                          *)
(* NoStranded is the crisp reproduction; the liveness check is far heavier      *)
(* because `msgs` accumulates -- see StateConstraint. For a quick pass, check    *)
(* NoStranded alone against the fairness-free `Spec`.                            *)
(*                                                                           *)
(* Scope: this module tracks ONLY the agreement/readiness axis (mv, view,       *)
(* round). Occupancy / NoMissedDelivery are covered by MODULE Muster2 /         *)
(* Muster2Live and omitted here to keep the seq axis in focus.                  *)
(*****************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS Nodes, MaxSeq, Fix
ASSUME MaxSeq \in Nat
ASSUME Fix \in BOOLEAN
NoSeq == 0

VARIABLES
  up, view, round, mv, seqCtr, viewSeq, msgs

vars == <<up, view, round, mv, seqCtr, viewSeq, msgs>>

--------------------------------------------------------------------------------
Router(V) == CHOOSE n \in V : \A m \in V : n <= m

\* Agreement-only readiness: every committed-view member (other than self) has a
\* known member-view stamped for the current committed view.
Ready(r) ==
  /\ view[r] # {}
  /\ \A m \in view[r] : \/ m = r
                        \/ /\ mv[r][m].known
                           /\ mv[r][m].hv = view[r]

CanBump(s) == seqCtr[s] < MaxSeq
Bump(s)    == seqCtr[s] + 1

\* The view a node is currently trying to reach.
Desired(n) == IF round[n].active THEN round[n].target ELSE view[n]

PrepareMsg(s, r, tgt, q) ==
  [t |-> "prepare", src |-> s, dst |-> r, tgt |-> tgt, seq |-> q]
MarkerMsg(s, r, hv, q) ==
  [t |-> "marker", src |-> s, dst |-> r, hv |-> hv, seq |-> q]

NoRound == [active |-> FALSE, target |-> {}, awaiting |-> {}, seq |-> NoSeq]

ApplyMV(r, s, hv, q) ==
  IF q > mv[r][s].seq THEN [known |-> TRUE, hv |-> hv, seq |-> q] ELSE mv[r][s]

--------------------------------------------------------------------------------
Init ==
  /\ up      = [n \in Nodes |-> TRUE]
  /\ view    = [n \in Nodes |-> {n}]
  /\ round   = [n \in Nodes |-> NoRound]
  /\ mv      = [r \in Nodes |-> [s \in Nodes |-> [known |-> FALSE, hv |-> {}, seq |-> NoSeq]]]
  /\ seqCtr  = [n \in Nodes |-> 0]
  /\ viewSeq = [n \in Nodes |-> 0]
  /\ msgs    = {}

--------------------------------------------------------------------------------
(* CHURN (seq-consuming, UNFAIR). *)

\* Discover a live peer -> start (or SUPERSEDE) a prepare round toward the grown
\* target. The round seq is a FRESH Bump, hence strictly above viewSeq[n]: this
\* is why the invalidation it writes on old-view members out-ranks any heartbeat
\* marker (which carries viewSeq[n]) until a Commit/cancel advances viewSeq.
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
        /\ msgs' = msgs \cup { PrepareMsg(n, r, newTarget, Bump(n)) : r \in audience }
  /\ UNCHANGED <<up, view, mv, viewSeq>>

NodeDown(n) ==
  /\ up[n]
  /\ \E k \in Nodes : k # n /\ up[k]
  /\ up' = [up EXCEPT ![n] = FALSE]
  /\ UNCHANGED <<view, round, mv, seqCtr, viewSeq, msgs>>

--------------------------------------------------------------------------------
(* CONVERGENCE-DRIVING (FAIR). *)

\* A peer processed our prepare and acked: it INVALIDATES its member-view for us
\* (known := FALSE), seq-stamped at the round seq. A lower-seq marker cannot undo
\* it. Clears the peer from awaiting if it matches our current round.
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
  /\ UNCHANGED <<up, view, seqCtr, viewSeq>>

\* Every old-view member acked -> swap the committed view and advance viewSeq to a
\* FRESH stamp (strictly above the round seq). Subsequent heartbeat markers now
\* carry this higher seq, so they out-rank the invalidation and re-establish
\* agreement on the new view. (This is do_rebalance's `view_seq: snapshot_seq`.)
Commit(n) ==
  /\ up[n]
  /\ round[n].active
  /\ round[n].awaiting = {}
  /\ LET ns == Bump(n) IN
       /\ view'    = [view EXCEPT ![n] = round[n].target]
       /\ round'   = [round EXCEPT ![n].active = FALSE]
       /\ seqCtr'  = [seqCtr EXCEPT ![n] = ns]
       /\ viewSeq' = [viewSeq EXCEPT ![n] = ns]
  /\ UNCHANGED <<up, mv, msgs>>

\* Detect a dead peer. Three cases:
\*   * viewChanged (d was a committed member): a real SHRINK -- adopt the smaller
\*     view and advance viewSeq (do_rebalance's shrink path).
\*   * round active, target still differs after pruning d: continue the round with
\*     the pruned target (a mid-round shrink; keeps the round's seq).
\*   * round active, pruning d returns the target to the committed view: CANCEL.
\*     There is no ring to swap. PRE-FIX (Fix=FALSE) this just drops the round --
\*     leaving every acked old-view member invalidated for us at the round seq,
\*     above our unchanged viewSeq. FIX (Fix=TRUE) advances viewSeq past the round
\*     seq (cancel_view_change), so the heartbeat can heal them.
DetectDown(n, d) ==
  /\ up[n] /\ ~up[d] /\ n # d
  /\ d \in (view[n] \cup round[n].target \cup round[n].awaiting)
  /\ LET nv         == view[n] \ {d}
         nt         == round[n].target \ {d}
         viewChanged == nv # view[n]
         cancel      == round[n].active /\ nt = nv
         doBump      == viewChanged \/ (cancel /\ Fix)
         ns          == Bump(n)
     IN /\ view'    = [view EXCEPT ![n] = nv]
        /\ round'   = [round EXCEPT ![n] =
              IF round[n].active /\ nt # nv
              THEN [active |-> TRUE, target |-> nt,
                    awaiting |-> round[n].awaiting \ {d}, seq |-> round[n].seq]
              ELSE NoRound]
        /\ seqCtr'  = IF doBump THEN [seqCtr  EXCEPT ![n] = ns] ELSE seqCtr
        /\ viewSeq' = IF doBump THEN [viewSeq EXCEPT ![n] = ns] ELSE viewSeq
        /\ mv'      = [mv EXCEPT ![n][d] = [known |-> FALSE, hv |-> {}, seq |-> NoSeq]]
  /\ UNCHANGED <<up, msgs>>

\* Periodic re-announce (announce_view). Emits markers to every OTHER committed
\* member carrying our COMMITTED view (hv = view[s]) at our COMMITTED viewSeq[s]
\* -- NOT a fresh per-message seq. Idempotent, so fairness does not cause churn.
\* Skipped while a round is in flight (announce_view asserts nothing in
\* transition).
Heartbeat(s) ==
  /\ up[s] /\ ~round[s].active
  /\ \E m \in view[s] : m # s
  /\ msgs' = msgs \cup { MarkerMsg(s, m, view[s], viewSeq[s]) : m \in view[s] \ {s} }
  /\ UNCHANGED <<up, view, round, mv, seqCtr, viewSeq>>

DeliverMarker(msg) ==
  /\ msg \in msgs /\ msg.t = "marker"
  /\ up[msg.dst]
  /\ mv' = [mv EXCEPT ![msg.dst][msg.src] = ApplyMV(msg.dst, msg.src, msg.hv, msg.seq)]
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<up, view, round, seqCtr, viewSeq>>

--------------------------------------------------------------------------------
Next ==
  \/ \E n, m \in Nodes : Discover(n, m)
  \/ \E n \in Nodes : Commit(n)
  \/ \E n \in Nodes : NodeDown(n)
  \/ \E n, d \in Nodes : DetectDown(n, d)
  \/ \E s \in Nodes : Heartbeat(s)
  \/ \E msg \in msgs : DeliverPrepare(msg)
  \/ \E msg \in msgs : DeliverMarker(msg)

\* Delivery fairness is PER-LINK (src,dst), not a single WF over "\E msg". A coarse
\* WF(\E msg : DeliverMarker(msg)) is satisfied by delivering ANY message, so a
\* heartbeat that endlessly re-emits and re-delivers an already-applied marker can
\* starve the ONE marker that still needs to land -- a model artifact, not a real
\* stall (the real transport delivers every link independently). Quantifying WF
\* per (src,dst) forces the healing marker to be delivered.
Fairness ==
  /\ \A n \in Nodes : WF_vars(Commit(n))
  /\ \A n, d \in Nodes : WF_vars(DetectDown(n, d))
  /\ \A s \in Nodes : WF_vars(Heartbeat(s))
  /\ \A s, r \in Nodes :
       WF_vars(\E msg \in msgs :
         msg.t = "prepare" /\ msg.src = s /\ msg.dst = r /\ DeliverPrepare(msg))
  /\ \A s, r \in Nodes :
       WF_vars(\E msg \in msgs :
         msg.t = "marker" /\ msg.src = s /\ msg.dst = r /\ DeliverMarker(msg))

LiveSpec == Init /\ [][Next]_vars /\ Fairness

\* Fairness-free spec, for a fast NoStranded (safety) check without building the
\* full state graph for temporal checking.
Spec == Init /\ [][Next]_vars

\* Bounded model checking. `msgs` is an accumulating SET of idempotent re-announce
\* markers, so the raw state space is unbounded for exhaustive checking; bound the
\* seq range and the in-flight message count. The bug reproduces at tiny bounds
\* (the pre-fix counterexample has |msgs| <= 1 and seqCtr <= 3), so this slice is
\* ample to both hit the violation (Fix=FALSE) and gain confidence in the fix
\* (Fix=TRUE).
StateConstraint ==
  /\ \A n \in Nodes : seqCtr[n] <= MaxSeq + 1
  /\ Cardinality(msgs) <= 2

--------------------------------------------------------------------------------
(* SAFETY: the crisp characterization of the stranded state. A member r holds an *)
(* invalidation for an up peer s (~known) stamped ABOVE s's committed viewSeq,    *)
(* while s's round is quiet and both sit on the same committed view. In this      *)
(* state no heartbeat from s (carrying viewSeq[s]) can ever out-seq the           *)
(* invalidation -> permanent divergence. Fix=FALSE reaches it; Fix=TRUE does not. *)
Stranded(s, r) ==
  /\ up[s] /\ up[r] /\ s # r
  /\ ~round[s].active
  /\ view[s] = view[r]
  /\ r \in view[s]
  /\ ~mv[r][s].known
  /\ mv[r][s].seq > viewSeq[s]

NoStranded == \A s, r \in Nodes : ~Stranded(s, r)

--------------------------------------------------------------------------------
(* LIVENESS: two committed peers on the same view eventually agree (the member-  *)
(* view is re-established), unless a node dies or the views legitimately diverge  *)
(* again. This is the convergence obligation the cancel path must preserve.       *)
Repair ==
  \A s, r \in Nodes :
    ( /\ up[s] /\ up[r] /\ s # r
      /\ ~round[s].active
      /\ view[s] = view[r]
      /\ r \in view[s]
      /\ ~mv[r][s].known )
    ~> ( \/ mv[r][s].known
         \/ ~up[s] \/ ~up[r]
         \/ view[s] # view[r] )

================================================================================
