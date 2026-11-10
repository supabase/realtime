defmodule Rollcall.Tracker do
  @moduledoc """
  The process that holds the entries of one scope on this node.

  The tracker holds the local entries, a monitor on each process that tracks an
  entry, a version counter, an incarnation, a record for each peer
  node and the view. It exchanges heartbeats with the trackers of the same scope
  on other nodes.

  ## Not built yet

  This module describes the finished design. The tracker does not yet do these
  things:

    * send a request
    * reply to a request with a snapshot
    * hold `sent`, the state at the last heartbeat

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
  value is a number of ticks. The default is 10. With the default heartbeat
  period of 1500 ms, a silent peer is purged after 15 seconds.

  ## Transport

  The tracker sends and receives through a transport. See `Rollcall.Transport`.
  The `:transport` option of `start_link/1` is `{module, opts}`. The default is
  `{Rollcall.Transport.Null, []}`.

  ## Heartbeat

  A tick sends one snapshot of `local` to the peers and counts one quiet period
  for each peer record. The `:heartbeat_period_in_ms` option of `start_link/1` sets the
  time between ticks, in milliseconds. The default is 1500. 

  A tracker that stops sends a goodbye from `terminate/2`. The tracker traps
  exits, so a supervisor shutdown also reaches `terminate/2`. The goodbye is a
  snapshot with no entries, and a peer clears its replica when it arrives. 

  ## Grace period

  A stop of a tracker costs work on every node. The tracker sends a goodbye
  snapshot. The next tracker has a new incarnation, so each peer replaces its
  replica. The new tracker has no peers. It learns each peer from a heartbeat,
  then asks for a snapshot. A scope that loses its last process and gets a new
  process soon after pays this cost on each cycle.

  The tracker waits for a grace period before it stops. It starts a timer when
  it holds no entry. A `track` cancels the timer. When the timer expires, the
  tracker asks the transport with `c:Rollcall.Transport.has_interest?/1`. The
  tracker stops when the transport has no interest. It starts the timer again
  when the transport has interest. A transport that does not implement the
  callback has no interest.

  The tracker holds the entries of its peers. A node that has listeners and no
  entry of its own needs them. A stop would leave the listeners with no state
  and no diffs.

  The cost of the wait is an idle tracker. It still sends a heartbeat in each
  period. The best length depends on the heartbeat period.

  Set the length of the period with the `:empty_grace_in_ms` option of
  `start_link/1`, in milliseconds. The default is 5000.

  ## Trace points

  The tracker emits these trace points.

    * `:rollcall_tracker_joined` - the tracker joined its scope through the
      transport. The event has the keys `scope` and `origin`. The tracker emits
      it before `:rollcall_tracker_started`.
    * `:rollcall_tracker_started` - the tracker started.
    * `:rollcall_tracker_empty` - the tracker holds no entry, and the timer of
      the grace period started.
    * `:rollcall_tracker_stopped` - the timer expired. The tracker stops after
      the event.
    * `:rollcall_tracker_heartbeat_sent` - a tick sent a snapshot. The event has
      the keys `scope`, `origin`, `kind`, `version` and `refs`. `kind` is
      `:snapshot`. `refs` lists the refs of the entries in the message.
    * `:rollcall_tracker_goodbye_sent` - the tracker sent the goodbye. The event
      has the keys `scope`, `origin` and `version`. The `version` is the version
      of the goodbye message.
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
    * `:rollcall_tracker_message_dropped` - the tracker dropped a message and
      changed nothing. The event has the keys `message_scope`, `node` and
      `reason`. The reason is `:wrong_scope` or `:local_origin`.

  Use the functions in `Rollcall`. Do not call this module directly.
  """

  use GenServer, restart: :temporary
  use Snabbkaffex, only: :trace
  alias Rollcall.Tracker.Entry
  alias Rollcall.Tracker.Local
  alias Rollcall.Tracker.Changes
  alias Rollcall.Tracker.Messages
  alias Rollcall.Tracker.Peer
  alias Rollcall.Tracker.State
  alias Rollcall.Tracker.View

  @max_retries 3
  @default_empty_grace_in_ms :timer.seconds(5)
  # Default to sending a heartbeat every 1.5 seconds
  @default_heartbeat_period_in_ms 1500
  # this how many heartbeat period before we assume a peer is dead
  @default_silence_threshold 10
  @default_transport {Rollcall.Transport.Null, []}

  @init_options [:transport, :heartbeat_period_in_ms, :silence_threshold, :empty_grace_in_ms]

  # The exit reasons of a call when no tracker runs, or when the tracker stops
  # before it replies.
  @gone [:noproc, :normal, :shutdown]

  @type transport :: {module(), keyword()}

  @type init_options :: [
          silence_threshold: pos_integer(),
          transport: transport(),
          heartbeat_period_in_ms: pos_integer() | :manual,
          empty_grace_in_ms: non_neg_integer(),
          name: Rollcall.name()
        ]

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
  @spec track(
          Rollcall.name(),
          Rollcall.scope(),
          pid(),
          Rollcall.partition(),
          Rollcall.key(),
          Rollcall.meta(),
          Keyword.t()
        ) ::
          {:ok, Rollcall.ref()} | {:error, term()}
  def track(name, scope, pid, partition, key, meta, opts \\ []) when is_pid(pid) and is_map(meta) do
    call_or_start(name, scope, {:track, pid, partition, key, meta, opts}, @max_retries)
  end

  # Calls the tracker for `scope`. Starts a tracker and sends the message again
  # when none runs, at most `retries` times.
  defp call_or_start(name, scope, message, retries) do
    GenServer.call(via(name, scope), message)
  catch
    :exit, {reason, _} = caught when reason in @gone ->
      if retries == 0, do: exit(caught)

      case start(name, scope) do
        :ok -> call_or_start(name, scope, message, retries - 1)
        error -> error
      end
  end

  @doc """
  Starts the tracker for `scope` in the instance `name`.

  Returns `:ok` also when a tracker runs already. Call `Rollcall.ensure_started/2`
  instead. It does not start a child when a tracker runs.
  """
  @spec start(Rollcall.name(), Rollcall.scope()) :: :ok | {:error, term()}
  def start(name, scope) do
    # The options of the library, stored in the registry by `Rollcall.start_link/1`.
    {:ok, opts} = Registry.meta(name, :tracker_options)
    {:ok, tracker_supervisor} = Registry.meta(name, :tracker_supervisor)

    case DynamicSupervisor.start_child(tracker_supervisor, {__MODULE__, {scope, Keyword.put(opts, :name, name)}}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
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
  @spec untrack(Rollcall.name(), Rollcall.scope(), pid(), Rollcall.partition(), Rollcall.key()) :: :ok
  def untrack(name, scope, pid, partition, key) do
    call_if_running(name, scope, {:untrack, pid, partition, key}, :ok)
  end

  # Calls the tracker for `scope`. Returns `default` when no tracker runs, when
  # the tracker stops before it replies, or when the instance does not run.
  defp call_if_running(name, scope, message, default) do
    case lookup(name, scope) do
      [{pid, _}] -> GenServer.call(pid, message)
      [] -> default
    end
  catch
    :exit, {reason, _} when reason in @gone -> default
  end

  # `Registry.lookup/2` raises `ArgumentError` when the Registry does not exist.
  defp lookup(name, scope) do
    Registry.lookup(name, scope)
  rescue
    ArgumentError -> []
  end

  @doc """
  Returns the state of the tracker for `scope`, or `nil` when no tracker runs.

  The state is a map with the keys `scope`, `version`, `incarnation`, `local`
  and `peers`. The value of `local` is a `Rollcall.Tracker.Local` set. The value
  of `peers` maps each peer node to its `Rollcall.Tracker.Peer`.

  The map holds the fields that have a meaning outside the process. The timer
  and the monitors stay private, so a change to them does not break a caller.

  The function does not start a tracker. Use it in tests and for debugging.
  """
  @spec get_state(Rollcall.name(), Rollcall.scope()) :: State.view() | nil
  def get_state(name, scope) do
    call_if_running(name, scope, :get_state, nil)
  end

  @doc """
  Returns the names of the scopes that have a running tracker on this node.

  The function skips a tracker that has exited. The Registry removes the entry
  of an exited process after a short delay.
  """
  @spec scopes(Rollcall.name()) :: [Rollcall.scope()]
  def scopes(name) do
    name
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {_, pid} -> Process.alive?(pid) end)
    |> Enum.map(fn {scope, _} -> scope end)
  end

  @doc """
  Returns every entry in the view of `scope`. See `Rollcall.state/2`.
  """
  @spec state(Rollcall.name(), Rollcall.scope()) :: [Rollcall.scope_entry()]
  def state(name, scope) do
    with_view(name, scope, fn view -> View.entries(view) end)
  end

  @doc """
  Returns the entries in `partition` of the view of `scope`. See
  `Rollcall.state/3`.
  """
  @spec state(Rollcall.name(), Rollcall.scope(), Rollcall.partition()) :: [Rollcall.entry()]
  def state(name, scope, partition) do
    with_view(name, scope, fn view -> View.entries(view, partition) end)
  end

  defp with_view(name, scope, fun) do
    case lookup(name, scope) do
      [{_tracker, nil}] -> []
      [{_tracker, view}] -> fun.(view)
      _ -> []
    end
  end

  @doc """
  Starts the tracker for `scope` and registers it in the instance's registry.

  The argument is `{scope, opts}`. The option `:name` is required. It is the
  name of the instance of Rollcall, and the tracker registers in the registry
  of that instance.

  The option `:silence_threshold` sets the number of ticks without a message
  after which the tracker deletes a peer record. The default is 10.

  The option `:transport` is `{module, opts}`. It sets the transport. The
  default is the Null transport.

  The option `:heartbeat_period_in_ms` is the time between ticks in milliseconds,
  or `:manual`. The default is 1500.

  The option `:empty_grace_in_ms` is the time in milliseconds that the tracker
  waits with no entry before it stops. The default is 5000.

  Returns `{:ok, pid}`. Returns `{:error, {:already_started, pid}}` when a
  tracker runs for `scope`. 
  """
  @spec start_link({Rollcall.scope(), init_options()}) :: GenServer.on_start()
  def start_link({scope, opts}) do
    GenServer.start_link(__MODULE__, {scope, opts}, name: via(Keyword.fetch!(opts, :name), scope))
  end

  @doc """
  Returns the pid of the tracker for `scope`, or `nil` when no tracker runs.
  """
  @spec whereis(Rollcall.name(), Rollcall.scope()) :: pid() | nil
  def whereis(name, scope) do
    GenServer.whereis(via(name, scope))
  end

  @doc """
  Returns the `:via` name that registers the tracker for `scope`.
  """
  @spec via(Rollcall.name(), Rollcall.scope()) :: {:via, Registry, {Rollcall.name(), Rollcall.scope()}}
  def via(name, scope) do
    {:via, Registry, {name, scope}}
  end

  @doc """
  Returns the option keys that `Rollcall.start_link/1` accepts, except `:name`.
  """
  @spec init_options() :: [atom()]
  def init_options do
    @init_options
  end

  @impl true
  @spec init({Rollcall.scope(), keyword()}) :: {:ok, State.t()}
  def init({scope, opts}) do
    Process.set_label({:rollcall_tracker, scope})

    {transport_module, transport_opts} = Keyword.get(opts, :transport, @default_transport)
    {:ok, transport_state} = transport_module.init(scope, transport_opts)

    tp(:rollcall_tracker_joined, %{scope: scope, origin: self()})

    view = View.new()

    {_new, _old} = Registry.update_value(Keyword.fetch!(opts, :name), scope, fn _ -> view end)

    state = %State{
      scope: scope,
      incarnation: System.monotonic_time(:nanosecond),
      local: Local.new(),
      view: view,
      empty_grace_in_ms: Keyword.get(opts, :empty_grace_in_ms, @default_empty_grace_in_ms),
      silence_threshold: Keyword.get(opts, :silence_threshold, @default_silence_threshold),
      heartbeat_period_in_ms: Keyword.get(opts, :heartbeat_period_in_ms, @default_heartbeat_period_in_ms),
      transport_module: transport_module,
      transport_state: transport_state
    }

    # Trap exists in this process so we get terminate/2 callbacks and can send goodbye messages
    Process.flag(:trap_exit, true)

    tp(:rollcall_tracker_started, %{scope: scope})

    state =
      state
      |> schedule_heartbeat()
      |> start_empty_timer()

    {:ok, state}
  end

  # The messages that `track/7`, `untrack/5` and `get_state/2` send.
  @typep call_message ::
           :get_state
           | {:track, pid(), Rollcall.partition(), Rollcall.key(), Rollcall.meta(), Keyword.t()}
           | {:untrack, pid(), Rollcall.partition(), Rollcall.key()}

  @impl true
  @spec handle_call(call_message(), GenServer.from(), State.t()) ::
          {:reply, {:ok, Rollcall.ref()} | :ok | State.view(), State.t()}
  def handle_call(:get_state, _from, state) do
    {:reply, State.inspect_view(state), state}
  end

  def handle_call({:track, pid, partition, key, meta, opts}, _from, state) do
    ref = Keyword.get(opts, :ref) || random_ref()

    {changes, local} = Local.track(state.local, pid, partition, key, meta, ref)

    state =
      state
      |> State.apply_changes(local, changes)
      |> update_view(changes)
      |> publish_changes(changes)
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
      |> State.apply_changes(local, changes)
      |> update_view(changes)
      |> publish_changes(changes)
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
  @spec handle_info(term(), State.t()) :: {:noreply, State.t()} | {:stop, :normal, State.t()}
  def handle_info({:timeout, ref, :empty_timeout}, %{empty_timer: ref} = state) do
    if Local.empty?(state.local) do
      if transport_has_interest?(state) do
        {:noreply, start_empty_timer(%{state | empty_timer: nil})}
      else
        tp(:rollcall_tracker_stopped, %{scope: state.scope})

        {:stop, :normal, state}
      end
    else
      tp(:rollcall_tracker_stop_skipped, %{scope: state.scope})

      {:noreply, %{state | empty_timer: nil}}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {changes, local} = Local.untrack_pid(state.local, pid)

    state =
      state
      |> State.apply_changes(local, changes)
      |> update_view(changes)
      |> publish_changes(changes)
      |> remove_monitor(pid)
      |> start_empty_timer()

    tp(:rollcall_tracker_pid_down, %{scope: state.scope, pid: pid})

    {:noreply, state}
  end

  def handle_info(:tick, state) do
    state =
      state
      |> send_heartbeat()
      |> tick_and_purge_peers()
      |> schedule_heartbeat()

    {:noreply, state}
  end

  # In this catch all handle_info, we see if the message was a message from one
  # of the peers in the cluster. This is done by attempting to unwrap it using the
  # the transport. If successful, we'll process it, otherwise we ignore it.
  def handle_info(msg, state) do
    case state.transport_module.unwrap(state.transport_state, msg) do
      {:ok, scope, msg} ->
        cond do
          # Drop invalid messages
          not Messages.message?(msg) ->
            {:noreply, drop_message(state, :malformed, scope, nil)}

          scope != state.scope ->
            {:noreply, drop_message(state, :wrong_scope, scope, Messages.origin_node(msg))}

          # Valid message from the same scope
          true ->
            origin = node(Messages.origin(msg))
            new_state = deliver_message(state, origin, State.peer(state, origin), msg)

            {:noreply, new_state}
        end

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    # When terminating we send a goodbye message, which is an empty snapshot.
    #
    # We need to bump the version on a goodbye to make sure any peer holding our current
    # state applies the goodbye.
    stamp = State.goodbye_stamp(state)
    {:stamp, _incarnation, goodbye_version} = stamp
    snapshot = Messages.snapshot(self(), stamp, [])

    :ok = state.transport_module.heartbeat(state.transport_state, snapshot)

    tp(:rollcall_tracker_goodbye_sent, %{scope: state.scope, origin: self(), version: goodbye_version})
  end

  # The transport does not send a message to its own node. The clause makes a
  # tracker safe when it does.
  defp deliver_message(state, node, _peer, _msg) when node == node() do
    drop_message(state, :local_origin, state.scope, node)
  end

  # A request carries no state, so a request from an unknown node creates no
  # record.
  defp deliver_message(state, _node, nil, {:request, _origin}), do: state

  defp deliver_message(state, node, nil, msg) do
    {peer, changes} = Peer.new(msg)
    put_peer(state, node, peer, changes)
  end

  defp deliver_message(state, node, %Peer{} = peer, msg) do
    {peer, changes} = Peer.apply(peer, msg)
    put_peer(state, node, peer, changes)
  end

  defp drop_message(state, reason, message_scope, origin_node) do
    tp(:rollcall_tracker_message_dropped, %{
      scope: state.scope,
      message_scope: message_scope,
      node: origin_node,
      reason: reason
    })

    state
  end

  defp put_peer(state, node, peer, changes) do
    tp(:rollcall_tracker_peer_message, %{
      scope: state.scope,
      node: node,
      joins: Changes.join_refs(changes),
      leaves: Changes.leave_refs(changes),
      behind: Peer.behind?(peer)
    })

    state
    |> State.put_peer(node, peer)
    |> update_view(changes)
    |> publish_changes(changes)
  end

  defp tick_and_purge_peers(%State{} = state) do
    peers =
      Enum.reduce(state.peers, %{}, fn
        {node, peer}, kept ->
          case Peer.tick(peer, state.silence_threshold) do
            {:keep, peer} ->
              Map.put(kept, node, peer)

            {:purge, changes} ->
              state
              |> update_view(changes)
              |> publish_changes(changes)

              tp(:rollcall_tracker_peer_purged, %{
                scope: state.scope,
                node: node,
                joins: Changes.join_refs(changes),
                leaves: Changes.leave_refs(changes)
              })

              kept
          end
      end)

    %{state | peers: peers}
  end

  defp update_view(state, changes) do
    View.write(state.view, changes)

    state
  end

  # `function_exported?/3` does not load a module. The transport module is
  # loaded, because `init/2` ran when the tracker started.
  defp transport_has_interest?(state) do
    function_exported?(state.transport_module, :has_interest?, 1) and
      state.transport_module.has_interest?(state.transport_state)
  end

  defp publish_changes(state, changes) do
    for {partition, diff} <- Changes.partition_diffs(changes) do
      :ok = state.transport_module.publish(state.transport_state, partition, diff)

      tp(
        :rollcall_tracker_published,
        %{
          scope: state.scope,
          partition: partition,
          joins: diff |> elem(0) |> Enum.map(&elem(&1, 0)),
          leaves: diff |> elem(1) |> Enum.map(&elem(&1, 0))
        },
        ignore_side_effects: true
      )
    end

    state
  end

  defp send_heartbeat(%State{} = state) do
    local_entries = Local.entries(state.local)

    snapshot_entries = Enum.map(local_entries, &Entry.to_wire_entry/1)
    snapshot = Messages.snapshot(self(), State.current_stamp(state), snapshot_entries)

    :ok = state.transport_module.heartbeat(state.transport_state, snapshot)

    tp(:rollcall_tracker_heartbeat_sent, %{
      scope: state.scope,
      origin: self(),
      kind: :snapshot,
      version: state.version,
      refs: Enum.map(local_entries, & &1.ref)
    })

    state
  end

  defp schedule_heartbeat(%State{heartbeat_period_in_ms: :manual} = state), do: state

  defp schedule_heartbeat(%State{heartbeat_period_in_ms: heartbeat_period_in_ms} = state) do
    Process.send_after(self(), :tick, heartbeat_period_in_ms)

    state
  end

  defp start_empty_timer(%{empty_timer: nil} = state) do
    if Local.empty?(state.local) do
      tp(:rollcall_tracker_empty, %{scope: state.scope})

      %{state | empty_timer: :erlang.start_timer(state.empty_grace_in_ms, self(), :empty_timeout)}
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

  defp random_ref do
    binary = <<
      System.system_time(:nanosecond)::64,
      :erlang.phash2({node(), self()})::16,
      :erlang.unique_integer()::16
    >>

    Base.url_encode64(binary)
  end
end
