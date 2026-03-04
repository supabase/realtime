defmodule Realtime.MetricsPusherTest do
  # async: false because tests interact with shared PromEx ETS state
  use Realtime.DataCase, async: false
  import ExUnit.CaptureLog

  alias Realtime.MetricsPusher
  alias Realtime.PrometheusRemoteWrite
  alias Plug.Conn

  setup {Req.Test, :verify_on_exit!}

  # Mirrors the global metrics list from MetricsControllerTest.
  # These are the series the pusher sends (Realtime.PromEx.get_metrics/0, global only).
  # Histograms will appear as "<name>_bucket" series after encoding, so we use
  # String.starts_with?/2 when checking decoded series names.
  @global_metrics [
    "beam_system_schedulers_online_info",
    "osmon_ram_usage",
    "phoenix_channel_joined_total",
    "phoenix_channel_handled_in_duration_milliseconds",
    "phoenix_socket_connected_duration_milliseconds",
    "phoenix_connections_active",
    "phoenix_connections_max",
    "realtime_global_rpc",
    "realtime_channel_global_events",
    "realtime_channel_global_presence_events",
    "realtime_channel_global_db_events",
    "realtime_channel_global_joins",
    "realtime_channel_global_input_bytes",
    "realtime_channel_global_output_bytes",
    "realtime_channel_global_error",
    "realtime_payload_size"
  ]

  # Fires every telemetry event needed to populate all event-based global metrics.
  # Mirrors fire_all_tenant_events/0 in MetricsControllerTest.
  defp fire_all_tenant_events do
    tenant_meta = %{tenant: "test_tenant"}

    :telemetry.execute([:realtime, :channel, :error], %{code: 1}, %{code: 404})
    :telemetry.execute([:realtime, :rate_counter, :channel, :events], %{sum: 5}, tenant_meta)
    :telemetry.execute([:realtime, :rate_counter, :channel, :presence_events], %{sum: 3}, tenant_meta)
    :telemetry.execute([:realtime, :rate_counter, :channel, :db_events], %{sum: 2}, tenant_meta)
    :telemetry.execute([:realtime, :rate_counter, :channel, :joins], %{sum: 1}, tenant_meta)
    :telemetry.execute([:realtime, :channel, :input_bytes], %{size: 1024}, tenant_meta)
    :telemetry.execute([:realtime, :channel, :output_bytes], %{size: 2048}, tenant_meta)

    :telemetry.execute(
      [:realtime, :tenants, :payload, :size],
      %{size: 512},
      Map.put(tenant_meta, :message_type, "broadcast")
    )

    :telemetry.execute([:realtime, :replication, :poller, :query, :stop], %{duration: 100}, tenant_meta)
    :telemetry.execute([:realtime, :tenants, :read_authorization_check], %{latency: 10}, tenant_meta)
    :telemetry.execute([:realtime, :tenants, :write_authorization_check], %{latency: 15}, tenant_meta)

    :telemetry.execute(
      [:realtime, :tenants, :broadcast_from_database],
      %{latency_committed_at: 50, latency_inserted_at: 40},
      tenant_meta
    )

    :telemetry.execute([:realtime, :tenants, :replay], %{latency: 20}, tenant_meta)
    :telemetry.execute([:realtime, :rpc], %{latency: 5}, %{success: true, mechanism: :erpc})

    :telemetry.execute([:phoenix, :channel_joined], %{}, %{
      result: :ok,
      socket: %Phoenix.Socket{transport: :websocket, endpoint: RealtimeWeb.Endpoint}
    })

    :telemetry.execute([:phoenix, :channel_handled_in], %{duration: 500_000}, %{
      socket: %Phoenix.Socket{endpoint: RealtimeWeb.Endpoint}
    })

    :telemetry.execute([:phoenix, :socket_connected], %{duration: 200_000}, %{
      result: :ok,
      endpoint: RealtimeWeb.Endpoint,
      transport: :websocket,
      serializer: Phoenix.Socket.V2.JSONSerializer
    })
  end

  defp start_and_allow_pusher(opts) do
    pid = start_supervised!({MetricsPusher, opts})
    Req.Test.allow(MetricsPusher, self(), pid)
    {:ok, pid}
  end

  describe "push sends live PromEx metrics" do
    test "events are emitted, Req sends them, mock receives and decoded content is correct" do
      fire_all_tenant_events()

      parent = self()

      Req.Test.expect(MetricsPusher, fn conn ->
        send(parent, {:push_body, Req.Test.raw_body(conn)})
        Req.Test.text(conn, "")
      end)

      {:ok, _pid} =
        start_and_allow_pusher(
          url: "http://localhost:8428/api/v1/write",
          interval: 10,
          timeout: 5000
        )

      assert_receive {:push_body, body}, 500

      {:ok, series} = PrometheusRemoteWrite.decode(body)
      series_names = MapSet.new(series, & &1[:name])

      for base_name <- @global_metrics do
        assert Enum.any?(series_names, &String.starts_with?(&1, base_name)),
               "expected a series whose name starts with #{base_name}"
      end

      bucket_series =
        Enum.filter(series, &(&1[:name] == "phoenix_channel_handled_in_duration_milliseconds_bucket"))

      assert length(bucket_series) > 0

      assert Enum.all?(bucket_series, fn s ->
               Enum.any?(s[:labels], &Map.has_key?(&1, "le"))
             end)

      assert "phoenix_channel_handled_in_duration_milliseconds_sum" in series_names
      assert "phoenix_channel_handled_in_duration_milliseconds_count" in series_names
    end
  end

  describe "extra_label query parameters" do
    test "appends default service=realtime extra_label to URL" do
      parent = self()

      Req.Test.expect(MetricsPusher, fn conn ->
        send(parent, {:query_string, conn.query_string})
        Req.Test.text(conn, "")
      end)

      {:ok, _pid} =
        start_and_allow_pusher(
          url: "http://localhost:8428/api/v1/write",
          interval: 10,
          timeout: 5000
        )

      assert_receive {:query_string, query_string}, 500
      assert query_string == "extra_label=\"service=realtime\""
    end

    test "appends custom extra_labels to URL" do
      parent = self()

      Req.Test.expect(MetricsPusher, fn conn ->
        send(parent, {:query_string, conn.query_string})
        Req.Test.text(conn, "")
      end)

      {:ok, _pid} =
        start_and_allow_pusher(
          url: "http://localhost:8428/api/v1/write",
          interval: 10,
          timeout: 5000,
          extra_labels: [env: "prod"]
        )

      assert_receive {:query_string, query_string}, 500
      assert query_string == "extra_label=\"service=realtime\"&extra_label=\"env=prod\""
    end
  end

  describe "start_link/1" do
    test "does not start when URL is missing" do
      opts = [enabled: true]
      assert :ignore = MetricsPusher.start_link(opts)
    end

    test "sends request successfully" do
      opts = [
        url: "https://example.com:8428/api/v1/write",
        user: "realtime",
        auth: "secret",
        interval: 10,
        timeout: 5000
      ]

      parent = self()

      Req.Test.expect(MetricsPusher, fn conn ->
        body = Req.Test.raw_body(conn)
        assert conn.method == "POST"
        assert is_binary(body)
        assert byte_size(body) > 0
        assert conn.scheme == :https
        assert conn.host == "example.com"
        assert conn.port == 8428
        assert conn.request_path == "/api/v1/write"
        assert Conn.get_req_header(conn, "authorization") == ["Basic #{Base.encode64("realtime:secret")}"]
        assert Conn.get_req_header(conn, "content-encoding") == ["snappy"]
        assert Conn.get_req_header(conn, "content-type") == ["application/x-protobuf"]
        assert Conn.get_req_header(conn, "x-prometheus-remote-write-version") == ["0.1.0"]

        send(parent, :req_called)
        Req.Test.text(conn, "")
      end)

      {:ok, _pid} = start_and_allow_pusher(opts)
      assert_receive :req_called, 100
    end

    test "sends request successfully without auth header" do
      opts = [
        url: "http://localhost:8428/api/v1/write",
        interval: 10,
        timeout: 5000
      ]

      parent = self()

      Req.Test.expect(MetricsPusher, fn conn ->
        body = Req.Test.raw_body(conn)
        assert is_binary(body)
        assert byte_size(body) > 0
        assert Conn.get_req_header(conn, "authorization") == []
        assert Conn.get_req_header(conn, "content-type") == ["application/x-protobuf"]
        assert Conn.get_req_header(conn, "content-encoding") == ["snappy"]

        send(parent, :req_called)
        Req.Test.text(conn, "")
      end)

      {:ok, _pid} = start_and_allow_pusher(opts)
      assert_receive :req_called, 100
    end

    test "when request receives non 2XX response" do
      opts = [
        url: "https://example.com:8428/api/v1/write",
        user: "realtime",
        auth: "secret",
        interval: 10,
        timeout: 5000
      ]

      parent = self()

      log =
        capture_log(fn ->
          Req.Test.expect(MetricsPusher, fn conn ->
            send(parent, :req_called)
            Conn.send_resp(conn, 500, "")
          end)

          {:ok, pid} = start_and_allow_pusher(opts)
          assert_receive :req_called, 100
          assert Process.alive?(pid)
          Process.sleep(100)
        end)

      assert log =~ "MetricsPusher: Failed to push metrics to"
    end

    test "when an error is raised" do
      opts = [
        url: "https://example.com:8428/api/v1/write",
        interval: 10,
        timeout: 5000
      ]

      parent = self()

      log =
        capture_log(fn ->
          Req.Test.expect(MetricsPusher, fn _conn ->
            send(parent, :req_called)
            raise RuntimeError, "unexpected error"
          end)

          {:ok, pid} = start_and_allow_pusher(opts)
          assert_receive :req_called, 100
          assert Process.alive?(pid)
          Process.sleep(100)
        end)

      assert log =~ "MetricsPusher: Exception during push: %RuntimeError{message: \"unexpected error\"}"
    end

    test "logs unexpected messages and stays alive" do
      fire_all_tenant_events()

      parent = self()

      Req.Test.expect(MetricsPusher, fn conn ->
        send(parent, :push_happened)
        Req.Test.text(conn, "")
      end)

      {:ok, pid} =
        start_and_allow_pusher(
          url: "http://localhost:8428/api/v1/write",
          interval: 10,
          timeout: 5000
        )

      assert_receive :push_happened, 500

      log =
        capture_log(fn ->
          send(pid, :unexpected_message)
          Process.sleep(50)
          assert Process.alive?(pid)
        end)

      assert log =~ "MetricsPusher received unexpected message: :unexpected_message"
    end
  end
end
