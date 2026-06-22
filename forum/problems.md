Scenario 1 — node joins (scale-up / rolling deploy). The primary miss case.

  Cluster {A,B} → {A,B,C}. Group G is held only on B. Suppose G re-hashes so router moves A → C.

  Worst-case ordering:
  1. C joins; A and B get :nodeup, handshake.
  2. A (sender's node) has little/nothing to re-announce → its do_rebalance finishes fast → A is :stable, ring {A,B,C}, router(G)=C.
  3. A process on A broadcasts to G → gets {:ok, C} → sends to C.
  4. B is slower — it has not yet run do_rebalance, so it hasn't sent receive_node_state([G], B) to C.
  5. C's occupancy for G is empty → C fans out to nobody → every member of G on B misses the message.

  The window = (time A returns to :stable) → (time B finishes announcing G to C). New nodes are the worst routers: C's table starts empty, so all groups newly routed to
  C depend entirely on holders re-announcing, and during a deploy C is simultaneously receiving announcements from everyone, so its RPC queue lengthens exactly when
  it's most needed.

  Scenario 2 — node leaves / crashes (scale-down, deploy, partition)

  Cluster {A,B,C}, C leaves. Split into two sub-cases:

  2a — C was a router (members live on B). Identical structure to Scenario 1: G's router moves off C to, say, A; until B's do_rebalance announces {G,B} to A, a sender
  on A (already :stable) routes to A whose table lacks {G,B} → miss. Note the :DOWN handler only purges entries keyed by the dead node (scope.ex:278); it does nothing
  to repopulate entries that move onto surviving routers — that repopulation is the slow holder-driven re-announce.

  2b — C was a holder (members on C). Those pids died with the node, so "missing" them isn't a correctness loss — there's nobody to deliver to.

  Amplifier — rebalance RPC failure. If B's receive_node_state to the new router raises or returns non-:ok, do_rebalance re-raises → B's Scope crashes
  (scope.ex:725-726, README:190). On restart init resets members=[node()], rebuilds group_states as :occupied, and re-discovers (scope.ex:819-827). During that
  crash→init window B's status is left :rebalancing (safe for senders on B), but senders on A are still routing to a new router that B never successfully told → the
  miss window stretches from milliseconds to potentially seconds (a full crash+restart+rediscover+rebalance cycle).
