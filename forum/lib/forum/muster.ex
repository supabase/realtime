defmodule Forum.Muster do
  @moduledoc """
  Group-aware fan-out broadcast.

  For every group, exactly one node in the cluster is the **designated** node
  (chosen by `:erlang.phash2/2` over the sorted Muster cluster membership).
  The designated node knows which nodes hold local members of that group and
  acts as the fan-out hub for broadcasts.

  Use a different scope name than any `Forum.Census` scope on the same node.
  """

  alias Forum.Partition

  @type group :: Forum.group()
  @type start_option ::
          {:partitions, pos_integer()}
          | {:vacancy_cooldown_ms, non_neg_integer()}
          | {:rpc_timeout_ms, timeout()}
          | {:message_module, module()}

  # Timeout for the local GenServer.call to Scope. Generous because the
  # underlying RPC timeout is what actually bounds the wait; this just needs
  # to be longer than that. The supervisor restarts Scope if it crashes, so
  # callers won't wait forever on a dead Scope. During a rebalance, callers
  # stay parked on this call until the rebalance settles them with :ok.
  @claim_call_timeout 60_000

  @doc "Returns a supervisor child specification."
  def child_spec([scope]) when is_atom(scope), do: child_spec([scope, []])
  def child_spec(scope) when is_atom(scope), do: child_spec([scope, []])

  def child_spec([scope, opts]) when is_atom(scope) and is_list(opts) do
    %{
      id: {Forum.Muster, scope},
      start: {__MODULE__, :start_link, [scope, opts]},
      type: :supervisor
    }
  end

  @doc """
  Starts the Muster supervision tree for `scope`.

  Options:

  * `:partitions` — number of local partitions (default: schedulers online).
  * `:vacancy_cooldown_ms` — how long to wait after a group goes vacant locally
    before notifying the designated node (default: 30_000).
  * `:rpc_timeout_ms` — timeout for designated-node RPCs (default: 5_000).
  * `:message_module` — module implementing `Forum.Adapter` (default:
    `Forum.Adapter.ErlDist`).
  """
  @spec start_link(atom, [start_option]) :: Supervisor.on_start()
  def start_link(scope, opts \\ []) when is_atom(scope) do
    {partitions, opts} = Keyword.pop(opts, :partitions, System.schedulers_online())

    if not (is_integer(partitions) and partitions >= 1) do
      raise ArgumentError,
            "expected :partitions to be a positive integer, got: #{inspect(partitions)}"
    end

    cooldown = Keyword.get(opts, :vacancy_cooldown_ms)

    if cooldown != nil and not (is_integer(cooldown) and cooldown >= 0) do
      raise ArgumentError,
            "expected :vacancy_cooldown_ms to be a non-negative integer, got: #{inspect(cooldown)}"
    end

    Forum.Supervisor.start_link(Forum.Muster.Scope, scope, partitions, opts)
  end

  @doc """
  Join `pid` to `group` in `scope`.

  If this is the first local member of `group` and the group has not been
  recently vacant, the designated node is notified via a synchronous RPC.
  If that RPC fails, the join fails and the pid is not registered locally.
  The next call to `join/3` will retry the RPC.
  """
  @spec join(atom, group, pid) :: :ok | {:error, :not_local | :rpc_failed | term}
  def join(_scope, _group, pid) when is_pid(pid) and node(pid) != node(),
    do: {:error, :not_local}

  def join(scope, group, pid) when is_atom(scope) and is_pid(pid) do
    partition = Forum.Supervisor.partition(scope, group)

    if Partition.member_count(partition, group) > 0 do
      Partition.join(partition, group, pid)
    else
      case claim(scope, group) do
        :ok ->
          Partition.join(partition, group, pid)

        {:error, _} = err ->
          err
      end
    end
  end

  @doc "Remove `pid` from `group` in `scope`."
  @spec leave(atom, group, pid) :: :ok
  def leave(scope, group, pid) when is_atom(scope) and is_pid(pid) do
    Partition.leave(Forum.Supervisor.partition(scope, group), group, pid)
  end

  @doc """
  Returns the designated node for `group` in `scope`.

  * `{:ok, node}` — cluster view is stable; route to `node`.
  * `{:rebalancing, [node]}` — the local Scope is settling a membership
    change. The designated mapping is in flux; callers using their own
    transport should fan out to every node in the list rather than
    targeting a single designated.
  """
  @spec designated(atom, group) :: {:ok, node} | {:rebalancing, [node]}
  def designated(scope, group) when is_atom(scope) do
    case :persistent_term.get({Forum.Muster, scope, :status}) do
      :stable ->
        # ExHashRing.Ring.find_node already returns {:ok, node}.
        ExHashRing.Ring.find_node(ring_name(scope), group)

      :rebalancing ->
        {:ok, members} = ExHashRing.Ring.get_nodes(ring_name(scope))
        {:rebalancing, members}
    end
  end

  @doc "Returns the current Muster cluster member nodes for `scope`."
  @spec members(atom) :: [node]
  def members(scope) when is_atom(scope) do
    {:ok, ns} = ExHashRing.Ring.get_nodes(ring_name(scope))
    ns
  end

  defp ring_name(scope), do: :"#{scope}_muster_ring"

  @doc "List local pids registered to `group` in `scope`."
  @spec local_members(atom, group) :: [pid]
  def local_members(scope, group) when is_atom(scope) do
    Partition.members(Forum.Supervisor.partition(scope, group), group)
  end

  @doc "Whether `pid` is a local member of `group` in `scope`."
  @spec local_member?(atom, group, pid) :: boolean
  def local_member?(scope, group, pid) when is_atom(scope) and is_pid(pid) do
    Partition.member?(Forum.Supervisor.partition(scope, group), group, pid)
  end

  @doc "Local member count for `group` in `scope`."
  @spec local_member_count(atom, group) :: non_neg_integer
  def local_member_count(scope, group) when is_atom(scope) do
    Partition.member_count(Forum.Supervisor.partition(scope, group), group)
  end

  defp claim(scope, group) do
    GenServer.call(Forum.Supervisor.name(scope), {:claim, group}, @claim_call_timeout)
  catch
    :exit, reason -> {:error, {:scope_exit, reason}}
  end
end
