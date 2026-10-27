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

  @impl true
  def init(scope) do
    Process.set_label({:rollcall_tracker, scope})

    tp(:rollcall_tracker_started, %{scope: scope})

    state = %{
      scope: scope,
      empty_grace: Application.get_env(:rollcall, :empty_grace, :timer.seconds(5)),
      empty_timer: nil,
      local: []
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:track, pid, partition, key, meta}, _from, state) do
    state = Map.put(state, :local, [{pid, partition, key, meta} | state.local])
    state = cancel_empty_timer(state)

    {:reply, {:ok, "ref"}, state}
  end

  def handle_call({:untrack, pid, partition, key}, _from, state) do
    state = %{
      state
      | local:
          Enum.reject(state.local, fn
            {^pid, ^partition, ^key, _} -> true
            _ -> false
          end)
    }

    state =
      if Enum.empty?(state.local) do
        arm_empty_timer(state)
      else
        state
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:timeout, ref, :empty_timeout}, %{empty_timer: ref} = state) do
    tp(:rollcall_tracker_stopped, %{scope: state.scope})

    {:stop, :normal, state}
  end

  def handle_info({:timeout, _stale_ref, :empty_timeout}, state) do
    {:noreply, state}
  end

  defp arm_empty_timer(%{empty_timer: nil} = state) do
    tp(:rollcall_tracker_empty, %{scope: state.scope})

    %{state | empty_timer: :erlang.start_timer(state.empty_grace, self(), :empty_timeout)}
  end

  defp arm_empty_timer(state), do: state

  defp cancel_empty_timer(%{empty_timer: nil} = state), do: state

  defp cancel_empty_timer(%{empty_timer: ref} = state) do
    :erlang.cancel_timer(ref)
    %{state | empty_timer: nil}
  end
end
