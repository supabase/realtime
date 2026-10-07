defmodule RealtimeWeb.Presence.Usage do
  @moduledoc """
  Provides data on Presence usage.

  This metric is currently tied to Phoenix.Presence internals.
  """

  @buckets [5, 10, 25, 50, 100, 200, 500, :infinity]

  @match_spec [{{{:"$1", :_, :_}, :_, :_}, [], [:"$1"]}]
  @select_batch_size 500

  @type bucket :: pos_integer() | :infinity
  @type t :: %{tenant_count: non_neg_integer(), topic_count: non_neg_integer(), buckets: %{bucket() => non_neg_integer()}}

  @doc """
  Gets the current usage data for Phoenix.Tracker.

  This will scan the shards in Phoenix.Tracker and return usage stats.

  Usage stats include:

  * tenant_count: number of tenants using presence
  * topic_count: number of topics in the presence system
  * buckets: a map of topic sizes, i.e. number of members, bucketed in @buckets.
  """
  @spec scan(atom()) :: t()
  def scan(tracker) do
    {tenants, topic_map} =
      tracker
      |> shard_names()
      |> get_members()
      |> merge()

    %{
      buckets: bucket(topic_map),
      tenant_count: MapSet.size(tenants),
      topic_count: length(Map.keys(topic_map))
    }
  end

  defp shard_names(tracker) do
    [{:pool_size, size}] = :ets.lookup(tracker, :pool_size)

    Enum.map(0..(size - 1), &Phoenix.Tracker.Shard.name_for_number(tracker, &1))
  end

  defp get_members(shards), do: Enum.map(shards, &scan_shard/1)

  defp scan_shard(shard) do
    shard
    |> :ets.select(@match_spec, @select_batch_size)
    |> collect_topics({MapSet.new(), Map.new()})
  end

  defp collect_topics(:"$end_of_table", acc), do: acc

  defp collect_topics({topics, continuation}, acc) do
    acc =
      Enum.reduce(topics, acc, fn topic, {tenants, topic_map} ->
        tenant = tenant_from_topic(topic)
        {MapSet.put(tenants, tenant), Map.update(topic_map, topic, 1, &(&1 + 1))}
      end)

    collect_topics(:ets.select(continuation), acc)
  end

  defp tenant_from_topic(topic) do
    [prefix | _] = String.split(topic, ":", parts: 2)

    if String.ends_with?(prefix, "-private") do
      binary_part(prefix, 0, byte_size(prefix) - byte_size("-private"))
    else
      prefix
    end
  end

  defp merge(shards) do
    Enum.reduce(
      shards,
      fn {tenants, topics}, {acc_tenants, acc_topics} ->
        {MapSet.union(acc_tenants, tenants), Map.merge(acc_topics, topics)}
      end
    )
  end

  defp bucket(topics) do
    Enum.reduce(
      topics,
      new_bucket_map(),
      fn
        {_, count}, buckets ->
          Map.update(buckets, bucket_for(count), 0, &(&1 + 1))
      end
    )
  end

  defp new_bucket_map() do
    Enum.reduce(@buckets, Map.new(), fn k, map -> Map.put(map, k, 0) end)
  end

  for bucket <- @buckets do
    case bucket do
      :infinity ->
        defp bucket_for(_count), do: :infinity

      _ ->
        defp bucket_for(count) when count <= unquote(bucket), do: unquote(bucket)
    end
  end
end
