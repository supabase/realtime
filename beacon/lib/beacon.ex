defmodule Beacon do
  @moduledoc """
  Distributed process group membership tracking.
  """

  alias Beacon.Partition
  alias Beacon.Scope

  @type group :: any
  @type start_option ::
          {:partitions, pos_integer()} | {:broadcast_interval_in_ms, non_neg_integer()}

  @doc "Returns a supervisor child specification for a Beacon scope"
  def child_spec([scope]) when is_atom(scope), do: child_spec([scope, []])
  def child_spec(scope) when is_atom(scope), do: child_spec([scope, []])

  def child_spec([scope, opts]) when is_atom(scope) and is_list(opts) do
    %{
      id: Beacon,
      start: {__MODULE__, :start_link, [scope, opts]},
      type: :supervisor
    }
  end

  @doc """
  Starts the Beacon supervision tree for `scope`.

  Options:

  * `:partitions` - number of partitions to use (default: number of schedulers online)
  * `:broadcast_interval_in_ms`: - interval in milliseconds to broadcast membership counts to other nodes (default: 5000 ms)
  * `:message_module` - module implementing `Beacon.Adapter` behaviour (default: `Beacon.Adapter.ErlDist`)
  """
  @spec start_link(atom, [start_option]) :: Supervisor.on_start()
  def start_link(scope, opts \\ []) when is_atom(scope) do
    {partitions, opts} = Keyword.pop(opts, :partitions, System.schedulers_online())
    broadcast_interval_in_ms = Keyword.get(opts, :broadcast_interval_in_ms)

    if not (is_integer(partitions) and partitions >= 1) do
      raise ArgumentError,
            "expected :partitions to be a positive integer, got: #{inspect(partitions)}"
    end

    if broadcast_interval_in_ms != nil and
         not (is_integer(broadcast_interval_in_ms) and broadcast_interval_in_ms > 0) do
      raise ArgumentError,
            "expected :broadcast_interval_in_ms to be a positive integer, got: #{inspect(broadcast_interval_in_ms)}"
    end

    Beacon.Supervisor.start_link(scope, partitions, opts)
  end

  @doc "Join pid to group in scope"
  @spec join(atom, any, pid) :: :ok | {:error, :not_local}
  def join(_scope, _group, pid) when is_pid(pid) and node(pid) != node(), do: {:error, :not_local}

  def join(scope, group, pid) when is_atom(scope) and is_pid(pid) do
    Partition.join(Beacon.Supervisor.partition(scope, group), group, pid)
  end

  @doc "Leave pid from group in scope"
  @spec leave(atom, group, pid) :: :ok
  def leave(scope, group, pid) when is_atom(scope) and is_pid(pid) do
    Partition.leave(Beacon.Supervisor.partition(scope, group), group, pid)
  end

  @doc "Get total members count per group in scope"
  @spec member_counts(atom) :: %{group => non_neg_integer}
  def member_counts(scope) when is_atom(scope) do
    remote_counts = Scope.member_counts(scope)

    scope
    |> local_member_counts()
    |> Map.merge(remote_counts, fn _k, v1, v2 -> v1 + v2 end)
  end

  @doc "Get total member count of group in scope"
  @spec member_count(atom, group) :: non_neg_integer
  def member_count(scope, group) do
    local_member_count(scope, group) + Scope.member_count(scope, group)
  end

  @doc "Get total member count of group in scope on specific node"
  @spec member_count(atom, group, node) :: non_neg_integer
  def member_count(scope, group, node) when node == node(), do: local_member_count(scope, group)
  def member_count(scope, group, node), do: Scope.member_count(scope, group, node)

  @doc "Get local members of group in scope"
  @spec local_members(atom, group) :: [pid]
  def local_members(scope, group) when is_atom(scope) do
    Partition.members(Beacon.Supervisor.partition(scope, group), group)
  end

  @doc "Get local member count of group in scope"
  @spec local_member_count(atom, group) :: non_neg_integer
  def local_member_count(scope, group) when is_atom(scope) do
    Partition.member_count(Beacon.Supervisor.partition(scope, group), group)
  end

  @doc "Get local members count per group in scope"
  @spec local_member_counts(atom) :: %{group => non_neg_integer}
  def local_member_counts(scope) when is_atom(scope) do
    Enum.reduce(Beacon.Supervisor.partitions(scope), %{}, fn partition_name, acc ->
      Map.merge(acc, Partition.member_counts(partition_name))
    end)
  end

  @doc "Check if pid is a local member of group in scope"
  @spec local_member?(atom, group, pid) :: boolean
  def local_member?(scope, group, pid) when is_atom(scope) and is_pid(pid) do
    Partition.member?(Beacon.Supervisor.partition(scope, group), group, pid)
  end

  @doc "Get all local groups in scope"
  @spec local_groups(atom) :: [group]
  def local_groups(scope) when is_atom(scope) do
    Enum.flat_map(Beacon.Supervisor.partitions(scope), fn partition_name ->
      Partition.groups(partition_name)
    end)
  end

  @doc "Get local group count in scope"
  @spec local_group_count(atom) :: non_neg_integer
  def local_group_count(scope) when is_atom(scope) do
    Enum.sum_by(Beacon.Supervisor.partitions(scope), fn partition_name ->
      Partition.group_count(partition_name)
    end)
  end

  @doc "Get groups in scope"
  @spec groups(atom) :: [group]
  def groups(scope) when is_atom(scope) do
    remote_groups = Scope.groups(scope)

    scope
    |> local_groups()
    |> MapSet.new()
    |> MapSet.union(remote_groups)
    |> MapSet.to_list()
  end

  @doc "Get group count in scope"
  @spec group_count(atom) :: non_neg_integer
  def group_count(scope) when is_atom(scope) do
    remote_groups = Scope.groups(scope)

    scope
    |> local_groups()
    |> MapSet.new()
    |> MapSet.union(remote_groups)
    |> MapSet.size()
  end
end
