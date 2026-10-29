defmodule Rollcall.Tracker do
  @moduledoc """
  The process that holds the entries of one scope on this node.

  The tracker holds the local entries, a monitor on each process that tracks an
  entry, a version counter, an incarnation timestamp, a record for each peer
  node and the view. It exchanges heartbeats with the trackers of the same scope
  on other nodes.

  ## Not built yet

  This module describes the finished design. The tracker does not yet do these
  things:

    * send a heartbeat, a goodbye or a request
    * reply to a request with a snapshot
    * hold `sent`, the state at the last heartbeat
    * hold the view, or publish changes to subscribers

  The tracker does receive the messages of its peers, and it keeps one record
  for each peer node. Delete this section when the list is empty.

  ## Starting and Supervision

  `Rollcall.Registry` maps a scope to its tracker pid. The tracker has a
  `:via` name. No atom exists for a scope, because a scope is a tenant. The
  number of tenants has no limit, and the VM never frees an atom.

  `Rollcall.TrackerSupervisor` supervises the trackers. The restart type is
  `:temporary`. A restarted tracker would have no entries and no process that
  can untrack, so it would never stop. A crashed tracker does not restart. The
  next `track` for its scope starts a clean tracker.

  `track/5` finds the tracker for a scope, and starts one when none runs.
  `untrack/4` and `get_state/1` do not start a tracker.

  ## Process monitoring

  The tracker always monitors a process that has an entry. The monitor tells
  the tracker to remove the entries when the process exits.

  In link mode, the tracker also links to the process, so an entry never
  outlives its tracker. In monitor mode, a tracker crash leaves the process
  running and the entries of the node are lost until each process tracks again.
  `Phoenix.Presence` uses a link, so the crash of a shard stops every channel in
  the shard. Monitor mode lets a new tracker run next to the old one without
  that risk.

  ## Peers

  The tracker keeps one `Rollcall.Tracker.Peer` for each node that sent it a
  message. The key is `node(origin)`, where `origin` is the pid of the sending
  tracker. Two origins on one node share one record, so a restarted tracker
  replaces the entries of its old run.

  A tick counts one quiet period for each record. A message from the peer, of
  any kind, resets the count. A record that reaches the silence threshold is
  deleted, and its entries leave. A crashed peer sends no goodbye, and the
  threshold is how the tracker finds out.

  Set the threshold with the `:silence_threshold` option of `start_link/1`. The
  value is a number of ticks. The default is 10.

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
    * `:rollcall_tracker_peer_message` - a message reached a peer record. A
      request from an unknown node emits no event. The event has the keys
      `node`, `joins`, `leaves` and `behind`. `joins` and `leaves` are the refs
      that the message added to the replica and removed from it.
    * `:rollcall_tracker_peer_purged` - a tick deleted a peer record. The event
      has the keys `node`, `joins` and `leaves`. `joins` is empty. `leaves` holds
      the refs of the entries of the peer.

  Use the functions in `Rollcall`. Do not call this module directly.
  """

  use GenServer, restart: :temporary
  use Snabbkaffex, only: :trace
  alias Rollcall.Tracker.Local
  alias Rollcall.Tracker.Changes
  alias Rollcall.Tracker.Messages
  alias Rollcall.Tracker.Peer

  @max_retries 3

  # The exit reasons of a call when no tracker runs, or when the tracker stops
  # before it replies.
  @gone [:noproc, :normal, :shutdown]

  @doc """
  Tracks an entry in the tracker for `scope`, and returns the ref of the entry.

  The function starts a tracker when none runs. A tracker can also stop between
  the lookup and the call, for example when its grace period ends. A tracker
  that stopped handled no part of the message, so the function starts a new
  tracker and sends the message again.

  The function sends the message again at most #{@max_retries} times. The limit
  stops an endless loop when a tracker exits without a reply. After the limit,
  the function exits with the reason of the last failure.
  """
  @spec track(Rollcall.scope(), pid(), Rollcall.partition(), Rollcall.key(), Rollcall.meta()) :: {:ok, Rollcall.ref()}
  def track(scope, pid, partition, key, meta) do
    call_or_start(scope, {:track, pid, partition, key, meta}, @max_retries)
  end

  # Calls the tracker for `scope`. Starts a tracker and sends the message again
  # when none runs, at most `retries` times.
  defp call_or_start(scope, message, retries) do
    GenServer.call(via(scope), message)
  catch
    :exit, {reason, _} = caught when reason in @gone ->
      if retries == 0, do: exit(caught)

      start(scope)
      call_or_start(scope, message, retries - 1)
  end

  @doc """
  Removes the entry of `pid` for `key` in `partition` from the tracker for
  `scope`.

  Returns `:ok`. The function also returns `:ok` when no tracker runs, or when
  the tracker stops before it replies. A tracker that stops takes its entries
  with it, so a second attempt would find nothing to remove.

  The function does not start a tracker. A tracker that starts only to find
  nothing to remove would stop again after the grace period.
  """
  @spec untrack(Rollcall.scope(), pid(), Rollcall.partition(), Rollcall.key()) :: :ok
  def untrack(scope, pid, partition, key) do
    call_if_running(scope, {:untrack, pid, partition, key}, :ok)
  end

  # Calls the tracker for `scope`. Returns `default` when no tracker runs, or
  # when the tracker stops before it replies.
  defp call_if_running(scope, message, default) do
    GenServer.call(via(scope), message)
  catch
    :exit, {reason, _} when reason in @gone -> default
  end

  @inspectable_keys [:incarnation, :scope, :version, :local, :peers]

  @type inspected_state :: %{
          scope: Rollcall.scope(),
          version: non_neg_integer(),
          incarnation: integer(),
          local: Local.t(),
          peers: %{node() => Peer.t()}
        }

  @doc """
  Returns the state of the tracker for `scope`, or `nil` when no tracker runs.

  The state is a map with the keys `scope`, `version`, `incarnation`, `local`
  and `peers`. The value of `local` is a `Rollcall.Tracker.Local` set. The value
  of `peers` maps each peer node to its `Rollcall.Tracker.Peer`.

  The map holds the fields that have a meaning outside the process. The timer
  and the monitors stay private, so a change to them does not break a caller.

  The function does not start a tracker. Use it in tests and for debugging.
  """
  @spec get_state(Rollcall.scope()) :: inspected_state() | nil
  def get_state(scope) do
    call_if_running(scope, :get_state, nil)
  end

  @doc """
  Returns the names of the scopes that have a running tracker on this node.

  The function skips a tracker that has exited. The Registry removes the entry
  of an exited process after a short delay.
  """
  @spec scopes() :: [Rollcall.scope()]
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

  The argument is `scope` or `{scope, opts}`. The option `:silence_threshold`
  sets the number of ticks without a message after which the tracker deletes a
  peer record. The default is 10.

  Returns `{:ok, pid}`. Returns `{:error, {:already_started, pid}}` when a
  tracker runs for `scope`. `Rollcall.TrackerSupervisor` calls this function.
  """
  @spec start_link(Rollcall.scope() | {Rollcall.scope(), [silence_threshold: pos_integer()]}) ::
          GenServer.on_start()
  def start_link({scope, opts}) do
    GenServer.start_link(__MODULE__, {scope, opts}, name: via(scope))
  end

  def start_link(scope) do
    start_link({scope, []})
  end

  @doc """
  Returns the pid of the tracker for `scope`, or `nil` when no tracker runs.
  """
  @spec whereis(Rollcall.scope()) :: pid() | nil
  def whereis(scope) do
    GenServer.whereis(via(scope))
  end

  @doc """
  Returns the `:via` name that registers the tracker for `scope` in
  `Rollcall.Registry`.
  """
  @spec via(Rollcall.scope()) :: {:via, Registry, {Rollcall.Registry, Rollcall.scope()}}
  def via(scope) do
    {:via, Registry, {Rollcall.Registry, scope}}
  end

  defmodule State do
    @moduledoc """
    The state of a tracker process.

    `local` holds the entries that processes on this node track. `version`
    counts the changes to `local`. `incarnation` is the time at which the
    tracker started. `sent` holds the `local` set and the `version` at the last
    heartbeat. The struct has no `sent` field yet.

    The `incarnation` and the `version` form the stamp of a message. A peer
    compares stamps to order messages that arrive in any order. A tracker that
    restarts gets a newer incarnation, so its peers replace its old entries.

    `peers` maps each peer node to its `Rollcall.Tracker.Peer`. The view of the
    tracker is `local` plus the replica of each peer. `silence_threshold` is the
    number of ticks without a message after which the tracker deletes a peer
    record.

    `monitors` maps each process that has an entry to its monitor. `empty_grace`
    and `empty_timer` control the stop of a tracker that holds no entry.
    """

    alias Rollcall.Tracker.Local
    alias Rollcall.Tracker.Peer

    # `local` has no default. A default runs `Local.new/0` at compile time, and
    # the struct would then hold a literal value of the opaque type `Local.t()`.
    @enforce_keys [:scope, :incarnation, :empty_grace, :local, :silence_threshold]

    defstruct [
      :scope,
      :incarnation,
      :empty_grace,
      :local,
      :silence_threshold,
      empty_timer: nil,
      version: 0,
      monitors: %{},
      peers: %{}
    ]

    @type t :: %__MODULE__{
            scope: Rollcall.scope(),
            incarnation: integer(),
            empty_grace: non_neg_integer(),
            empty_timer: reference() | nil,
            local: Local.t(),
            version: non_neg_integer(),
            monitors: %{pid() => reference()},
            peers: %{node() => Peer.t()},
            silence_threshold: pos_integer()
          }

    @spec bump_version(t()) :: t()
    def bump_version(%__MODULE__{version: version} = state) do
      %{state | version: version + 1}
    end
  end

  @impl true
  @spec init({Rollcall.scope(), keyword()}) :: {:ok, State.t()}
  def init({scope, opts}) do
    Process.set_label({:rollcall_tracker, scope})

    tp(:rollcall_tracker_started, %{scope: scope})

    state = %State{
      scope: scope,
      incarnation: System.os_time(:nanosecond),
      empty_grace: Application.get_env(:rollcall, :empty_grace, :timer.seconds(5)),
      local: Local.new(),
      # This default will get set to something less magic when we do the heartbeat timing.
      silence_threshold: Keyword.get(opts, :silence_threshold, 10)
    }

    {:ok, state}
  end

  # The messages that `track/5`, `untrack/4` and `get_state/1` send.
  @typep call_message ::
           :get_state
           | {:track, pid(), Rollcall.partition(), Rollcall.key(), Rollcall.meta()}
           | {:untrack, pid(), Rollcall.partition(), Rollcall.key()}

  @impl true
  @spec handle_call(call_message(), GenServer.from(), State.t()) ::
          {:reply, {:ok, Rollcall.ref()} | :ok | inspected_state(), State.t()}
  def handle_call(:get_state, _from, state) do
    {:reply, Map.take(state, @inspectable_keys), state}
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
      |> start_empty_timer()

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
  @spec handle_cast({:deliver, Messages.t()}, State.t()) :: {:noreply, State.t()}
  def handle_cast({:deliver, msg}, state) do
    node = node(Messages.origin(msg))
    {:noreply, deliver_message(state, node, Map.get(state.peers, node), msg)}
  end

  # A request carries no state, so a request from an unknown node creates no
  # record.
  defp deliver_message(state, _node, nil, {:request, _origin}), do: state

  defp deliver_message(state, node, nil, msg) do
    {peer, changes} = Peer.new(msg)
    put_peer(state, node, peer, changes)
  end

  defp deliver_message(state, node, %Peer{} = peer, msg) do
    {peer, changes} = Peer.deliver(peer, msg)
    put_peer(state, node, peer, changes)
  end

  defp put_peer(state, node, peer, changes) do
    tp(:rollcall_tracker_peer_message, %{
      scope: state.scope,
      node: node,
      joins: Changes.join_refs(changes),
      leaves: Changes.leave_refs(changes),
      behind: Peer.behind?(peer)
    })

    %{state | peers: Map.put(state.peers, node, peer)}
  end

  @impl true
  @spec handle_info(term(), State.t()) :: {:noreply, State.t()} | {:stop, :normal, State.t()}
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
      |> start_empty_timer()

    tp(:rollcall_tracker_pid_down, %{scope: state.scope, pid: pid})

    {:noreply, state}
  end

  def handle_info(:tick, state) do
    peers =
      Enum.reduce(state.peers, %{}, fn
        {node, peer}, kept ->
          case Peer.tick(peer, state.silence_threshold) do
            {:keep, peer} ->
              Map.put(kept, node, peer)

            {:purge, changes} ->
              tp(:rollcall_tracker_peer_purged, %{
                scope: state.scope,
                node: node,
                joins: Changes.join_refs(changes),
                leaves: Changes.leave_refs(changes)
              })

              kept
          end
      end)

    {:noreply, %{state | peers: peers}}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  defp apply_changes(state, local, changes) do
    state
    |> Map.put(:local, local)
    |> bump_version(changes)
  end

  defp start_empty_timer(%{empty_timer: nil} = state) do
    if Local.empty?(state.local) do
      tp(:rollcall_tracker_empty, %{scope: state.scope})

      %{state | empty_timer: :erlang.start_timer(state.empty_grace, self(), :empty_timeout)}
    else
      state
    end
  end

  defp start_empty_timer(state), do: state

  defp cancel_empty_timer(%{empty_timer: nil} = state), do: state

  defp cancel_empty_timer(%{empty_timer: ref} = state) do
    :erlang.cancel_timer(ref)
    %{state | empty_timer: nil}
  end

  defp bump_version(state, changes) do
    if Changes.empty?(changes) do
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
