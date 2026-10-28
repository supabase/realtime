defmodule Rollcall do
  @moduledoc """
  A replicated registry of entries. A process tracks an entry. The tracker
  removes the entry when that process exits.

  A scope groups the entries that belong together. A partition groups the
  entries inside a scope. An entry has a key and a meta. The tracker generates
  a ref for each entry. In Realtime, the scope is a tenant and the partition is
  a channel topic.

  Each node runs one tracker for each scope that has a process on the node.
  The tracker is the authority for the entries that processes on its node
  track. It replicates these entries to the trackers of the same scope on the
  other nodes. The view of a node is its own entries plus the replicas of the
  other nodes.

  The first `track/5` for a scope starts the tracker. The tracker removes an
  entry when its process exits or untracks it. The tracker stops after it holds
  no entry for the grace period. See `Rollcall.Tracker`.

  Use the functions in this module. Do not call `Rollcall.Tracker` directly.
  """

  alias Rollcall.Tracker

  @doc """
  Returns the names of the scopes that have a running tracker on this node.

  A tracker in its grace period is running.
  """
  def scopes do
    Tracker.scopes()
  end

  @doc """
  Tracks an entry for `pid` in `partition` of `scope`.

  The `key` and the `meta` are the payload of the entry.

  Returns `{:ok, ref}`. The ref identifies the entry.

  Starts the tracker for `scope` when no tracker runs.
  """
  def track(pid, scope, partition, key, meta) when is_pid(pid) do
    Tracker.call(scope, {:track, pid, partition, key, meta}, true)
  end

  @doc """
  Removes the entry of `pid` for `key` in `partition` of `scope`.

  Returns `:ok`. The function also returns `:ok` when the entry does not
  exist, or when no tracker runs for `scope`.

  Does not start a tracker.
  """
  def untrack(pid, scope, partition, key) when is_pid(pid) do
    Tracker.call(scope, {:untrack, pid, partition, key})
  end
end
