defmodule Rollcall do
  @moduledoc """
  A registry for entries that a process tracks. 

  This is the main entry point into Rollcall. Rollcall provides
  distributed entry tracking associated with a scope, such as a tenant.

  A Rollcall process owns the entries local to its node. It replicates
  to peers of the same scope across the cluster.
  """

  alias Rollcall.Tracker

  @doc """
  Returns the names of the scopes that have a running tracker on this node.
  """
  def scopes do
    Tracker.scopes()
  end

  @doc """
  Tracks an entry for `pid` in `partition` of `scope`.

  Returns `{:ok, ref}`. The ref identifies the entry.

  Returns `{:error, {:already_tracked, pid, partition, key}}` when `pid`
  already tracks `key` in `partition`.

  Starts the tracker for `scope` when no tracker runs.
  """
  def track(pid, scope, partition, key, meta) do
    Tracker.call(scope, {:track, pid, partition, key, meta})
  end
end
