defmodule Realtime.PromEx.Plugins.PresenceTest do
  use Realtime.DataCase, async: false

  alias Realtime.GenRpcPubSub.Worker
  alias Realtime.PromEx.Plugins.Presence

  @worker Realtime.PubSubElixir.Realtime.PubSub.Adapter_1

  defmodule MetricsTest do
    use PromEx, otp_app: :realtime_test_presence
    @impl true
    def plugins, do: [{Presence, poll_rate: 5_000}]
  end

  setup_all do
    start_supervised!(MetricsTest)
    :ok
  end

  test "sizes Phoenix.Tracker messages received via :ftl and :ftr" do
    tracker_msg = {:pub, :heartbeat, {:shard, 1}, :empty, %{}}
    ftl = Worker.forward_to_local("phx_presence:shard_1", tracker_msg, Phoenix.PubSub)
    ftr = Worker.forward_to_region("phx_presence:shard_1", tracker_msg, Phoenix.PubSub)

    bytes_before = metric_value("realtime_presence_replication_received_bytes") || 0

    send(@worker, ftl)
    send(@worker, ftr)
    :sys.get_state(@worker)

    assert metric_value("realtime_presence_replication_received_bytes") ==
             bytes_before + :erlang.external_size(ftl) + :erlang.external_size(ftr)
  end

  test "ignores non-presence topics" do
    bytes_before = metric_value("realtime_presence_replication_received_bytes") || 0

    send(@worker, Worker.forward_to_local("realtime:some_topic", :hello, Phoenix.PubSub))
    :sys.get_state(@worker)

    assert (metric_value("realtime_presence_replication_received_bytes") || 0) == bytes_before
  end

  describe "track latency" do
    alias RealtimeWeb.Presence.Metrics
    alias RealtimeWeb.Presence.Metrics.Envelope

    @latency "realtime_presence_notify_latency"
    @discarded "realtime_presence_notify_discarded"

    test "buckets each observation by action, origin and path" do
      tags = [action: "track", origin: "local", path: "fastlane", implementation: "phoenix"]
      context = %{tenant: "t", path: :fastlane, implementation: :phoenix, now: 10_000, node: "n1"}

      le_25_before = metric_value(@latency <> "_bucket", tags ++ [le: "25.0"]) || 0
      count_before = metric_value(@latency <> "_count", tags) || 0

      # 20ms and 400ms: one lands under le="25", both count.
      Metrics.record([%Envelope{ts: 9_980, node: "n1", action: :track}], context)
      Metrics.record([%Envelope{ts: 9_600, node: "n1", action: :track}], context)

      assert metric_value(@latency <> "_bucket", tags ++ [le: "25.0"]) == le_25_before + 1
      assert metric_value(@latency <> "_count", tags) == count_before + 2
    end

    test "counts discarded observations by reason without recording a latency" do
      tags = [reason: "stale", action: "update", origin: "remote", path: "channel", implementation: "phoenix"]
      context = %{tenant: "t", path: :channel, implementation: :phoenix, now: 100_000, node: "n1"}
      latency_tags = [action: "update", origin: "remote", path: "channel", implementation: "phoenix"]

      discarded_before = metric_value(@discarded, tags) || 0
      count_before = metric_value(@latency <> "_count", latency_tags) || 0

      Metrics.record([%Envelope{ts: 1, node: "elsewhere", action: :update}], context)

      assert metric_value(@discarded, tags) == discarded_before + 1
      assert (metric_value(@latency <> "_count", latency_tags) || 0) == count_before
    end
  end

  describe "usage metrics" do
    alias Realtime.Tenants
    alias Realtime.Test.PresenceUsageTracker, as: Tracker

    @buckets [5, 10, 25, 50, 100, 200, 500, :infinity]

    setup do
      start_supervised!({Tracker, pool_size: 1})
      :ok
    end

    test "scans the given tracker and records tenant count, topic count, and every bucket" do
      {:ok, _ref} = Tracker.track(self(), Tenants.tenant_topic("tenant1", "room"), "key1", %{})
      {:ok, _ref} = Tracker.track(self(), Tenants.tenant_topic("tenant2", "room"), "key1", %{})

      Presence.execute_usage_metrics(Tracker)

      assert metric_value("realtime_presence_usage_tenants", []) == 2
      assert metric_value("realtime_presence_usage_topics", []) == 2

      for bucket <- @buckets do
        expected = if bucket == 5, do: 2, else: 0
        assert metric_value("realtime_presence_usage_topics_by_bucket", bucket: bucket) == expected
      end
    end

    test "re-scanning overwrites stale values, including buckets dropping back to zero" do
      topic = Tenants.tenant_topic("tenant1", "room")
      {:ok, _ref} = Tracker.track(self(), topic, "key1", %{})
      Presence.execute_usage_metrics(Tracker)

      assert metric_value("realtime_presence_usage_tenants", []) == 1
      assert metric_value("realtime_presence_usage_topics_by_bucket", bucket: 5) == 1

      :ok = Tracker.untrack(self(), topic, "key1")
      Presence.execute_usage_metrics(Tracker)

      assert metric_value("realtime_presence_usage_tenants", []) == 0
      assert metric_value("realtime_presence_usage_topics_by_bucket", bucket: 5) == 0
    end

    test "records a scan duration observation" do
      count_before = metric_value("realtime_presence_usage_scan_duration_milliseconds_count", []) || 0

      Presence.execute_usage_metrics(Tracker)

      assert metric_value("realtime_presence_usage_scan_duration_milliseconds_count", []) == count_before + 1
    end
  end

  defp metric_value(metric, tags \\ [implementation: "phoenix"]) do
    MetricsHelper.search(PromEx.get_metrics(MetricsTest), metric, tags)
  end
end
