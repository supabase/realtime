defmodule Realtime.SynShards do
  @moduledoc """
  Implements sharding for Syn
  """
  @shards_num Application.compile_env(:realtime, :syn_shards)

  @spec add_node_to_scopes(atom()) :: :ok
  def add_node_to_scopes(scope) do
    scope
    |> scope_shards()
    |> :syn.add_node_to_scopes()
  end

  @spec join(atom(), term(), pid()) :: :ok | {:error, term()}
  def join(scope, name, pid) do
    scope
    |> shard_by_pid(pid)
    |> :syn.join(name, pid)
  end

  @spec leave(atom(), term(), pid()) :: :ok | {:error, term()}
  def leave(scope, name, pid) do
    scope
    |> shard_by_pid(pid)
    |> :syn.leave(name, pid)
  end

  @spec group_names(atom()) :: [term()]
  def group_names(scope, node \\ false) do
    scope
    |> scope_shards()
    |> Enum.reduce(MapSet.new(), fn shard, acc ->
      group_names =
        if node,
          do: :syn.group_names(shard, node),
          else: :syn.group_names(shard)

      group_names
      |> MapSet.new()
      |> MapSet.union(acc)
    end)
    |> MapSet.to_list()
  end

  @spec member_count(atom(), term(), atom() | boolean()) :: non_neg_integer()
  def member_count(scope, name, node \\ false) do
    scope
    |> scope_shards()
    |> Enum.reduce(0, fn shard, acc ->
      member_count =
        if node,
          do: :syn.member_count(shard, name, node),
          else: :syn.member_count(shard, name)

      member_count + acc
    end)
  end

  @spec scope_shards(atom()) :: [atom()]
  defp scope_shards(scope), do: for(num <- 0..(@shards_num - 1), do: :"#{scope}_#{num}")

  @spec shard_by_pid(atom(), pid()) :: atom()
  defp shard_by_pid(scope, pid), do: :"#{scope}_#{:erlang.phash2(pid, @shards_num)}"
end
