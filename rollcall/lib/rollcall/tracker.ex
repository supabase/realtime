defmodule Rollcall.Tracker do
  @moduledoc """
  The process that holds the entries of one scope on this node.

  The tracker holds the local entries, a monitor on each process that tracks an
  entry, a version counter, an incarnation timestamp and the view. It exchanges
  heartbeats with the trackers of the same scope on other nodes.

  ## Starting and Supervision

  `Rollcall.Registry` maps a scope to its tracker pid. The tracker has a
  `:via` name. No atom exists for a scope, because a scope is a tenant. The
  number of tenants has no limit, and the VM never frees an atom.

  `Rollcall.TrackerSupervisor` supervises the trackers. The restart type is
  `:temporary`. A restarted tracker would have no entries and no process that
  can untrack, so it would never stop. A crashed tracker does not restart. The
  next `track` for its scope starts a clean tracker.

  `call/4` finds the tracker for a scope. It starts the tracker only when
  `start` is true.

  ## Process monitoring

  The tracker always monitors a process that has an entry. The monitor tells
  the tracker to remove the entries when the process exits.

  In link mode, the tracker also links to the process, so an entry never
  outlives its tracker. In monitor mode, a tracker crash leaves the process
  running and the entries of the node are lost until each process tracks again.
  Phoenix.Presence uses a link, so the crash of a shard stops every channel in
  the shard. Monitor mode lets a new tracker run next to the old one without
  that risk.

  ## Grace period

  A stop of a tracker costs work on every node. The tracker sends a goodbye
  snapshot. The next tracker has a new incarnation, so each peer replaces its
  replica. The new tracker has no peers. It learns each peer from a heartbeat,
  then asks for a snapshot. A scope that loses its last process and gets a new
  process soon after pays this cost on each cycle.

  The tracker waits for a grace period before it stops. It starts a timer when
  it holds no entry. A `track` cancels the timer. When the timer expires, the
  tracker stops.

  The cost of the wait is an idle tracker. It still sends a heartbeat in each
  period. The best length depends on the heartbeat period.

  Set the length of the period with the `:empty_grace` key of the `:rollcall`
  application environment, in milliseconds. The tracker reads the key when it
  starts. The default is 5000.

  ## Trace points

  The tracker emits these trace points. A test waits for an event, and does not
  sleep. The events do nothing outside the test environment. Each event has the
  key `scope`.

    * `:rollcall_tracker_started` - the tracker started.
    * `:rollcall_tracker_empty` - the tracker holds no entry, and the timer of
      the grace period started.
    * `:rollcall_tracker_stopped` - the timer expired. The tracker stops after
      the event.
    * `:rollcall_tracker_track` - a `track` call changed `local`. The event has
      the keys `pid`, `partition`, `key`, `version`, `joins` and `leaves`. The
      `version` is the version after the call. `joins` and `leaves` are lists of
      refs.
    * `:rollcall_tracker_untrack` - an `untrack` call. The event has the same
      keys as the track event. When no entry matches, `joins` and `leaves` are
      empty, and the `version` does not change.
    * `:rollcall_tracker_pid_down` - a process that tracked entries exited. The
      event has the key `pid`. The tracker emits the event after it removed the
      entries of the process.

  Use the functions in `Rollcall`. Do not call this module directly.
  """

  use GenServer, restart: :temporary
  use Snabbkaffex, only: :trace
  alias Rollcall.Tracker.Local
  alias Rollcall.Tracker.Local.Changes

  @max_retries 3

  @doc """
  Sends `msg` to the tracker for `scope` and returns the reply.

  The tracker can be not running, or can stop before it replies. A tracker can
  stop between the lookup and the call, for example when its grace period ends.
  Then the result depends on `start`:

  * `start` is true: the function starts a tracker and sends `msg` again. A
    tracker that stopped handled no part of the message, so the new tracker can
    handle it. The function sends `msg` again at most `retries` times. The
    limit stops an endless loop when a tracker exits without a reply. After the
    limit, the function exits with the reason of the last failure.
  * `start` is false: the function returns `:ok`. A tracker that starts only to
    find nothing to remove would stop again after the grace period, so an
    `untrack` does not start one.
  """
  def call(scope, msg, start \\ false, retries \\ @max_retries) do
    GenServer.call(via(scope), msg)
  catch
    :exit, {reason, _} = caught when reason in [:noproc, :normal, :shutdown] ->
      if retries == 0, do: exit(caught)

      if start do
        start(scope)
        call(scope, msg, start, retries - 1)
      else
        :ok
      end
  end

  @inspectable_keys [:incarnation, :scope, :version, :local]

  @doc """
  Returns the state of the tracker for `scope`, or `nil` when no tracker runs.

  The state is a map with the keys `scope`, `version`, `incarnation` and
  `local`. The value of `local` is a `Rollcall.Tracker.Local` set.

  The map holds the fields that have a meaning outside the process. The timer
  and the monitors stay private, so a change to them does not break a caller.

  The function does not start a tracker. Use it in tests and for debugging.
  """
  def get_state(scope) do
    case call(scope, :get_state) do
      :ok -> nil
      {:ok, state} -> Map.take(state, @inspectable_keys)
    end
  end

  @doc """
  Returns the names of the scopes that have a running tracker on this node.

  The function skips a tracker that has exited. The Registry removes the entry
  of an exited process after a short delay.
  """
  def scopes do
    Rollcall.Registry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {_, pid} -> Process.alive?(pid) end)
    |> Enum.map(fn {scope, _} -> scope end)
  end

  defp start(scope) do
    case DynamicSupervisor.start_child(Rollcall.TrackerSupervisor, {__MODULE__, scope}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc """
  Starts the tracker for `scope` and registers it in `Rollcall.Registry`.

  Returns `{:ok, pid}`. Returns `{:error, {:already_started, pid}}` when a
  tracker runs for `scope`. `Rollcall.TrackerSupervisor` calls this function.
  """
  def start_link(scope) do
    GenServer.start_link(__MODULE__, scope, name: via(scope))
  end

  @doc """
  Returns the pid of the tracker for `scope`, or `nil` when no tracker runs.
  """
  def whereis(scope) do
    GenServer.whereis(via(scope))
  end

  @doc """
  Returns the `:via` name that registers the tracker for `scope` in
  `Rollcall.Registry`.
  """
  def via(scope) do
    {:via, Registry, {Rollcall.Registry, scope}}
  end

  defmodule State do
    @moduledoc """
    The state of a tracker process.

    `local` holds the entries that processes on this node track. `version`
    counts the changes to `local`. `incarnation` is the time at which the
    tracker started. `sent` holds the `local` set and the `version` at the last
    heartbeat.

    The `incarnation` and the `version` form the stamp of a message. A peer
    compares stamps to order messages that arrive in any order. A tracker that
    restarts gets a newer incarnation, so its peers replace its old entries.

    TODO: For each peer node, the state holds a `replica`, a `mark`, a `silent` count
    and a `behind` flag. The view of the tracker is `local` plus each replica.

    `monitors` maps each process that has an entry to its monitor. `empty_grace`
    and `empty_timer` control the stop of a tracker that holds no entry.
    """

    alias Rollcall.Tracker.Local

    @enforce_keys [:scope, :incarnation, :empty_grace]

    defstruct [
      :scope,
      :incarnation,
      :empty_grace,
      empty_timer: nil,
      local: Local.new(),
      version: 0,
      monitors: %{}
    ]

    def bump_version(%__MODULE__{version: version} = state) do
      %{state | version: version + 1}
    end
  end

  @impl true
  def init(scope) do
    Process.set_label({:rollcall_tracker, scope})

    tp(:rollcall_tracker_started, %{scope: scope})

    state = %State{
      scope: scope,
      incarnation: System.os_time(:nanosecond),
      empty_grace: Application.get_env(:rollcall, :empty_grace, :timer.seconds(5))
    }

    {:ok, state}
  end

  # The messages that `call/4` sends:
  #
  #   :get_state
  #   {:track, pid, partition, key, meta}
  #   {:untrack, pid, partition, key}
  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, state}, state}
  end

  def handle_call({:track, pid, partition, key, meta}, _from, state) do
    ref = make_ref()

    {changes, local} = Local.track(state.local, pid, partition, key, meta, ref)

    state =
      state
      |> apply_changes(local, changes)
      |> cancel_empty_timer()
      |> watch_pid(pid)

    tp(
      :rollcall_tracker_track,
      %{
        scope: state.scope,
        pid: pid,
        partition: partition,
        key: key,
        version: state.version,
        joins: Changes.join_refs(changes),
        leaves: Changes.leave_refs(changes)
      },
      ignore_side_effects: true
    )

    {:reply, {:ok, ref}, state}
  end

  def handle_call({:untrack, pid, partition, key}, _from, state) do
    {changes, local} = Local.untrack(state.local, pid, partition, key)

    state =
      state
      |> apply_changes(local, changes)
      |> maybe_unwatch(pid)
      |> arm_empty_timer()

    tp(
      :rollcall_tracker_untrack,
      %{
        scope: state.scope,
        pid: pid,
        partition: partition,
        key: key,
        version: state.version,
        joins: Changes.join_refs(changes),
        leaves: Changes.leave_refs(changes)
      },
      ignore_side_effects: true
    )

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:timeout, ref, :empty_timeout}, %{empty_timer: ref} = state) do
    tp(:rollcall_tracker_stopped, %{scope: state.scope})

    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {changes, local} = Local.untrack_pid(state.local, pid)

    state =
      state
      |> apply_changes(local, changes)
      |> remove_monitor(pid)
      |> arm_empty_timer()

    tp(:rollcall_tracker_pid_down, %{scope: state.scope, pid: pid})

    {:noreply, state}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  defp apply_changes(state, local, changes) do
    state
    |> Map.put(:local, local)
    |> bump_version(changes)
  end

  defp arm_empty_timer(%{empty_timer: nil} = state) do
    if Local.empty?(state.local) do
      tp(:rollcall_tracker_empty, %{scope: state.scope})

      %{state | empty_timer: :erlang.start_timer(state.empty_grace, self(), :empty_timeout)}
    else
      state
    end
  end

  defp arm_empty_timer(state), do: state

  defp cancel_empty_timer(%{empty_timer: nil} = state), do: state

  defp cancel_empty_timer(%{empty_timer: ref} = state) do
    :erlang.cancel_timer(ref)
    %{state | empty_timer: nil}
  end

  defp bump_version(state, changes) do
    if Local.Changes.empty?(changes) do
      state
    else
      State.bump_version(state)
    end
  end

  # Handles watching pids to update tracker state when a process ends
  #
  # We use monitor here because initially we don't want a tracker going down
  # to take the channels down, which is actually what happens with Phoenix.Presence
  # because it uses link.
  #
  # When Rollcall goes to production we'll need to switch this to link.
  defp watch_pid(state, pid) do
    if Local.tracks?(state.local, pid) and !Map.has_key?(state.monitors, pid) do
      %{state | monitors: Map.put(state.monitors, pid, Process.monitor(pid))}
    else
      state
    end
  end

  defp maybe_unwatch(state, pid) do
    if Local.tracks?(state.local, pid) do
      state
    else
      remove_monitor(state, pid)
    end
  end

  defp remove_monitor(state, pid) do
    case Map.pop(state.monitors, pid) do
      {nil, _monitors} ->
        state

      {ref, monitors} ->
        Process.demonitor(ref, [:flush])
        %{state | monitors: monitors}
    end
  end
end
