defmodule RealtimeWeb.Presence.Usage do
  @moduledoc """
  Provides data on Presence usage.

  This metric is currently tied to Phoenix.Presence internals.
  """

  @buckets [5, 10, 25, 50, 100, 200, 500, :infinity]
  @default_bucket_map Enum.reduce(@buckets, Map.new(), fn k, map -> Map.put(map, k, 0) end)

  @match_spec [{{{:"$1", :_, :_}, :_, :_}, [], [:"$1"]}]
  @select_batch_size 500

  @type bucket :: pos_integer() | :infinity
  @type t :: %{
          tenant_count: non_neg_integer(),
          topic_count: non_neg_integer(),
          buckets: %{bucket() => non_neg_integer()}
        }

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
    topic_counts =
      tracker
      |> shard_names()
      |> get_members()
      |> Enum.frequencies()

    {tenants, buckets} =
      Enum.reduce(topic_counts, {MapSet.new(), @default_bucket_map}, fn
        {topic, count}, {tenants, buckets} ->
          {MapSet.put(tenants, tenant_from_topic(topic)), Map.update(buckets, bucket_for(count), 0, &(&1 + 1))}
      end)

    %{
      buckets: buckets,
      tenant_count: MapSet.size(tenants),
      topic_count: map_size(topic_counts)
    }
  end

  defp shard_names(tracker) do
    case :ets.whereis(tracker) do
      :undefined ->
        []

      _tid ->
        [{:pool_size, size}] = :ets.lookup(tracker, :pool_size)
        Enum.map(0..(size - 1), &Phoenix.Tracker.Shard.name_for_number(tracker, &1))
    end
  end

  defp get_members(shards) do
    Stream.flat_map(
      shards,
      fn
        shard ->
          Stream.resource(
            fn -> handling_missing_table(fn -> :ets.select(shard, @match_spec, @select_batch_size) end) end,
            fn
              :missing_table ->
                {:halt, :missing_table}

              :"$end_of_table" ->
                {:halt, :ok}

              {topics, continuation} ->
                case handling_missing_table(fn -> :ets.select(continuation) end) do
                  :missing_table -> {topics, :missing_table}
                  next -> {topics, next}
                end
            end,
            fn _ -> :ok end
          )
      end
    )
  end

  defp handling_missing_table(f) do
    f.()
  rescue
    ArgumentError -> :missing_table
  end

  defp tenant_from_topic(topic) do
    [prefix | _] = String.split(topic, ":", parts: 2)

    if String.ends_with?(prefix, "-private") do
      binary_part(prefix, 0, byte_size(prefix) - byte_size("-private"))
    else
      prefix
    end
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
