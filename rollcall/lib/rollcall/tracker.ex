defmodule Rollcall.Tracker do
  @moduledoc """
  The process that holds the entries of one scope on this node.

  The tracker holds the local entries, a monitor on each process that tracks an
  entry, a version counter, an incarnation timestamp and the view. It exchanges
  heartbeats with the trackers of the same scope on other nodes.

  ## Starting and Supervision

  `Rollcall.Registry` maps a scope to its tracker pid. The tracker has a
  `:via` name. No atom exists for a scope.

  `Rollcall.TrackerSupervisor` supervises the trackers. The restart type is
  `:temporary`. A crashed tracker does not restart. The next `track` for its
  scope starts a new tracker.

  `call/4` finds the tracker for a scope. It starts the tracker only when
  `start` is true.

  ## Grace period

  The tracker starts a timer when it holds no entry. A `track` cancels the
  timer. When the timer expires, the tracker stops.

  Set the length of the period with the `:empty_grace` key of the `:rollcall`
  application environment, in milliseconds. The tracker reads the key when it
  starts. The default is 5000.

  Use the functions in `Rollcall`. Do not call this module directly.
  """

  use GenServer, restart: :temporary
  use Snabbkaffex, only: :trace
  alias Rollcall.Tracker.Local
  alias Rollcall.Tracker.Local.Changes

  @max_retries 3

  @doc """
  Sends `msg` to the tracker for `scope` and returns the reply.

  The tracker can be not running, or can stop before it replies. Then the
  result depends on `start`:

  * `start` is true: the function starts a tracker and sends `msg` again. It
    sends `msg` again at most `retries` times. After that, it exits with the
    reason of the last failure.
  * `start` is false: the function returns `:ok`.
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

  def get_state(scope) do
    case call(scope, :get_state) do
      :ok -> nil
      {:ok, state} -> Map.take(state, @inspectable_keys)
    end
  end

  @doc """
  Returns the names of the scopes that have a running tracker on this node.
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

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, state}, state}
  end

  def handle_call({:track, pid, partition, key, meta}, _from, state) do
    ref = make_ref()

    {changes, local} = Local.track(state.local, pid, partition, key, meta, ref)

    state =
      state
      |> Map.put(:local, local)
      |> bump_version(changes)
      |> cancel_empty_timer()
      |> watch_pid(pid)

    tp(:rollcall_tracker_track, %{
      scope: state.scope,
      pid: pid,
      partition: partition,
      key: key,
      version: state.version,
      joins: Changes.join_refs(changes),
      leaves: Changes.leave_refs(changes)
    })

    {:reply, {:ok, ref}, state}
  end

  def handle_call({:untrack, pid, partition, key}, _from, state) do
    {changes, local} = Local.untrack(state.local, pid, partition, key)

    state =
      state
      |> Map.put(:local, local)
      |> bump_version(changes)
      |> maybe_unwatch(pid)
      |> arm_empty_timer()

    tp(:rollcall_tracker_untrack, %{
      scope: state.scope,
      pid: pid,
      partition: partition,
      key: key,
      version: state.version,
      joins: Changes.join_refs(changes),
      leaves: Changes.leave_refs(changes)
    })

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
      |> Map.put(:local, local)
      |> bump_version(changes)
      |> remove_monitor(pid)
      |> arm_empty_timer()

    tp(:rollcall_tracker_pid_down, %{scope: state.scope, pid: pid})

    {:noreply, state}
  end

  def handle_info({:timeout, _stale_ref, :empty_timeout}, state) do
    {:noreply, state}
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
