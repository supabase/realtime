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

  @spec group_names(atom()) :: [term()]
  def group_names(scope, node \\ false) do
    scope
    |> scope_shards()
    |> Enum.reduce([], fn shard, acc ->
      group_names =
        if node,
          do: :syn.group_names(shard, node),
          else: :syn.group_names(shard)

      group_names ++ acc
    end)
    |> Enum.uniq()
  end

  @spec join(atom(), term(), pid()) :: :ok | {:error, term()}
  def join(scope, name, pid) do
    scope
    |> shard_by_name(name)
    |> :syn.join(name, pid)
  end

  @spec member_count(atom(), term()) :: non_neg_integer()
  def member_count(scope, name, node \\ false) do
    scope =
      shard_by_name(scope, name)

    if node,
      do: :syn.member_count(scope, name, node),
      else: :syn.member_count(scope, name)
  end

  @spec leave(atom(), term(), pid()) :: :ok | {:error, term()}
  def leave(scope, name, pid) do
    scope
    |> shard_by_name(name)
    |> :syn.leave(name, pid)
  end

  @spec scope_shards(atom()) :: [atom()]
  defp scope_shards(scope), do: for(num <- 1..@shards_num, do: :"#{scope}_#{num}")

  @spec shard_by_name(atom(), term()) :: atom()
  defp shard_by_name(scope, name),
    do: :"#{scope}_#{:erlang.phash2(name, @shards_num)}"
end
