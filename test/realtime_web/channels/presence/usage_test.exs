defmodule RealtimeWeb.Presence.UsageTest do
  use ExUnit.Case, async: true

  alias Realtime.Tenants
  alias Realtime.Test.PresenceUsageTracker, as: Tracker
  alias RealtimeWeb.Presence
  alias RealtimeWeb.Presence.Usage

  setup context do
    start_supervised!({Tracker, pool_size: context[:pool_size] || 1})
    :ok
  end

  test "no tracked presences reports zero tenants, zero topics, and every bucket at zero" do
    assert Usage.scan(Tracker) == %{
             tenant_count: 0,
             topic_count: 0,
             buckets: %{
               5 => 0,
               10 => 0,
               25 => 0,
               50 => 0,
               100 => 0,
               200 => 0,
               500 => 0,
               :infinity => 0
             }
           }
  end

  test "one tracked presence counts one tenant, one topic, and one member in the first bucket" do
    {:ok, _ref} = Tracker.track(self(), Tenants.tenant_topic("tenant1", "room"), "key1", %{})

    assert Usage.scan(Tracker) == %{
             tenant_count: 1,
             topic_count: 1,
             buckets: %{
               5 => 1,
               10 => 0,
               25 => 0,
               50 => 0,
               100 => 0,
               200 => 0,
               500 => 0,
               :infinity => 0
             }
           }
  end

  test "public and private topics for the same tenant count as one tenant" do
    {:ok, _ref} = Tracker.track(self(), Tenants.tenant_topic("tenant1", "room"), "key1", %{})
    {:ok, _ref} = Tracker.track(self(), Tenants.tenant_topic("tenant1", "other", false), "key2", %{})

    assert Usage.scan(Tracker) == %{
             tenant_count: 1,
             topic_count: 2,
             buckets: %{
               5 => 2,
               10 => 0,
               25 => 0,
               50 => 0,
               100 => 0,
               200 => 0,
               500 => 0,
               :infinity => 0
             }
           }
  end

  test "an external_id that merely contains \"-private\" isn't truncated" do
    {:ok, _ref} = Tracker.track(self(), Tenants.tenant_topic("big", "room1"), "key1", %{})
    {:ok, _ref} = Tracker.track(self(), Tenants.tenant_topic("big-private-eye", "room2"), "key2", %{})

    assert Usage.scan(Tracker) == %{
             tenant_count: 2,
             topic_count: 2,
             buckets: %{
               5 => 2,
               10 => 0,
               25 => 0,
               50 => 0,
               100 => 0,
               200 => 0,
               500 => 0,
               :infinity => 0
             }
           }
  end

  test "a public sub_topic containing \"-private:\" doesn't shift the tenant boundary" do
    {:ok, _ref} = Tracker.track(self(), Tenants.tenant_topic("t", "normal"), "key1", %{})
    {:ok, _ref} = Tracker.track(self(), Tenants.tenant_topic("t", "room-private:thing"), "key2", %{})

    assert Usage.scan(Tracker) == %{
             tenant_count: 1,
             topic_count: 2,
             buckets: %{
               5 => 2,
               10 => 0,
               25 => 0,
               50 => 0,
               100 => 0,
               200 => 0,
               500 => 0,
               :infinity => 0
             }
           }
  end

  @tag pool_size: 4
  test "members are aggregated across multiple shards, including empty ones" do
    # phash2-verified at pool_size 4: tenantD:room -> shard 0, tenantB:room -> shard 1,
    # tenantA:room -> shard 2. Shard 3 gets none of these, so merge/1 also covers an empty shard.
    {:ok, _ref} = Tracker.track(self(), Tenants.tenant_topic("tenantD", "room"), "key1", %{})
    {:ok, _ref} = Tracker.track(self(), Tenants.tenant_topic("tenantB", "room"), "key2", %{})
    {:ok, _ref} = Tracker.track(self(), Tenants.tenant_topic("tenantA", "room"), "key3", %{})

    assert Usage.scan(Tracker) == %{
             tenant_count: 3,
             topic_count: 3,
             buckets: %{
               5 => 3,
               10 => 0,
               25 => 0,
               50 => 0,
               100 => 0,
               200 => 0,
               500 => 0,
               :infinity => 0
             }
           }
  end

  test "bucket boundaries are inclusive: 5 members stays in bucket 5, 6 rolls to bucket 10" do
    five = Tenants.tenant_topic("tenant1", "five")
    six = Tenants.tenant_topic("tenant2", "six")

    for key <- ~w(a1 a2 a3 a4 a5), do: {:ok, _ref} = Tracker.track(self(), five, key, %{})
    for key <- ~w(b1 b2 b3 b4 b5 b6), do: {:ok, _ref} = Tracker.track(self(), six, key, %{})

    assert Usage.scan(Tracker) == %{
             tenant_count: 2,
             topic_count: 2,
             buckets: %{
               5 => 1,
               10 => 1,
               25 => 0,
               50 => 0,
               100 => 0,
               200 => 0,
               500 => 0,
               :infinity => 0
             }
           }
  end

  test "counts are aggregated correctly across every bucket" do
    scenarios = [
      {25, "tenant25"},
      {50, "tenant50"},
      {100, "tenant100"},
      {200, "tenant200"},
      {500, "tenant500"},
      {501, "tenant501"}
    ]

    for {count, tenant} <- scenarios do
      topic = Tenants.tenant_topic(tenant, "room")

      for n <- 1..count do
        {:ok, _ref} = Tracker.track(self(), topic, "key#{n}", %{})
      end
    end

    assert Usage.scan(Tracker) == %{
             tenant_count: 6,
             topic_count: 6,
             buckets: %{
               5 => 0,
               10 => 0,
               25 => 1,
               50 => 1,
               100 => 1,
               200 => 1,
               500 => 1,
               :infinity => 1
             }
           }
  end

  test "a shard whose ETS table doesn't exist is treated as empty, not a crash" do
    # No real Phoenix.Presence/Tracker involved here: a bare table just carrying a :pool_size
    # entry, with no shard table ever created behind it - the same symptom a crashed-and-not-yet-
    # restarted shard GenServer would produce, without the timing race of actually causing one.
    tracker = :"usage_test_missing_shard_#{System.unique_integer([:positive])}"
    :ets.new(tracker, [:set, :public, :named_table])
    :ets.insert(tracker, {:pool_size, 1})

    assert Usage.scan(tracker) == %{
             tenant_count: 0,
             topic_count: 0,
             buckets: %{
               5 => 0,
               10 => 0,
               25 => 0,
               50 => 0,
               100 => 0,
               200 => 0,
               500 => 0,
               :infinity => 0
             }
           }
  end

  test "a tracker that hasn't started at all is treated as empty, not a crash" do
    # No ETS table whatsoever, not even a :pool_size entry - the symptom of scanning before
    # RealtimeWeb.Presence has started (e.g. a poller's near-instant first tick during boot).
    tracker = :"usage_test_nonexistent_tracker_#{System.unique_integer([:positive])}"

    assert Usage.scan(tracker) == %{
             tenant_count: 0,
             topic_count: 0,
             buckets: %{
               5 => 0,
               10 => 0,
               25 => 0,
               50 => 0,
               100 => 0,
               200 => 0,
               500 => 0,
               :infinity => 0
             }
           }
  end

  test "scanning the real RealtimeWeb.Presence returns a well-formed result" do
    assert %{tenant_count: tenant_count, topic_count: topic_count, buckets: buckets} =
             Usage.scan(Presence)

    assert is_integer(tenant_count) and tenant_count >= 0
    assert is_integer(topic_count) and topic_count >= 0
    assert Enum.sort(Map.keys(buckets)) == Enum.sort([5, 10, 25, 50, 100, 200, 500, :infinity])
    assert Enum.all?(buckets, fn {_bucket, count} -> is_integer(count) and count >= 0 end)
  end
end
