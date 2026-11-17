defmodule Realtime.Presence.Comparison.PhoenixReaderTest do
  use ExUnit.Case, async: true

  alias Phoenix.Tracker.Shard
  alias Realtime.Presence.Comparison.PhoenixReader
  alias Realtime.Tenants
  alias Realtime.Test.PresenceUsageTracker, as: Tracker

  setup context do
    start_supervised!({Tracker, pool_size: context[:pool_size] || 1})
    :ok
  end

  describe "tenant_refs/2" do
    test "returns the refs of the public and the private topics of the tenant only" do
      {:ok, public_1} = Tracker.track(self(), Tenants.tenant_topic("t1", "room"), "k1", %{})
      {:ok, public_2} = Tracker.track(self(), Tenants.tenant_topic("t1", "room"), "k2", %{})
      {:ok, private} = Tracker.track(self(), Tenants.tenant_topic("t1", "other", false), "k1", %{})
      {:ok, _other_tenant} = Tracker.track(self(), Tenants.tenant_topic("t2", "room"), "k1", %{})

      refs = PhoenixReader.tenant_refs(Tracker, "t1")

      assert refs |> Map.keys() |> Enum.sort() == ["t1-private:other", "t1:room"]
      assert Enum.sort(refs["t1:room"]) == Enum.sort([public_1, public_2])
      assert refs["t1-private:other"] == [private]
    end

    test "does not read the topics of a tenant whose id starts with the id of the tenant" do
      {:ok, ref} = Tracker.track(self(), Tenants.tenant_topic("big", "room"), "k1", %{})
      {:ok, _} = Tracker.track(self(), Tenants.tenant_topic("big-private-eye", "room"), "k1", %{})
      {:ok, _} = Tracker.track(self(), Tenants.tenant_topic("bigger", "room"), "k1", %{})

      assert PhoenixReader.tenant_refs(Tracker, "big") == %{"big:room" => [ref]}
    end

    @tag pool_size: 4
    test "reads the topics of every shard" do
      topics = for n <- 1..8, do: Tenants.tenant_topic("t", "room#{n}")

      # The topics must use more than one shard, or the test would pass when the read skips shards.
      assert topics |> Enum.map(&Shard.name_for_topic(Tracker, &1, 4)) |> Enum.uniq() |> length() > 1

      expected =
        Map.new(topics, fn topic ->
          {:ok, ref_1} = Tracker.track(self(), topic, "k1", %{})
          {:ok, ref_2} = Tracker.track(self(), topic, "k2", %{})
          {topic, Enum.sort([ref_1, ref_2])}
        end)

      refs = Map.new(PhoenixReader.tenant_refs(Tracker, "t"), fn {topic, refs} -> {topic, Enum.sort(refs)} end)

      assert refs == expected
    end

    test "returns an empty map when the tracker does not run" do
      assert PhoenixReader.tenant_refs(:no_such_tracker, "t") == %{}
    end
  end

  describe "topic_refs/2" do
    @tag pool_size: 4
    test "returns the refs of one topic, and an empty list for a topic that nobody tracks" do
      topics = for n <- 1..8, do: Tenants.tenant_topic("t", "room#{n}")

      refs =
        Map.new(topics, fn topic ->
          {:ok, ref_1} = Tracker.track(self(), topic, "k1", %{})
          {:ok, ref_2} = Tracker.track(self(), topic, "k2", %{})
          {topic, Enum.sort([ref_1, ref_2])}
        end)

      for {topic, expected} <- refs, do: assert(Enum.sort(PhoenixReader.topic_refs(Tracker, topic)) == expected)

      assert PhoenixReader.topic_refs(Tracker, Tenants.tenant_topic("t", "nobody")) == []
      assert PhoenixReader.topic_refs(:no_such_tracker, "t:room1") == []
    end
  end
end
