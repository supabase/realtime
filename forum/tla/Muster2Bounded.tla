---------------------------- MODULE Muster2Bounded ----------------------------
(*****************************************************************************)
(* Bounded 4-node harness over MODULE Muster2 (the B1 fix). A full 4-node    *)
(* exhaustive run is infeasible (3 nodes already = 57.8M states), so this    *)
(* caps the per-source seq (via MaxSeq in the cfg) AND the in-flight message *)
(* count, turning the search into a bounded model check. It cannot PROVE     *)
(* safety at 4 nodes; it can only surface a shallow 4-node-specific          *)
(* violation of NoMissedDelivery / TypeOK reachable within the bound.        *)
(*                                                                           *)
(* NOTE: Router == min breaks node-id symmetry (node 1 is special), so no    *)
(* TLC SYMMETRY set is valid here.                                           *)
(*****************************************************************************)
EXTENDS Muster2

\* Cap concurrent in-flight messages to keep the bounded search finite/small.
MsgBound == Cardinality(msgs) <= 2

================================================================================
