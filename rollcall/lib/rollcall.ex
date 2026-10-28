defmodule Rollcall do
  @moduledoc """
  A replicated registry of entries. A process tracks an entry. The tracker
  removes the entry when that process exits.

  A scope groups the entries that belong together. A partition groups the
  entries inside a scope. An entry has a key and a meta. The tracker generates
  a ref for each entry. In Realtime, the scope is a tenant and the partition is
  a channel topic.

  Each node runs one tracker for each scope that has a process on the node.
  The work and the memory of a node then depend on the scopes that have
  processes on the node, and not on the whole cluster. The tracker is the
  authority for the entries that processes on its node track. It replicates
  these entries to the trackers of the same scope on the other nodes. An entry
  has one owner, so the trackers need no merge and no conflict resolution. The
  view of a node is its own entries plus the replicas of the other nodes.

  The first `track/5` for a scope starts the tracker, so an unused scope costs
  nothing. The tracker removes an entry when its process exits or untracks it,
  so an entry never outlives its process. The tracker stops after it holds no
  entry for the grace period. The grace period avoids a stop and a start when a
  scope gets a new process soon after it lost its last process. See
  `Rollcall.Tracker`.

  Use the functions in this module. Do not call `Rollcall.Tracker` directly.
  """

  alias Rollcall.Tracker

  @doc """
  Returns the names of the scopes that have a running tracker on this node.

  A tracker in its grace period is running, so a scope with no entry can be in
  the list for a short time.
  """
  def scopes do
    Tracker.scopes()
  end

  @doc """
  Tracks an entry for `pid` in `partition` of `scope`.

  The `key` and the `meta` are the payload of the entry.

  Returns `{:ok, ref}`. The ref identifies the entry.

  When `pid` already tracks `key` in `partition`, the new entry replaces the
  old entry. The entry gets a new ref, so a subscriber sees one diff with a
  leave and a join. The replace takes one call. A caller that must tell a new
  entry from an update would need two calls.

  The call replaces the entry also when the meta is the same. The caller knows
  which part of a meta changes on each call, for example a timestamp. A caller
  that wants to skip an unchanged meta compares it before the call.

  Starts the tracker for `scope` when no tracker runs.
  """
  def track(pid, scope, partition, key, meta) when is_pid(pid) do
    Tracker.call(scope, {:track, pid, partition, key, meta}, true)
  end

  @doc """
  Removes the entry of `pid` for `key` in `partition` of `scope`.

  Returns `:ok`. The function also returns `:ok` when the entry does not
  exist, or when no tracker runs for `scope`. The caller wants the entry gone,
  and it is gone in both cases.

  Does not start a tracker. A tracker that starts only to find nothing to
  remove would stop again after the grace period.
  """
  def untrack(pid, scope, partition, key) when is_pid(pid) do
    Tracker.call(scope, {:untrack, pid, partition, key})
  end
end
