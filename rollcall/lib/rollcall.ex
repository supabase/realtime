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

  @typedoc "The name of a scope. In Realtime, the external id of a tenant."
  @type scope :: String.t()

  @typedoc "The name of a partition inside a scope. In Realtime, a channel topic."
  @type partition :: String.t()

  @typedoc "The key of an entry. A process has one entry for each partition and key."
  @type key :: String.t()

  @typedoc "The payload of an entry that belongs to the key."
  @type meta :: map()

  @typedoc "The identity of an entry."
  @type ref :: String.t()

  @doc """
  Returns a supervisor child specification. The argument is the `opts` of
  `start_link/1`.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Starts the library: the registry of the trackers and the supervisor of the
  trackers.

  The options are the options of `Rollcall.Tracker.start_link/1`, except
  `:name`. They are `:transport`, `:heartbeat_period_in_ms`,
  `:silence_threshold` and `:empty_grace_in_ms`. Each tracker that `track/5`
  starts gets these options. An option that you do not set has the defaults
  defined in `Rollcall.Tracker`.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    tracker_options = Keyword.validate!(opts, Tracker.init_options())
    Enum.each(tracker_options, fn {key, value} -> validate_option!(key, value) end)

    children = [
      {Registry, keys: :unique, name: Rollcall.Registry, meta: [tracker_options: tracker_options]},
      {DynamicSupervisor, name: Rollcall.TrackerSupervisor}
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: Rollcall.Supervisor)
  end

  defp validate_option!(:transport, {module, opts}) when is_atom(module) and is_list(opts), do: :ok
  defp validate_option!(:heartbeat_period_in_ms, :manual), do: :ok
  defp validate_option!(:heartbeat_period_in_ms, value) when is_integer(value) and value > 0, do: :ok
  defp validate_option!(:silence_threshold, value) when is_integer(value) and value > 0, do: :ok
  defp validate_option!(:empty_grace_in_ms, value) when is_integer(value) and value >= 0, do: :ok

  defp validate_option!(key, value) do
    raise ArgumentError, "invalid value for the option #{inspect(key)}: #{inspect(value)}"
  end

  @doc """
  Returns the names of the scopes that have a running tracker on this node.

  A tracker in its grace period is running, so a scope with no entry can be in
  the list for a short time.
  """
  @spec scopes() :: [scope()]
  def scopes do
    Tracker.scopes()
  end

  @doc """
  Tracks an entry for `pid` in `partition` of `scope`.

  The `key` and the `meta` are the payload of the entry.

  Returns `{:ok, ref}` or `{:error, reason}`. The ref identifies the entry.

  When `pid` already tracks `key` in `partition`, the new entry replaces the
  old entry. The entry gets a new ref, so a subscriber sees one diff with a
  leave and a join. The new meta has the key `:rc_prev_ref` with the ref of the
  old entry. 

  The call replaces the entry also when the meta is the same. The caller knows
  which part of a meta changes on each call, for example a timestamp, and the
  tracker does not. A skip would also make the return value depend on the
  earlier entry, because `track` would have to return the ref of that entry. A
  caller that wants to skip an unchanged meta compares it before the call.

  Starts the tracker for `scope` when no tracker runs.
  """
  @spec track(pid(), scope(), partition(), key(), meta()) :: {:ok, ref()} | {:error, term()}
  def track(pid, scope, partition, key, meta) when is_pid(pid) and is_map(meta) do
    Tracker.track(scope, pid, partition, key, meta)
  end

  @doc """
  Removes the entry of `pid` for `key` in `partition` of `scope`.

  Returns `:ok`. The function also returns `:ok` when the entry does not
  exist, or when no tracker runs for `scope`. The caller wants the entry gone,
  and it is gone in both cases.

  Does not start a tracker. A tracker that starts only to find nothing to
  remove would stop again after the grace period.
  """
  @spec untrack(pid(), scope(), partition(), key()) :: :ok
  def untrack(pid, scope, partition, key) when is_pid(pid) do
    Tracker.untrack(scope, pid, partition, key)
  end
end
