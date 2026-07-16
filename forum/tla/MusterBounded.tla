----------------------------- MODULE MusterBounded -----------------------------
(*****************************************************************************)
(* Positive control: bounded 4-node harness over MODULE Muster (the baseline *)
(* that EXHIBITS Finding A). Confirms the bounded 4-node search is capable of *)
(* reaching a NoMissedDelivery violation, so a clean Muster2Bounded run is    *)
(* meaningful rather than vacuous.                                            *)
(*****************************************************************************)
EXTENDS Muster

MsgBound == Cardinality(msgs) <= 3

================================================================================
