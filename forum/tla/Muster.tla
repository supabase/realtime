-------------------------------- MODULE Muster --------------------------------
(*****************************************************************************)
(* A TLA+ model of Forum.Muster's core routing-safety story.                *)
(*                                                                           *)
(* What it models (see tla/README.md and TLA_FINDINGS.md for the full        *)
(* mapping to the Elixir code):                                              *)
(*                                                                           *)
(*   * A fixed set of Nodes. A node may permanently go down (per the user's  *)
(*     assumption "nodes CANNOT come back to life and reset their seq").     *)
(*   * ONE group `g`. Ground truth `holds[n]` = node n has >=1 local member  *)
(*     of g. This is what a broadcast to g must reach.                       *)
(*   * Per-node cluster view `view[n]` (the sorted member list, modeled as a *)
(*     set). Discovery grows a view toward the live set; a detected DOWN      *)
(*     shrinks it. The `phash2(members)` view-hash is modeled as the set      *)
(*     itself (equal sets == equal hash; we do not model hash collisions).   *)
(*   * The router for g under a view V is `Router(V)` = the minimum node id   *)
(*     in V. `min` is a faithful instance of consistent hashing for the ONE  *)
(*     property the algorithm's non-barrier paths rely on: subset-           *)
(*     monotonicity (if r routes g in V and r in V' subset of V then r routes *)
(*     g in V'). See TLA_FINDINGS.md for the caveat.                          *)
(*   * Router-role occupancy as a per-{router,source} last-writer-wins        *)
(*     register `occ[r][s] = [present, seq]`, exactly the Scope occupancy     *)
(*     table for a single group. seq is a per-source monotonic dispatch stamp.*)
(*   * The readiness barrier: `memberViews`, and derived status via Ready(r). *)
(*   * Messages over Erlang dist / erpc: occupied, vacant, snapshot, marker.  *)
(*     erpc semantics = a dispatched RPC lands at an arbitrary later time, in *)
(*     any order relative to other messages, and is NEVER cancelled (it can   *)
(*     land long after the sender gave up). Modeled as an in-flight message   *)
(*     SET that any Deliver step may drain in any order.                      *)
(*                                                                           *)
(* Safety property checked: NO MISSED DELIVERY. When a sender broadcasts to  *)
(* g and the router it targets is allowed to trust its occupancy table       *)
(* (can_decide?), every live holder of g that is a member of the shared view *)
(* is in the router's delivery set. Over-delivery (a stale entry) is safe    *)
(* and intentionally NOT flagged.                                            *)
(*****************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS Nodes,      \* set of node ids, e.g. {1, 2, 3}
          MaxSeq      \* per-source seq bound (keeps the model finite)

ASSUME MaxSeq \in Nat

NoSeq == 0

VARIABLES
  up,           \* [Nodes -> BOOLEAN]  is the node alive (down is permanent)
  holds,        \* [Nodes -> BOOLEAN]  does the node have a local member of g
  view,         \* [Nodes -> SUBSET Nodes]  the node's cluster view (incl. self)
  occ,          \* [Nodes -> [Nodes -> [present: BOOLEAN, seq: Nat]]]
                \*   occ[r][s]: router r's occupancy row for source s
  mv,           \* [Nodes -> [Nodes -> [known: BOOLEAN, hv: SUBSET Nodes, seq: Nat]]]
                \*   mv[r][s]: r's record of s's last-announced view (member_views)
  owed,         \* [Nodes -> SUBSET Nodes]  routers this source owes an in-flight snapshot
  seqCtr,       \* [Nodes -> Nat]  per-source monotonic dispatch counter
  msgs          \* set of in-flight messages (erpc / dist)

vars == <<up, holds, view, occ, mv, owed, seqCtr, msgs>>

--------------------------------------------------------------------------------
(* Helpers *)

\* Router for g under view V: smallest node id (a consistent-hash instance
\* that satisfies subset-monotonicity, see header).
Router(V) == CHOOSE n \in V : \A m \in V : n <= m

\* Does source s, under s's own current view, route g to router r?
RoutesTo(s, r) == view[s] # {} /\ Router(view[s]) = r

\* r is "ready": every member of r's view has announced a view equal to r's view.
Ready(r) ==
  /\ view[r] # {}
  /\ \A m \in view[r] :
        \/ m = r
        \/ /\ mv[r][m].known
           /\ mv[r][m].hv = view[r]

\* r may trust its occupancy table for a broadcast tagged senderView.
CanDecide(r, senderView) == Ready(r) /\ view[r] = senderView

\* The set of source nodes r currently believes hold g (present rows only).
Present(r) == { s \in Nodes : occ[r][s].present }

--------------------------------------------------------------------------------
(* Message constructors. A message is a record with a `t` tag. *)

\* Note: the first-member :occupied claim is modeled as a synchronous write
\* inside HolderJoin (the member is registered only once the router is told), so
\* there is no in-flight "occupied" message type. The remaining wire messages are
\* the async ones: vacant (flush), snapshot and marker.
VacantMsg(s, r, q)   == [t |-> "vacant",   src |-> s, dst |-> r, seq |-> q]
SnapshotMsg(s, r, hv, q) ==
  [t |-> "snapshot", src |-> s, dst |-> r, hv |-> hv, seq |-> q]
MarkerMsg(s, r, hv, q) ==
  [t |-> "marker", src |-> s, dst |-> r, hv |-> hv, seq |-> q]

--------------------------------------------------------------------------------
Init ==
  /\ up     = [n \in Nodes |-> TRUE]
  /\ holds  = [n \in Nodes |-> FALSE]
  \* Every node starts seeing only itself (fresh coordinator, ring = [node()]).
  /\ view   = [n \in Nodes |-> {n}]
  /\ occ    = [r \in Nodes |-> [s \in Nodes |-> [present |-> FALSE, seq |-> NoSeq]]]
  /\ mv     = [r \in Nodes |-> [s \in Nodes |->
                 [known |-> FALSE, hv |-> {}, seq |-> NoSeq]]]
  /\ owed   = [n \in Nodes |-> {}]
  /\ seqCtr = [n \in Nodes |-> 0]
  /\ msgs   = {}

--------------------------------------------------------------------------------
(* Ground-truth churn: group membership on a node.                            *)
(*                                                                            *)
(* Becoming a "holder" is ATOMIC with notifying the current router, faithful  *)
(* to join/3: on the local-router path join writes the occupancy self-row     *)
(* inside the same synchronous call; on the remote path the member is         *)
(* registered only AFTER the :occupied RPC is acked (the router already holds  *)
(* the row at that instant). So there is never an observable state where a     *)
(* node is a committed holder yet its current router has not been told. The    *)
(* seq is fresh (strictly greater than any prior dispatch by n), so the write  *)
(* always wins its seq guard.                                                  *)
CanBump(s) == seqCtr[s] < MaxSeq
Bump(s)    == seqCtr[s] + 1

HolderJoin(n) ==
  /\ up[n] /\ ~holds[n] /\ view[n] # {}
  /\ CanBump(n)
  /\ LET r == Router(view[n]) IN
       /\ holds' = [holds EXCEPT ![n] = TRUE]
       /\ seqCtr' = [seqCtr EXCEPT ![n] = Bump(n)]
       /\ occ' = [occ EXCEPT ![r][n] =
             IF Bump(n) > occ[r][n].seq THEN [present |-> TRUE, seq |-> Bump(n)]
             ELSE occ[r][n]]
  /\ UNCHANGED <<up, view, mv, owed, msgs>>

\* Leaving removes the local member immediately (leave/3 / a member DOWN). The
\* retraction to the router is ASYNC (cooldown + vacant flush): a self-routed
\* group is tombstoned locally (seq-guarded, not a hard delete); a remote-routed
\* group dispatches a fire-and-forget vacant that the router applies later, in
\* any order (this is where the stale-DELETE-after-fresh-INSERT race lives).
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
  /\ UNCHANGED <<up, view, mv, owed>>

--------------------------------------------------------------------------------
(* Cluster-view churn: discovery grows a view, DOWN detection shrinks it. *)

\* Node n discovers a live peer m and adds it to its view (discovery handshake),
\* which triggers a rebalance. do_rebalance re-asserts the local self occupancy
\* rows for every held group now routed to self, SYNCHRONOUSLY, before :status
\* leaves :rebalancing; we fold that into this atomic step. (Growing a view can
\* only keep or move the router to a smaller id, so this fold is idempotent for
\* Discover; it matters for DetectDown, but we keep it here for symmetry.)
Discover(n, m) ==
  /\ up[n] /\ up[m] /\ n # m
  /\ m \notin view[n]
  /\ LET nv == view[n] \cup {m}
         fold == holds[n] /\ Router(nv) = n
     IN /\ (fold => CanBump(n))
        /\ view' = [view EXCEPT ![n] = nv]
        /\ occ' = IF fold
                  THEN [occ EXCEPT ![n][n] = [present |-> TRUE, seq |-> Bump(n)]]
                  ELSE occ
        /\ seqCtr' = IF fold THEN [seqCtr EXCEPT ![n] = Bump(n)] ELSE seqCtr
  /\ UNCHANGED <<up, holds, mv, owed, msgs>>

\* A node permanently dies.
NodeDown(n) ==
  /\ up[n]
  \* keep at least one node alive to keep the model interesting/finite-behaved
  /\ \E k \in Nodes : k # n /\ up[k]
  /\ up' = [up EXCEPT ![n] = FALSE]
  /\ UNCHANGED <<holds, view, occ, mv, owed, seqCtr, msgs>>

\* Node n notices peer d is gone (coordinator :DOWN): remove from view, wipe d's
\* rows and member-view entry (all attributable to d, since d never restarts).
DetectDown(n, d) ==
  /\ up[n] /\ ~up[d] /\ n # d
  /\ d \in view[n]
  /\ LET nv == view[n] \ {d}
         \* do_rebalance re-asserts self-rows for held groups now routed to self,
         \* synchronously, before status leaves :rebalancing. This is the case
         \* that matters: losing the old (remote) router can make US the router.
         fold == holds[n] /\ nv # {} /\ Router(nv) = n
     IN /\ (fold => CanBump(n))
        /\ view' = [view EXCEPT ![n] = nv]
        /\ occ'  = IF fold
                   THEN [occ EXCEPT ![n][d] = [present |-> FALSE, seq |-> NoSeq],
                                    ![n][n] = [present |-> TRUE, seq |-> Bump(n)]]
                   ELSE [occ EXCEPT ![n][d] = [present |-> FALSE, seq |-> NoSeq]]
        /\ seqCtr' = IF fold THEN [seqCtr EXCEPT ![n] = Bump(n)] ELSE seqCtr
  /\ mv'   = [mv EXCEPT ![n][d] = [known |-> FALSE, hv |-> {}, seq |-> NoSeq]]
  /\ owed' = [owed EXCEPT ![n] = owed[n] \ {d}]
  /\ UNCHANGED <<up, holds, msgs>>

--------------------------------------------------------------------------------
(* Source-side dispatch. Each dispatch consumes a fresh per-source seq.        *)
(* These over-approximate the real triggers (first-member claim, vacant flush, *)
(* rebalance snapshot, view heartbeat): the real system has periodic backstops *)
(* that re-send current state, so "may send current truth at any time" is a    *)
(* faithful abstraction of the eventual re-send.                               *)

\* Re-announce our self occupancy row when WE are our own g-router (e.g. after a
\* rebalance made us the router again). Idempotent, seq-guarded upsert.
SelfClaim(s) ==
  /\ up[s] /\ holds[s] /\ view[s] # {}
  /\ Router(view[s]) = s
  /\ CanBump(s)
  /\ seqCtr' = [seqCtr EXCEPT ![s] = Bump(s)]
  /\ occ' = [occ EXCEPT ![s][s] =
        IF Bump(s) > occ[s][s].seq THEN [present |-> TRUE, seq |-> Bump(s)]
        ELSE occ[s][s]]
  /\ UNCHANGED <<up, holds, view, mv, owed, msgs>>

\* Rebalance snapshot to a router that gained g from us: data + view marker,
\* atomic on apply. Only sent when we hold g and route it to r.
SendSnapshot(s, r) ==
  /\ up[s] /\ holds[s] /\ view[s] # {}
  /\ r \in view[s] /\ r # s
  /\ Router(view[s]) = r
  /\ CanBump(s)
  /\ seqCtr' = [seqCtr EXCEPT ![s] = Bump(s)]
  /\ owed' = [owed EXCEPT ![s] = owed[s] \cup {r}]
  /\ msgs' = msgs \cup {SnapshotMsg(s, r, view[s], Bump(s))}
  /\ UNCHANGED <<up, holds, view, occ, mv>>

\* Bare view marker to a member for whom we hold NO data routing to it
\* (rebalance_marker / view heartbeat). Owed suppression: never send a bare
\* marker to a router we still owe a snapshot (its marker rides that snapshot).
SendMarker(s, m) ==
  /\ up[s] /\ view[s] # {}
  /\ m \in view[s] /\ m # s
  /\ m \notin owed[s]
  /\ ~(holds[s] /\ Router(view[s]) = m)  \* that case must use a snapshot
  /\ CanBump(s)
  /\ seqCtr' = [seqCtr EXCEPT ![s] = Bump(s)]
  /\ msgs' = msgs \cup {MarkerMsg(s, m, view[s], Bump(s))}
  /\ UNCHANGED <<up, holds, view, occ, mv, owed>>

--------------------------------------------------------------------------------
(* Delivery (apply) of an in-flight message on the destination router.         *)
(* Any in-flight message may be delivered at any time (erpc late landing +     *)
(* arbitrary reordering). Messages are never removed except by delivery, and   *)
(* delivery is always optional, so a message can be delayed indefinitely.      *)

\* Seq-guarded present upsert (occupied / snapshot data): strict >.
ApplyPresent(r, s, q) ==
  IF q > occ[r][s].seq THEN [present |-> TRUE, seq |-> q] ELSE occ[r][s]

\* Seq-guarded tombstone (vacant): >= (tombstone wins ties, though ties can't
\* occur with unique per-source seqs).
ApplyTomb(r, s, q) ==
  IF q >= occ[r][s].seq THEN [present |-> FALSE, seq |-> q] ELSE occ[r][s]

\* newest-seq-wins member-view update.
ApplyMV(r, s, hv, q) ==
  IF q > mv[r][s].seq THEN [known |-> TRUE, hv |-> hv, seq |-> q] ELSE mv[r][s]

DeliverVacant(msg) ==
  /\ msg \in msgs /\ msg.t = "vacant"
  /\ occ' = [occ EXCEPT ![msg.dst][msg.src] = ApplyTomb(msg.dst, msg.src, msg.seq)]
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<up, holds, view, mv, owed, seqCtr>>

\* Snapshot apply: data (present) first, then the member-view marker, one step.
\* Also clears the source's `owed` obligation to this router (its ack).
DeliverSnapshot(msg) ==
  /\ msg \in msgs /\ msg.t = "snapshot"
  /\ occ' = [occ EXCEPT ![msg.dst][msg.src] = ApplyPresent(msg.dst, msg.src, msg.seq)]
  /\ mv'  = [mv  EXCEPT ![msg.dst][msg.src] = ApplyMV(msg.dst, msg.src, msg.hv, msg.seq)]
  /\ owed' = [owed EXCEPT ![msg.src] = owed[msg.src] \ {msg.dst}]
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<up, holds, view, seqCtr>>

DeliverMarker(msg) ==
  /\ msg \in msgs /\ msg.t = "marker"
  /\ mv' = [mv EXCEPT ![msg.dst][msg.src] = ApplyMV(msg.dst, msg.src, msg.hv, msg.seq)]
  /\ msgs' = msgs \ {msg}
  /\ UNCHANGED <<up, holds, view, occ, owed, seqCtr>>

--------------------------------------------------------------------------------
Next ==
  \/ \E n \in Nodes : HolderJoin(n)
  \/ \E n \in Nodes : HolderLeave(n)
  \/ \E n, m \in Nodes : Discover(n, m)
  \/ \E n \in Nodes : NodeDown(n)
  \/ \E n, d \in Nodes : DetectDown(n, d)
  \/ \E s \in Nodes : SelfClaim(s)
  \/ \E s, r \in Nodes : SendSnapshot(s, r)
  \/ \E s, m \in Nodes : SendMarker(s, m)
  \/ \E msg \in msgs : DeliverVacant(msg)
  \/ \E msg \in msgs : DeliverSnapshot(msg)
  \/ \E msg \in msgs : DeliverMarker(msg)

Spec == Init /\ [][Next]_vars

--------------------------------------------------------------------------------
(* Invariants *)

TypeOK ==
  /\ up \in [Nodes -> BOOLEAN]
  /\ holds \in [Nodes -> BOOLEAN]
  /\ view \in [Nodes -> SUBSET Nodes]
  /\ seqCtr \in [Nodes -> 0..MaxSeq]
  /\ owed \in [Nodes -> SUBSET Nodes]

\* THE MAIN SAFETY PROPERTY: no missed delivery.
\*
\* For every ordered pair of live nodes (sender u, router r) such that
\*   - u would route a broadcast for g to r under u's view, and
\*   - r is allowed to trust its occupancy table for that broadcast,
\* every live holder s of g that is a member of the shared view must be in r's
\* delivery set Present(r).
NoMissedDelivery ==
  \A u \in Nodes :
    \A r \in Nodes :
      ( /\ up[u] /\ up[r]
        /\ view[u] # {}
        /\ Router(view[u]) = r          \* u targets r
        /\ CanDecide(r, view[u]) )       \* r trusts its table
      => \A s \in Nodes :
            ( /\ up[s] /\ holds[s]
              /\ s \in view[r] )         \* s is a member of the shared view
            => s \in Present(r)

================================================================================
