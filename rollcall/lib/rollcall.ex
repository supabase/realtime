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

  The first `track/6` for a scope starts the tracker, so an unused scope costs
  nothing. The tracker removes an entry when its process exits or untracks it,
  so an entry never outlives its process. The tracker stops after it holds no
  entry for the grace period. The grace period avoids a stop and a start when a
  scope gets a new process soon after it lost its last process. See
  `Rollcall.Tracker`.

  A client reads the entries of a partition with `state/3`. 

  Use the functions in this module. Do not call `Rollcall.Tracker` directly.
  """

  alias Rollcall.Tracker

  @typedoc "The name of an instance of Rollcall"
  @type name :: atom()

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

  @typedoc "An entry in one partition: its ref, its key and its meta."
  @type entry :: {ref(), key(), meta()}

  @typedoc "An entry in a scope: its partition, its ref, its key and its meta."
  @type scope_entry :: {partition(), ref(), key(), meta()}

  @typedoc """
  A set of changes to a partition.

  The elements are:

  1. a list of `entry()`s that have joined the partition.
  2. a list of `entry()`s that have left the partition.
  """
  @type partition_diff :: {[entry()], [entry()]}

  @doc """
  Defines an instance of Rollcall named after the module that calls `use`.

  The module gets `child_spec/1`, `start_link/1`, `track/5`, `untrack/4`,
  `scopes/0`, `state/1` and `state/2`. Each function calls the function of `Rollcall` with the same name
  and passes the module as the name of the instance. A caller then writes
  `MyApp.Rollcall.track(...)` and never handles the name.

      defmodule MyApp.Rollcall do
        use Rollcall, transport: {MyApp.Transport, []}
      end

  The options of `use` are the options of `start_link/1`. See
  `Rollcall.start_link/1` for the list. They are the defaults of the instance.
  An option that you pass to the `start_link/1` of the module replaces the same
  option of `use`.
  """
  defmacro __using__(opts) do
    opts = Keyword.validate!(opts, Rollcall.Tracker.init_options())

    quote do
      @spec child_spec(keyword()) :: Supervisor.child_spec()
      def child_spec(opts \\ []) do
        %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}
      end

      @spec start_link(keyword()) :: Supervisor.on_start()
      def start_link(opts \\ []) do
        opts = Keyword.validate!(opts, Rollcall.Tracker.init_options())
        Rollcall.start_link([name: __MODULE__] ++ Keyword.merge(unquote(opts), opts))
      end

      @spec track(pid(), Rollcall.scope(), Rollcall.partition(), Rollcall.key(), Rollcall.meta(), Keyword.t()) ::
              {:ok, Rollcall.ref()} | {:error, term()}
      def track(pid, scope, partition, key, meta, opts \\ []),
        do: Rollcall.track(__MODULE__, pid, scope, partition, key, meta, opts)

      @spec untrack(pid(), Rollcall.scope(), Rollcall.partition(), Rollcall.key()) :: :ok
      def untrack(pid, scope, partition, key), do: Rollcall.untrack(__MODULE__, pid, scope, partition, key)

      @spec scopes() :: [Rollcall.scope()]
      def scopes, do: Rollcall.scopes(__MODULE__)

      @spec state(Rollcall.scope(), Rollcall.partition()) :: [Rollcall.entry()]
      def state(scope, partition), do: Rollcall.state(__MODULE__, scope, partition)

      @spec state(Rollcall.scope()) :: [Rollcall.scope_entry()]
      def state(scope), do: Rollcall.state(__MODULE__, scope)
    end
  end

  @doc """
  Returns a supervisor child specification. The argument is the `opts` of
  `start_link/1`.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.fetch!(opts, :name),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Starts the library: the registry of the trackers and the supervisor of the
  trackers.

  See `Rollcall.Tracker.start_link/1` for a list of valid options.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    :ok = validate_option!(:name, Keyword.get(opts, :name))
    {name, tracker_options} = Keyword.pop(opts, :name)

    tracker_options = Keyword.validate!(tracker_options, Tracker.init_options())
    Enum.each(tracker_options, fn {key, value} -> validate_option!(key, value) end)

    supervisor_name = Module.concat(name, Supervisor)
    tracker_supervisor_name = Module.concat(name, TrackerSupervisor)

    children = [
      {Registry,
       keys: :unique,
       name: name,
       meta: [
         tracker_options: tracker_options,
         tracker_supervisor: tracker_supervisor_name
       ]},
      {DynamicSupervisor, name: tracker_supervisor_name}
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: supervisor_name)
  end

  defp validate_option!(:name, name) when is_atom(name) and name not in [nil, true, false], do: :ok
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
  @spec scopes(name()) :: [scope()]
  def scopes(name) do
    Tracker.scopes(name)
  end

  @doc """
  Returns every entry in `scope`: the partition, the ref, the key and the meta
  of each entry. The order is not defined.

  The entries are the local entries plus the replica of each peer. Use
  `state/3` to read one partition. 

  Returns `[]` when no tracker runs for `scope`, or when the instance does not
  run. The function reads a table of the tracker. It sends no message to the
  tracker and it does not start a tracker.

  Note: this function returns the entire scope, all partitions. In real use cases
  you probably don't want this and should use `state/3` instead, which returns
  a single partition, but it's here for ergonomics when testing.
  """
  @spec state(name(), scope()) :: [scope_entry()]
  def state(name, scope) do
    Tracker.state(name, scope)
  end

  @doc """
  Returns the entries in `partition` of `scope`: the ref, the key and the meta
  of each entry. The order is not defined.

  The entries are the local entries plus the replica of each peer. The cost of
  the read does not depend on the other partitions of the scope.

  Subscribe to the diffs of the partition before you read the state. A change
  that happens between the two steps then reaches you in a diff. See
  `Rollcall.Transport.publish/3`.

  Returns `[]` when no tracker runs for `scope`, or when the instance does not
  run. The function reads a table of the tracker. It sends no message to the
  tracker and it does not start a tracker.
  """
  @spec state(name(), scope(), partition()) :: [entry()]
  def state(name, scope, partition) do
    Tracker.state(name, scope, partition)
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

  A `:ref` option can be passed in the opts argument. When it's provided the value
  will be used as the ref for the entry. Refs need to be unique per scope, when callers
  provide the ref they are responsible for its uniqueness.
  """
  @spec track(name(), pid(), scope(), partition(), key(), meta(), Keyword.t()) :: {:ok, ref()} | {:error, term()}
  def track(name, pid, scope, partition, key, meta, opts \\ []) when is_pid(pid) and is_map(meta) do
    Tracker.track(name, scope, pid, partition, key, meta, opts)
  end

  @doc """
  Removes the entry of `pid` for `key` in `partition` of `scope`.

  Returns `:ok`. The function also returns `:ok` when the entry does not
  exist, or when no tracker runs for `scope`. The caller wants the entry gone,
  and it is gone in both cases.

  Does not start a tracker. A tracker that starts only to find nothing to
  remove would stop again after the grace period.
  """
  @spec untrack(name(), pid(), scope(), partition(), key()) :: :ok
  def untrack(name, pid, scope, partition, key) when is_pid(pid) do
    Tracker.untrack(name, scope, pid, partition, key)
  end
end
