------------------------------ MODULE Muster2Delta ------------------------------
(*****************************************************************************)
(* MODULE Muster2Multi (the multi-group B1 model) extended to model the       *)
(* rebalance snapshot SELECTION faithfully: the delta-vs-full choice and the  *)
(* add-only apply that Muster2Multi abstracted away (its "sub-gap").          *)
(*                                                                           *)
(* WHAT Muster2Multi ABSTRACTED (and this closes). Muster2Multi's SendSnapshot *)
(* always sent GroupsFor(s,view,r) -- the COMPLETE set of held groups routing *)
(* to r -- and DeliverSnapshot was add-only with only a per-ROW seq guard. So *)
(* it checked "full content, add-only apply", a state that matches NEITHER    *)
(* real path and can never omit a needed group. The real code (scope.ex       *)
(* do_rebalance, ~L1112-1169) instead computes, per rebalance:                *)
(*                                                                           *)
(*   groups_to_reannounce = held groups whose ROUTER CHANGED vs the previous  *)
(*                          ring generation (find_historical_node(_,_,1));    *)
(*   changed_routers      = routers that gained >=1 such moved group;         *)
(*   per changed router r:                                                    *)
(*     FULL  (receive_node_state, WIPE+replace) when r is NEW to the view     *)
(*           this round (r not in old_members) OR r is still owed a PREVIOUS   *)
(*           round's snapshot (owed_snapshots) -- no trustworthy baseline;    *)
(*           payload = ALL held groups routing to r.                          *)
(*     DELTA (apply_delta, ADD-ONLY upsert) otherwise -- r was a member and    *)
(*           acked our last round, so its rows for us match the PREVIOUS ring  *)
(*           generation; payload = only the groups that moved IN this round.   *)
(*                                                                           *)
(* Both apply paths are guarded WHOLESALE by a per-source watermark            *)
(* (applied_snapshot_seq): a snapshot/delta whose round seq is not strictly    *)
(* greater than the highest already applied from that source is a stale,       *)
(* reordered round and is DROPPED ENTIRELY (all its adds). This model adds     *)
(* `appliedSeq[r][s]` for that watermark; Muster2Multi had only per-row guards.*)
(*                                                                           *)
(* THE INVARIANT UNDER TEST. A DELTA is add-only and carries only this round's *)
(* moved groups; it is correct ONLY IF r's rows for s already contain every    *)
(* group s holds routing to r that did NOT move this round (the "previous      *)
(* generation baseline"). The owed_snapshots gate is meant to guarantee this:  *)
(* a delta is sent only to a router that ACKED our previous round (so it       *)
(* applied that round's data), and any round still in flight forces a FULL.    *)
(* Combined with the wholesale watermark, could a delta ever leave a router    *)
(* missing a needed group? That question is exactly NoMissedDelivery here.     *)
(*                                                                           *)
(* MODELING CHOICES (soundness for the UNDER-delivery property):              *)
(*  * Emission is BOUND to the commit (Commit for grow, DetectDown for shrink),*)
(*    because groups_to_reannounce is computed against the PREVIOUS committed   *)
(*    view -- a per-round quantity. view[n] holds the last committed view, so   *)
(*    at a commit oldV = view[n], newV = target: this is find_historical vs    *)
(*    find_node exactly. Both grow and shrink funnel through do_rebalance in    *)
(*    the code, so both emit here. The standalone SendSnapshot of Muster2Multi *)
(*    is REMOVED (there is no periodic occupancy re-send in the code; data is   *)
(*    asserted at join, at self-fold, and at rebalance -- all modeled).        *)
(*  * The FULL wipe is modeled faithfully but is safety-NEUTRAL for            *)
(*    NoMissedDelivery: a full payload is COMPLETE, so wiping non-payload rows  *)
(*    only removes rows that are correctly absent (over-delivery, ignored).    *)
(*    The DELTA add-only path is the one that can under-deliver, so it is the   *)
(*    focus.                                                                   *)
(*  * The occupancy GC sweep (drop_stale_router_entries, Muster3) is NOT       *)
(*    modeled. Omitting it is a sound OVER-approximation for under-delivery:    *)
(*    not sweeping only leaves MORE present rows, so a router's baseline is a   *)
(*    superset of the real one; if a delta on top of a superset baseline never *)
(*    misses, the real (swept) baseline cannot miss either. The delta risk is  *)
(*    a MISSING add, never an over-eager remove.                              *)
(*                                                                           *)
(* Setting Groups to a singleton + RingRank[g]=identity still recovers the    *)
(* single-group story (delta selection then rarely fires, since one group      *)
(* rarely changes router without the router joining/leaving).                  *)
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
  up, holds, view, round, occ, mv, owed, seqCtr, msgs, appliedSeq

vars == <<up, holds, view, round, occ, mv, owed, seqCtr, msgs, appliedSeq>>

--------------------------------------------------------------------------------
Router(g, V) == CHOOSE n \in V : \A m \in V : RingRank[g][n] <= RingRank[g][m]

Ready(r) ==
  /\ view[r] # {}
  /\ \A m \in view[r] : \/ m = r
                        \/ /\ mv[r][m].known
                           /\ mv[r][m].hv = view[r]

CanDecide(r, senderView) == Ready(r) /\ view[r] = senderView
Present(r, g) == { s \in Nodes : occ[r][g][s].present }

CanBump(s) == seqCtr[s] < MaxSeq
Bump(s)    == seqCtr[s] + 1

Desired(n) == IF round[n].active THEN round[n].target ELSE view[n]

HoldsForRouter(n, V, r) == \E g \in Groups : holds[n][g] /\ Router(g, V) = r
GroupsFor(n, V, r) == { g \in Groups : holds[n][g] /\ Router(g, V) = r }

--------------------------------------------------------------------------------
(* Rebalance-snapshot SELECTION (do_rebalance, scope.ex ~L1112-1169), for a    *)
(* node n moving its committed view from oldV to newV.                          *)

\* All held groups routing to r under newV (a FULL snapshot's payload).
AllHeldTo(n, newV, r) == { g \in Groups : holds[n][g] /\ Router(g, newV) = r }

\* Groups n holds that route to r under newV but did NOT route to r before
\* (moved IN this round; a DELTA's payload). old_dest = Router(g,oldV) =
\* find_historical_node(_,_,1).
MovedIn(n, oldV, newV, r) ==
  { g \in Groups : /\ holds[n][g]
                   /\ Router(g, newV) = r
                   /\ Router(g, oldV) # r }

\* Routers (other than n) that gained >=1 moved group: the only ones notified.
ChangedRouters(n, oldV, newV) ==
  { r \in newV : r # n /\ MovedIn(n, oldV, newV, r) # {} }

\* FULL when r is new to the view this round OR still owed a previous snapshot;
\* DELTA otherwise. (owedSet is the PRE-round owed set, faithful to the code
\* deciding targets from state.owed_snapshots before updating it.)
IsFull(n, oldV, r, owedSet) == (r \notin oldV) \/ (r \in owedSet)

SnapKind(n, oldV, r, owedSet) == IF IsFull(n, oldV, r, owedSet) THEN "full" ELSE "delta"

SnapPayload(n, oldV, newV, r, owedSet) ==
  IF IsFull(n, oldV, r, owedSet) THEN AllHeldTo(n, newV, r)
                                 ELSE MovedIn(n, oldV, newV, r)

SnapshotMsg(s, r, gs, kind, hv, q) ==
  [t |-> "snapshot", src |-> s, dst |-> r, grps |-> gs, kind |-> kind, hv |-> hv, seq |-> q]

\* The set of snapshot messages n dispatches this round (one per changed remote
\* router), all stamped with the round's single snapshot seq q.
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

--------------------------------------------------------------------------------
Init ==
  /\ up     = [n \in Nodes |-> TRUE]
  /\ holds  = [n \in Nodes |-> [g \in Groups |-> FALSE]]
  /\ view   = [n \in Nodes |-> {n}]
  /\ round  = [n \in Nodes |-> NoRound]
  /\ occ    = [r \in Nodes |-> [g \in Groups |-> [s \in Nodes |->
                  [present |-> FALSE, seq |-> NoSeq]]]]
  /\ mv     = [r \in Nodes |-> [s \in Nodes |-> [known |-> FALSE, hv |-> {}, seq |-> NoSeq]]]
  /\ owed   = [n \in Nodes |-> {}]
  /\ seqCtr = [n \in Nodes |-> 0]
  /\ msgs   = {}
  /\ appliedSeq = [r \in Nodes |-> [s \in Nodes |-> NoSeq]]

--------------------------------------------------------------------------------
(* Group-membership churn. Becoming a holder is atomic with claiming on that    *)
(* group's committed-view router (join/3: local path writes the row in-call,     *)
(* remote path registers only after the :occupied ack).                         *)

HolderJoin(n, g) ==
  /\ up[n] /\ ~holds[n][g] /\ view[n] # {}
  /\ CanBump(n)
  /\ LET r == Router(g, view[n]) IN
       /\ holds' = [holds EXCEPT ![n][g] = TRUE]
       /\ seqCtr' = [seqCtr EXCEPT ![n] = Bump(n)]
       /\ occ' = [occ EXCEPT ![r][g][n] =
             IF Bump(n) > occ[r][g][n].seq THEN [present |-> TRUE, seq |-> Bump(n)]
             ELSE occ[r][g][n]]
  /\ UNCHANGED <<up, view, round, mv, owed, msgs, appliedSeq>>

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
  /\ UNCHANGED <<up, view, round, mv, owed, appliedSeq>>

--------------------------------------------------------------------------------
(* Cluster-view churn: the B1 prepare round (group-independent) + commit, which  *)
(* now emits the per-router full/delta snapshots.                                *)

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
  /\ UNCHANGED <<up, holds, view, occ, mv, owed, appliedSeq>>

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
  /\ UNCHANGED <<up, holds, view, occ, owed, seqCtr, appliedSeq>>

\* Commit the grown view. Faithful to do_rebalance: swap the ring, re-assert local
\* self rows for every held group now routing to self at ONE snapshot seq, dispatch
\* per-router full/delta snapshots at that same seq, and register the owed targets.
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
  /\ UNCHANGED <<up, holds, mv, appliedSeq>>

NodeDown(n) ==
  /\ up[n]
  /\ \E k \in Nodes : k # n /\ up[k]
  /\ up' = [up EXCEPT ![n] = FALSE]
  /\ UNCHANGED <<holds, view, round, occ, mv, owed, seqCtr, msgs, appliedSeq>>

\* Detect a dead peer d: commit the shrink immediately (do_rebalance for a pure
\* shrink). Wipe d's rows in every group + its member_views, prune d from an active
\* round, self-fold for groups now routing to self, and re-announce groups that
\* moved off d onto a survivor (full/delta, same selection).
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
  /\ mv'   = [mv EXCEPT ![n][d] = [known |-> FALSE, hv |-> {}, seq |-> NoSeq]]
  /\ UNCHANGED <<up, holds, appliedSeq>>

--------------------------------------------------------------------------------
(* Steady-state re-assert / heartbeat (no view change).                          *)

\* Self-row re-assert for a group routing to self (do_rebalance self-upsert /
\* reannounce_local_groups; harmless idempotent).
SelfClaim(s, g) ==
  /\ up[s] /\ holds[s][g] /\ view[s] # {}
  /\ Router(g, view[s]) = s
  /\ CanBump(s)
  /\ seqCtr' = [seqCtr EXCEPT ![s] = Bump(s)]
  /\ occ' = [occ EXCEPT ![s][g][s] =
        IF Bump(s) > occ[s][g][s].seq THEN [present |-> TRUE, seq |-> Bump(s)]
        ELSE occ[s][g][s]]
  /\ UNCHANGED <<up, holds, view, round, mv, owed, msgs, appliedSeq>>

\* Bare view-agreement heartbeat (announce_view marker) to a member we neither owe
\* a snapshot nor hold any group for (data doubles as the marker otherwise).
SendMarker(s, m) ==
  /\ up[s] /\ view[s] # {}
  /\ ~round[s].active
  /\ m \in view[s] /\ m # s
  /\ m \notin owed[s]
  /\ ~HoldsForRouter(s, view[s], m)
  /\ CanBump(s)
  /\ seqCtr' = [seqCtr EXCEPT ![s] = Bump(s)]
  /\ msgs' = msgs \cup {MarkerMsg(s, m, view[s], Bump(s))}
  /\ UNCHANGED <<up, holds, view, round, occ, mv, owed, appliedSeq>>

--------------------------------------------------------------------------------
DeliverVacant(msg) ==
  /\ msg \in msgs /\ msg.t = "vacant"
  /\ occ' = [occ EXCEPT ![msg.dst][msg.grp][msg.src] =
        IF msg.seq >= occ[msg.dst][msg.grp][msg.src].seq
        THEN [present |-> FALSE, seq |-> msg.seq]
        ELSE occ[msg.dst][msg.grp][msg.src]]
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<up, holds, view, round, mv, owed, seqCtr, appliedSeq>>

\* Apply a rebalance snapshot (full or delta), per {:apply_snapshot}/{:apply_delta}.
\* WHOLESALE per-source seq guard: a round not strictly newer than the highest
\* already applied from this source (appliedSeq) is dropped ENTIRELY (all its adds),
\* only removed from msgs. Otherwise:
\*   * every carried group is upserted present (per-row strict-> guard, so a newer
\*     racing claim is not lowered);
\*   * FULL additionally WIPES (tombstones) this source's rows NOT in the payload
\*     that predate the round (strict <) -- safety-neutral, since a full payload is
\*     complete; DELTA never wipes;
\*   * advance the watermark, fold the carried view marker (mv), clear owed.
DeliverSnapshot(msg) ==
  /\ msg \in msgs /\ msg.t = "snapshot"
  /\ LET r == msg.dst
         s == msg.src
     IN IF msg.seq <= appliedSeq[r][s]
        THEN /\ msgs' = msgs \ {msg}
             /\ UNCHANGED <<up, holds, view, round, occ, mv, owed, seqCtr, appliedSeq>>
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
             /\ UNCHANGED <<up, holds, view, round, seqCtr>>

DeliverMarker(msg) ==
  /\ msg \in msgs /\ msg.t = "marker"
  /\ mv' = [mv EXCEPT ![msg.dst][msg.src] =
        IF msg.seq > mv[msg.dst][msg.src].seq
        THEN [known |-> TRUE, hv |-> msg.hv, seq |-> msg.seq]
        ELSE mv[msg.dst][msg.src]]
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<up, holds, view, round, occ, owed, seqCtr, appliedSeq>>

--------------------------------------------------------------------------------
Next ==
  \/ \E n \in Nodes, g \in Groups : HolderJoin(n, g)
  \/ \E n \in Nodes, g \in Groups : HolderLeave(n, g)
  \/ \E n, m \in Nodes : Discover(n, m)
  \/ \E n \in Nodes : Commit(n)
  \/ \E n \in Nodes : NodeDown(n)
  \/ \E n, d \in Nodes : DetectDown(n, d)
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

\* NoMissedDelivery, PER GROUP (unchanged from Muster2Multi).
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
(* Non-vacuity witnesses (expect TLC to VIOLATE; a violation is the WITNESS that *)
(* the delta machinery is actually exercised). Run one at a time.                *)
(*                                                                             *)
(* CONFIRMED: W1 (NoDeltaSent) is violated at MaxSeq=4, BFS depth 10 (see       *)
(* Muster2Delta_w1.cfg) -- a delta IS dispatched, so the MaxSeq=4 safety run    *)
(* genuinely exercises the add-only path. W2/W3 below are DEEPER probes for the  *)
(* wholesale-drop and add-onto-baseline states; neither surfaced within a       *)
(* multi-minute MaxSeq=4 search, consistent with the owed-gate making a stranded *)
(* stale delta hard to reach. They are kept as documented probes, not claimed as *)
(* confirmed witnesses.                                                         *)

\* W1: a DELTA snapshot is actually dispatched (add-only path reached). Violation
\* => the delta branch of the selection fires, so the clean safety run is not
\* vacuously covering only full snapshots. CONFIRMED violated (MaxSeq=4, depth 10).
NoDeltaSent == ~ (\E m \in msgs : m.t = "snapshot" /\ m.kind = "delta")

\* W2: a snapshot/delta sits in msgs that WILL be wholesale-dropped (its round seq
\* is not newer than what its receiver already applied from that source).
\* Violation => the wholesale stale-round drop path is reachable.
NoWholesaleDrop ==
  ~ (\E m \in msgs :
        m.t = "snapshot" /\ m.seq <= appliedSeq[m.dst][m.src])

\* W3: a delta is delivered while the receiver already holds a DIFFERENT present
\* row for the same source (i.e. the delta genuinely relies on a pre-existing
\* baseline it did not itself carry). Violation => the "add onto prior baseline"
\* scenario -- the crux of delta correctness -- is reached.
NoBaselineDelta ==
  ~ (\E m \in msgs :
        /\ m.t = "snapshot" /\ m.kind = "delta"
        /\ m.seq > appliedSeq[m.dst][m.src]
        /\ \E g \in Groups :
              /\ g \notin m.grps
              /\ occ[m.dst][g][m.src].present)

\* Optional state-space bound for deeper/looser searches.
MsgBound == Cardinality(msgs) <= 3

================================================================================
