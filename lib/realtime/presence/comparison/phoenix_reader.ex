defmodule Realtime.Presence.Comparison.PhoenixReader do
  @moduledoc """
  Reads tenant and topics out of Phoenix for use in Presence Comparison.
  """

  def tenant_refs(tracker, tenant) do
    case pool_size(tracker) do
      :undefined -> %{}
      pool_size -> read_tenant_refs(tracker, tenant, pool_size)
    end
  end

  def topic_refs(tracker, topic) do
    case pool_size(tracker) do
      :undefined -> []
      pool_size -> read_topic_refs(tracker, topic, pool_size)
    end
  end

  defp read_topic_refs(tracker, topic, pool_size) do
    shard = Phoenix.Tracker.Shard.name_for_topic(tracker, topic, pool_size)

    shard_topic_refs(shard, topic)
  rescue
    ArgumentError -> []
  end

  # A match spec cannot match a binary prefix, so the read finds the topics of each prefix
  # in the key order of the shard, then reads the refs of each topic.
  # A table that disappears during the read gives `%{}`, never a partial result.
  defp read_tenant_refs(tracker, tenant, pool_size) do
    prefixes = [tenant <> ":", tenant <> "-private:"]

    for n <- 0..(pool_size - 1), prefix <- prefixes, reduce: %{} do
      acc ->
        shard = Phoenix.Tracker.Shard.name_for_number(tracker, n)

        shard
        |> topics_with_prefix(prefix)
        |> Enum.reduce(acc, fn topic, acc ->
          case shard_topic_refs(shard, topic) do
            [] -> acc
            refs -> Map.put(acc, topic, refs)
          end
        end)
    end
  rescue
    ArgumentError -> %{}
  end

  defp shard_topic_refs(shard, topic) do
    # fn {{^topic, _, _}, meta, _} -> meta.phx_ref
    :ets.select(shard, [{{{topic, :_, :_}, :"$1", :_}, [], [{:map_get, :phx_ref, :"$1"}]}])
  end

  # The shard tables are ordered sets with keys `{topic, pid, key}`. `{prefix, 0, 0}` sorts
  # before every key of the prefix. `{topic, {}, {}}` sorts after every key of the topic,
  # because a tuple sorts after a pid, so the walk skips the other rows of the topic.
  # A topic lives in one shard only.
  defp topics_with_prefix(shard, prefix) do
    Stream.unfold(:ets.next(shard, {prefix, 0, 0}), fn
      :"$end_of_table" ->
        nil

      {topic, _pid, _key} ->
        if String.starts_with?(topic, prefix) do
          {topic, :ets.next(shard, {topic, {}, {}})}
        else
          nil
        end
    end)
  end

  defp pool_size(tracker) do
    [{:pool_size, size}] = :ets.lookup(tracker, :pool_size)
    size
  rescue
    ArgumentError -> :undefined
  end
end
