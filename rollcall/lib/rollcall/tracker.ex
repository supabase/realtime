defmodule Rollcall.Tracker do
  @moduledoc """
  The process that holds the entries of one scope on this node.

  ## Starting and Supervision

  `Rollcall.Registry` maps a scope to its tracker pid. The tracker has a
  `:via` name, so no atom exists for a scope.

  `Rollcall.TrackerSupervisor` supervises the trackers. The restart type is
  `:temporary`. A crashed tracker does not restart. The next call for its scope
  starts a new tracker.

  Calling `call/2` will automatically take care of finding or starting the 
  process for the scope.

  Use the functions in `Rollcall`. Do not call this module directly.
  """

  use GenServer, restart: :temporary

  @max_retries 3

  @doc """
  Sends `msg` to the tracker for `scope` and returns the reply.

  Starts the tracker when no tracker runs. Sends the message again when the
  tracker is not running or stops before it replies. The call sends the
  message again at most #{@max_retries} times. After that, the call exits with
  the reason of the last failure.
  """
  def call(scope, msg, retries \\ @max_retries) do
    GenServer.call(via(scope), msg)
  catch
    :exit, {reason, _} = caught when reason in [:noproc, :normal, :shutdown] ->
      if retries == 0, do: exit(caught)

      start(scope)
      call(scope, msg, retries - 1)
  end

  @doc """
  Returns the names of the scopes that have a running tracker on this node.
  """
  def scopes do
    Registry.select(Rollcall.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  defp start(scope) do
    case DynamicSupervisor.start_child(Rollcall.TrackerSupervisor, {__MODULE__, scope}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc """
  Starts the tracker for `scope` and registers it in `Rollcall.Registry`.

  Returns `{:error, {:already_started, pid}}` when a tracker runs for `scope`.
  `Rollcall.TrackerSupervisor` calls this function.
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

    {:ok, scope}
  end

  @impl true
  def handle_call(_msg, _from, state) do
    {:reply, {:ok, "ref"}, state}
  end
end
