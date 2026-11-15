defmodule Realtime.PromEx.Plugins.PresenceTest do
  use Realtime.DataCase, async: false

  import ExUnit.CaptureLog

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
    messages_before = metric_value("realtime_presence_replication_received_messages") || 0

    send(@worker, ftl)
    send(@worker, ftr)
    :sys.get_state(@worker)

    assert metric_value("realtime_presence_replication_received_bytes") ==
             bytes_before + :erlang.external_size(ftl) + :erlang.external_size(ftr)

    assert metric_value("realtime_presence_replication_received_messages") == messages_before + 2
  end

  test "sizes and counts Rollcall heartbeats received via :ftl" do
    tags = [implementation: "rollcall"]
    ftl = Worker.forward_to_local("rollcall:tenant-a", {:tb, "tenant-a", :heartbeat}, Phoenix.PubSub)

    bytes_before = metric_value("realtime_presence_replication_received_bytes", tags) || 0
    messages_before = metric_value("realtime_presence_replication_received_messages", tags) || 0

    send(@worker, ftl)
    :sys.get_state(@worker)

    assert metric_value("realtime_presence_replication_received_bytes", tags) ==
             bytes_before + :erlang.external_size(ftl)

    assert metric_value("realtime_presence_replication_received_messages", tags) == messages_before + 1
  end

  test "ignores non-presence topics" do
    bytes_before = metric_value("realtime_presence_replication_received_bytes") || 0

    send(@worker, Worker.forward_to_local("realtime:some_topic", :hello, Phoenix.PubSub))
    :sys.get_state(@worker)

    assert (metric_value("realtime_presence_replication_received_bytes") || 0) == bytes_before
  end

  describe "track latency" do
    alias Realtime.Presence.Metrics
    alias Realtime.Presence.Metrics.Envelope

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

  describe "track duration" do
    alias Realtime.Presence.Metrics

    @duration "realtime_presence_track_duration"

    test "buckets each call by action, result and reason" do
      tags = [action: "update", result: "ok", reason: "none", implementation: "phoenix"]
      le_25_before = metric_value(@duration <> "_bucket", tags ++ [le: "25.0"]) || 0
      count_before = metric_value(@duration <> "_count", tags) || 0

      Metrics.measure_tracker_call(fn -> {:ok, :update, :ref} end)

      assert metric_value(@duration <> "_bucket", tags ++ [le: "25.0"]) == le_25_before + 1
      assert metric_value(@duration <> "_count", tags) == count_before + 1
    end

    test "records an exit under its reason" do
      tags = [action: "track", result: "exit", reason: "timeout", implementation: "phoenix"]
      count_before = metric_value(@duration <> "_count", tags) || 0

      catch_exit(Metrics.measure_tracker_call(fn -> exit({:timeout, {GenServer, :call, []}}) end))

      assert metric_value(@duration <> "_count", tags) == count_before + 1
    end
  end

  describe "shadow errors" do
    @shadow_error "realtime_presence_shadow_error"

    test "counts each Rollcall failure by operation and reason, with no tenant label" do
      tags = [operation: "untrack", reason: "timeout"]
      count_before = metric_value(@shadow_error, tags) || 0

      :telemetry.execute([:realtime, :presence, :shadow, :error], %{}, %{
        tenant: "shadow-error-tenant",
        operation: :untrack,
        reason: :timeout
      })

      assert metric_value(@shadow_error, tags) == count_before + 1
      assert metric_value(@shadow_error, tenant: "shadow-error-tenant") == nil
    end
  end

  describe "usage metrics" do
    alias Realtime.Presence.Usage
    alias Realtime.Tenants
    alias Realtime.Test.PresenceUsageTracker, as: Tracker

    @phoenix [implementation: "phoenix"]
    @rollcall [implementation: "rollcall"]
    @usage_event [:realtime, :presence, :usage]

    # A Rollcall instance that only this describe uses, so the entries do not depend on the trackers
    # that other tests start in `Realtime.Presence.Rollcall`.
    defmodule TestRollcall do
      @moduledoc false
      use Rollcall, transport: {Rollcall.Transport.Null, []}
    end

    setup do
      start_supervised!({Tracker, pool_size: 1})
      start_supervised!(TestRollcall)
      :ok
    end

    test "scans the given tracker and records tenant count, topic count, and every bucket" do
      {:ok, _ref} = Tracker.track(self(), Tenants.tenant_topic("tenant1", "room"), "key1", %{})
      {:ok, _ref} = Tracker.track(self(), Tenants.tenant_topic("tenant2", "room"), "key1", %{})

      assert_eventually scanned_value("realtime_presence_usage_tenants", @phoenix) == 2
      assert_eventually scanned_value("realtime_presence_usage_topics", @phoenix) == 2

      for bucket <- Usage.buckets() ++ [:infinity] do
        expected = if bucket == 1, do: 2, else: 0

        assert_eventually scanned_value(
                            "realtime_presence_usage_topics_by_bucket",
                            [bucket: bucket] ++ @phoenix
                          ) == expected
      end
    end

    test "re-scanning overwrites stale values, including buckets dropping back to zero" do
      topic = Tenants.tenant_topic("tenant1", "room")
      {:ok, _ref} = Tracker.track(self(), topic, "key1", %{})

      assert_eventually scanned_value("realtime_presence_usage_tenants", @phoenix) == 1
      assert_eventually scanned_value("realtime_presence_usage_topics_by_bucket", [bucket: 1] ++ @phoenix) == 1

      :ok = Tracker.untrack(self(), topic, "key1")

      assert_eventually scanned_value("realtime_presence_usage_tenants", @phoenix) == 0
      assert_eventually scanned_value("realtime_presence_usage_topics_by_bucket", [bucket: 1] ++ @phoenix) == 0
    end

    test "records a scan duration observation for each backend" do
      for tags <- [@phoenix, @rollcall] do
        count_before = metric_value("realtime_presence_usage_scan_duration_milliseconds_count", tags) || 0

        Presence.execute_usage_metrics(Tracker, TestRollcall)

        # Realtime.PromEx scans on its own schedule too, so the count can grow by more than one.
        assert metric_value("realtime_presence_usage_scan_duration_milliseconds_count", tags) >= count_before + 1
      end
    end

    # A Rollcall scope is a tenant and a Rollcall partition is a topic.
    test "reads the Rollcall instance and records the tenants, the topics and the buckets" do
      for n <- 1..6, do: {:ok, _ref} = Rollcall.track(TestRollcall, self(), "tenant1", "room", "key#{n}", %{})
      {:ok, _ref} = Rollcall.track(TestRollcall, self(), "tenant1", "lobby", "key1", %{})
      {:ok, _ref} = Rollcall.track(TestRollcall, self(), "tenant2", "room", "key1", %{})

      assert_eventually scanned_value("realtime_presence_usage_tenants", @rollcall) == 2
      assert_eventually scanned_value("realtime_presence_usage_topics", @rollcall) == 3
      assert_eventually scanned_value("realtime_presence_usage_topics_by_bucket", [bucket: 1] ++ @rollcall) == 2
      assert_eventually scanned_value("realtime_presence_usage_topics_by_bucket", [bucket: 10] ++ @rollcall) == 1
    end

    test "keeps the series of the two backends apart" do
      {:ok, _ref} = Tracker.track(self(), Tenants.tenant_topic("tenant1", "room"), "key1", %{})

      for tenant <- ["tenant1", "tenant2", "tenant3"] do
        {:ok, _ref} = Rollcall.track(TestRollcall, self(), tenant, "room", "key1", %{})
      end

      assert_eventually scanned_value("realtime_presence_usage_tenants", @phoenix) == 1
      assert_eventually scanned_value("realtime_presence_usage_tenants", @rollcall) == 3
    end

    # The buckets of each backend come from `Usage.buckets/0`. A backend with other bounds has no series
    # for one of these buckets.
    test "has a series for every bucket of the Usage module for each backend" do
      for tags <- [@phoenix, @rollcall], bucket <- Usage.buckets() ++ [:infinity] do
        assert_eventually scanned_value("realtime_presence_usage_topics_by_bucket", [bucket: bucket] ++ tags) != nil
      end
    end

    # These tests read the telemetry events, because the poller of Realtime.PromEx can overwrite a
    # metric value between the call and the read. The poller also emits events, with no entries, so
    # the tests match on the entry that they track.
    test "a crash in the Phoenix scan is caught, logged, and does not stop the Rollcall metrics" do
      {:ok, _ref} = Rollcall.track(TestRollcall, self(), "tenant1", "room", "key1", %{})
      attach_usage_events()

      # Not a real tracker name: PhoenixUsage.scan/1 treats an unstarted tracker as empty rather than
      # crashing, so this forces a genuine crash (:ets.whereis/1 rejects a non-atom) to exercise the
      # Task-level safety net itself, regardless of what trips it.
      log = capture_log(fn -> assert Presence.execute_usage_metrics("not_an_atom_tracker", TestRollcall) end)

      assert log =~ "PresenceUsageScanCrashed"
      assert log =~ "phoenix"
      assert_receive {:usage, %{tenant_count: 1}, %{implementation: :rollcall}}
    end

    test "a crash in the Rollcall read is caught, logged, and does not stop the Phoenix metrics" do
      {:ok, _ref} = Tracker.track(self(), Tenants.tenant_topic("tenant1", "room"), "key1", %{})
      attach_usage_events()

      log = capture_log(fn -> assert Presence.execute_usage_metrics(Tracker, "not_an_atom_rollcall") end)

      assert log =~ "PresenceUsageScanCrashed"
      assert log =~ "rollcall"
      assert_receive {:usage, %{tenant_count: 1}, %{implementation: :phoenix}}
    end

    def handle_usage_event(_event, measurements, metadata, pid), do: send(pid, {:usage, measurements, metadata})

    defp attach_usage_events do
      id = {__MODULE__, make_ref()}
      :telemetry.attach(id, @usage_event, &__MODULE__.handle_usage_event/4, self())
      on_exit(fn -> :telemetry.detach(id) end)
    end

    # The usage values are last-value metrics. Realtime.PromEx also scans every 5 seconds, and its
    # scan of the empty RealtimeWeb.Presence and of the empty Rollcall instance can land between a
    # scan and a read. Scan again on every attempt so that such a read is retried instead of failing
    # the test.
    defp scanned_value(metric, tags) do
      Presence.execute_usage_metrics(Tracker, TestRollcall)
      metric_value(metric, tags)
    end
  end

  describe "join latency" do
    alias Realtime.Presence.Metrics

    @join_latency "realtime_presence_join_latency"

    test "buckets each observation by tracker state" do
      tags = [state: "warm", implementation: "phoenix"]

      le_25_before = metric_value(@join_latency <> "_bucket", tags ++ [le: "25.0"]) || 0
      count_before = metric_value(@join_latency <> "_count", tags) || 0

      # 20ms and 400ms: one lands under le="25", both count.
      Metrics.record_join(started_at_ms_ago(20), "t", :warm)
      Metrics.record_join(started_at_ms_ago(400), "t", :warm)

      assert metric_value(@join_latency <> "_bucket", tags ++ [le: "25.0"]) == le_25_before + 1
      assert metric_value(@join_latency <> "_count", tags) == count_before + 2
    end

    test "tags cold as a separate series from warm" do
      warm_tags = [state: "warm", implementation: "phoenix"]
      cold_tags = [state: "cold", implementation: "phoenix"]

      warm_count_before = metric_value(@join_latency <> "_count", warm_tags) || 0
      cold_count_before = metric_value(@join_latency <> "_count", cold_tags) || 0

      Metrics.record_join(started_at_ms_ago(5), "t", :cold)

      assert metric_value(@join_latency <> "_count", cold_tags) == cold_count_before + 1
      assert (metric_value(@join_latency <> "_count", warm_tags) || 0) == warm_count_before
    end

    defp started_at_ms_ago(ms), do: System.monotonic_time() - System.convert_time_unit(ms, :millisecond, :native)
  end

  defp metric_value(metric, tags \\ [implementation: "phoenix"]) do
    MetricsHelper.search(PromEx.get_metrics(MetricsTest), metric, tags)
  end
end
