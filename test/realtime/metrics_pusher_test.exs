defmodule Realtime.MetricsPusherTest do
  use Realtime.DataCase, async: true
  import ExUnit.CaptureLog

  alias Realtime.MetricsPusher
  alias Plug.Conn

  setup {Req.Test, :verify_on_exit!}

  # Helper function to start MetricsPusher and allow it to use Req.Test
  defp start_and_allow_pusher(opts) do
    pid = start_supervised!({MetricsPusher, opts})
    Req.Test.allow(MetricsPusher, self(), pid)
    {:ok, pid}
  end

  describe "start_link/1" do
    test "does not start when URL is missing" do
      opts = [enabled: true]
      assert :ignore = MetricsPusher.start_link(opts)
    end

    test "sends request successfully" do
      opts = [
        url: "https://example.com:8428/api/v1/import/prometheus",
        user: "realtime",
        auth: "hunter2",
        compress: true,
        interval: 10,
        timeout: 5000
      ]

      :telemetry.execute([:realtime, :channel, :input_bytes], %{size: 1024}, %{tenant: "test_tenant"})

      parent = self()

      # Expect 2 requests: one for global metrics, one for tenant metrics
      Req.Test.expect(MetricsPusher, 2, fn conn ->
        assert conn.method == "POST"
        assert conn.scheme == :https
        assert conn.host == "example.com"
        assert conn.port == 8428
        assert conn.request_path == "/api/v1/import/prometheus"
        assert Conn.get_req_header(conn, "authorization") == ["Basic #{Base.encode64("realtime:hunter2")}"]
        assert Conn.get_req_header(conn, "content-encoding") == ["gzip"]
        assert Conn.get_req_header(conn, "content-type") == ["text/plain"]

        body = Req.Test.raw_body(conn)
        decompressed_body = :zlib.gunzip(body)

        # Collect decompressed bodies so we can assert that one has global metrics
        # and the other has tenant metrics.
        send(parent, {:req_called, decompressed_body})
        Req.Test.text(conn, "")
      end)

      {:ok, _pid} = start_and_allow_pusher(opts)

      # Receive both request bodies
      assert_receive {:req_called, body1}, 300
      assert_receive {:req_called, body2}, 300

      global_metric = ~r/beam_stats_run_queue_count/
      tenant_metric = ~r/realtime_channel_input_bytes/

      # One request must contain a global-only metric, the other a tenant-only metric.
      assert (Regex.match?(global_metric, body1) and Regex.match?(tenant_metric, body2)) or
               (Regex.match?(global_metric, body2) and Regex.match?(tenant_metric, body1))
    end

    test "sends request successfully without auth header" do
      opts = [
        url: "http://localhost:8428/api/v1/import/prometheus",
        compress: true,
        interval: 10,
        timeout: 5000
      ]

      parent = self()

      Req.Test.expect(MetricsPusher, 2, fn conn ->
        assert Conn.get_req_header(conn, "authorization") == []

        send(parent, :req_called)
        Req.Test.text(conn, "")
      end)

      {:ok, _pid} = start_and_allow_pusher(opts)
      assert_receive :req_called, 300
      assert_receive :req_called, 300
    end

    test "sends request body untouched when compress=false" do
      opts = [
        url: "http://localhost:8428/api/v1/import/prometheus",
        user: "hunter2",
        auth: "realtime",
        compress: false,
        interval: 10,
        timeout: 5000
      ]

      parent = self()

      Req.Test.expect(MetricsPusher, 2, fn conn ->
        assert Conn.get_req_header(conn, "content-encoding") == []
        assert Conn.get_req_header(conn, "content-type") == ["text/plain"]

        send(parent, :req_called)
        Req.Test.text(conn, "")
      end)

      {:ok, _pid} = start_and_allow_pusher(opts)
      assert_receive :req_called, 300
      assert_receive :req_called, 300
    end

    test "when request receives non 2XX response" do
      opts = [
        url: "https://example.com:8428/api/v1/import/prometheus",
        auth: "hunter2",
        compress: true,
        interval: 10,
        timeout: 5000
      ]

      parent = self()

      log =
        capture_log(fn ->
          Req.Test.expect(MetricsPusher, 2, fn conn ->
            send(parent, :req_called)
            Conn.send_resp(conn, 500, "")
          end)

          {:ok, pid} = start_and_allow_pusher(opts)
          assert_receive :req_called, 300
          assert_receive :req_called, 300
          assert Process.alive?(pid)
          # Wait enough for the log to be captured
          Process.sleep(100)
        end)

      assert log =~ "MetricsPusher: Failed to push"
      assert log =~ "metrics to"
    end

    test "when an error is raised" do
      opts = [
        url: "https://example.com:8428/api/v1/import/prometheus",
        interval: 10,
        timeout: 5000
      ]

      parent = self()

      log =
        capture_log(fn ->
          Req.Test.expect(MetricsPusher, 2, fn _conn ->
            send(parent, :req_called)
            raise RuntimeError, "unexpected error"
          end)

          {:ok, pid} = start_and_allow_pusher(opts)
          assert_receive :req_called, 300
          assert_receive :req_called, 300
          assert Process.alive?(pid)
          # Wait enough for the log to be captured
          Process.sleep(100)
        end)

      assert log =~ "MetricsPusher: Exception during"
      assert log =~ "push: %RuntimeError{message: \"unexpected error\"}"
    end

    test "appends extra_label query params to URL" do
      opts = [
        url: "http://localhost:8428/api/v1/import/prometheus",
        compress: false,
        interval: 10,
        timeout: 5000,
        extra_labels: [{"region", "us-east-1"}, {"env", "prod"}]
      ]

      parent = self()

      Req.Test.expect(MetricsPusher, 2, fn conn ->
        send(parent, {:req_called, conn.query_string})
        Req.Test.text(conn, "")
      end)

      {:ok, _pid} = start_and_allow_pusher(opts)
      assert_receive {:req_called, query_string}, 300
      assert_receive {:req_called, _}, 300

      decoded_params = query_string |> String.split("&") |> Enum.map(&URI.decode_www_form/1)
      assert "extra_label=region=us-east-1" in decoded_params
      assert "extra_label=env=prod" in decoded_params
    end

    test "logs unexpected messages and stays alive" do
      parent = self()

      Req.Test.expect(MetricsPusher, 2, fn conn ->
        send(parent, :push_happened)
        Req.Test.text(conn, "")
      end)

      {:ok, pid} =
        start_and_allow_pusher(
          url: "http://localhost:8428/api/v1/import/prometheus",
          interval: 10,
          timeout: 5000
        )

      assert_receive :push_happened, 500
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
