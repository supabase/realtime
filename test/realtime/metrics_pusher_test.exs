defmodule Realtime.MetricsPusherTest do
  use Realtime.DataCase, async: true
  use Mimic
  import ExUnit.CaptureLog

  alias Plug.Conn
  alias Realtime.MetricsPusher

  setup {Req.Test, :verify_on_exit!}

  describe "start_link/1" do
    test "does not start when URL is missing" do
      opts = [enabled: true]
      assert :ignore = MetricsPusher.start_link(opts)
    end

    test "does not start when the URL list is empty" do
      assert :ignore = MetricsPusher.start_link(urls: [])
    end

    test "sends request successfully" do
      opts = [
        urls: ["https://example.com:8428/api/v1/import/prometheus"],
        user: "realtime",
        auth: "hunter2",
        compress: true,
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
      assert_receive {:req_called, body1}, 1000
      assert_receive {:req_called, body2}, 1000

      global_metric = ~r/beam_stats_run_queue_count/
      tenant_metric = ~r/realtime_channel_input_bytes/

      # One request must contain a global-only metric, the other a tenant-only metric.
      assert (Regex.match?(global_metric, body1) and Regex.match?(tenant_metric, body2)) or
               (Regex.match?(global_metric, body2) and Regex.match?(tenant_metric, body1))
    end

    test "sends request successfully without auth header" do
      opts = [
        urls: ["http://localhost:8428/api/v1/import/prometheus"],
        compress: true,
        timeout: 5000
      ]

      parent = self()

      Req.Test.expect(MetricsPusher, 2, fn conn ->
        assert Conn.get_req_header(conn, "authorization") == []

        send(parent, :req_called)
        Req.Test.text(conn, "")
      end)

      {:ok, _pid} = start_and_allow_pusher(opts)
      assert_receive :req_called, 1000
      assert_receive :req_called, 1000
    end

    test "sends request body untouched when compress=false" do
      opts = [
        urls: ["http://localhost:8428/api/v1/import/prometheus"],
        user: "hunter2",
        auth: "realtime",
        compress: false,
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
      assert_receive :req_called, 1000
      assert_receive :req_called, 1000
    end

    test "when request receives non 2XX response" do
      opts = [
        urls: ["https://example.com:8428/api/v1/import/prometheus"],
        auth: "hunter2",
        compress: true,
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
          assert_receive :req_called, 1000
          assert_receive :req_called, 1000
          assert Process.alive?(pid)
          # Wait enough for the log to be captured
          :sys.get_state(pid)
        end)

      assert log =~ "MetricsPusher: Failed to push"
      assert log =~ "metrics to"
      assert log =~ "error_code=MetricsPusherFailed"
    end

    test "when an error is raised" do
      opts = [
        urls: ["https://example.com:8428/api/v1/import/prometheus"],
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
          assert_receive :req_called, 1000
          assert_receive :req_called, 1000
          assert Process.alive?(pid)
          # Wait enough for the log to be captured
          :sys.get_state(pid)
        end)

      assert log =~ "MetricsPusher: Exception during"
      assert log =~ "push: %RuntimeError{message: \"unexpected error\"}"
      assert log =~ "error_code=MetricsPusherException"
    end

    test "appends extra_label query params to URL" do
      opts = [
        urls: ["http://localhost:8428/api/v1/import/prometheus"],
        compress: false,
        timeout: 5000,
        extra_labels: [{"region", "us-east-1"}, {"env", "prod"}]
      ]

      parent = self()

      Req.Test.expect(MetricsPusher, 2, fn conn ->
        send(parent, {:req_called, conn.query_string})
        Req.Test.text(conn, "")
      end)

      {:ok, _pid} = start_and_allow_pusher(opts)
      assert_receive {:req_called, query_string}, 1000
      assert_receive {:req_called, _}, 1000

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
          urls: ["http://localhost:8428/api/v1/import/prometheus"],
          timeout: 5000
        )

      assert_receive :push_happened, 1000
      assert_receive :push_happened, 1000

      log =
        capture_log(fn ->
          send(pid, :unexpected_message)
          # calling :sys.get_state/1 ensures that the above message has been processed
          # as this is a sync call answered in mailbox order
          :sys.get_state(pid)
        end)

      assert log =~ "MetricsPusher received unexpected message: :unexpected_message"
      assert Process.alive?(pid)
    end
  end

  @global_metric ~r/beam_stats_run_queue_count/
  @tenant_metric ~r/realtime_channel_input_bytes/

  describe "scope" do
    test ":global pushes only global metrics" do
      emit_tenant_metric()
      parent = self()

      Req.Test.expect(MetricsPusher, 1, fn conn ->
        send(parent, {:req_called, Req.Test.raw_body(conn)})
        Req.Test.text(conn, "")
      end)

      {:ok, _pid} =
        start_and_allow_pusher(
          scope: :global,
          urls: ["http://localhost:8428/api/v1/import/prometheus"],
          compress: false
        )

      assert_receive {:req_called, body}, 1000
      assert body =~ @global_metric
      refute body =~ @tenant_metric
      refute_receive {:req_called, _}, 100
    end

    test ":tenant pushes only tenant metrics" do
      emit_tenant_metric()
      parent = self()

      Req.Test.expect(MetricsPusher, 1, fn conn ->
        send(parent, {:req_called, Req.Test.raw_body(conn)})
        Req.Test.text(conn, "")
      end)

      {:ok, _pid} =
        start_and_allow_pusher(
          scope: :tenant,
          urls: ["http://localhost:8429/api/v1/import/prometheus"],
          compress: false
        )

      assert_receive {:req_called, body}, 1000
      assert body =~ @tenant_metric
      refute body =~ @global_metric
      refute_receive {:req_called, _}, 100
    end

    test "global and tenant pushers run side by side, each sending to its own URL" do
      emit_tenant_metric()
      parent = self()

      Req.Test.expect(MetricsPusher, 2, fn conn ->
        send(parent, {:req_called, conn.host, Req.Test.raw_body(conn)})
        Req.Test.text(conn, "")
      end)

      {:ok, _} =
        start_and_allow_pusher(
          scope: :global,
          name: MetricsPusher.Global,
          urls: ["http://global.example.com/api/v1/import/prometheus"],
          compress: false
        )

      {:ok, _} =
        start_and_allow_pusher(
          scope: :tenant,
          name: MetricsPusher.Tenant,
          urls: ["http://tenant.example.com/api/v1/import/prometheus"],
          compress: false
        )

      bodies =
        for _ <- 1..2, into: %{} do
          assert_receive {:req_called, host, body}, 1000
          {host, body}
        end

      assert bodies["global.example.com"] =~ @global_metric
      refute bodies["global.example.com"] =~ @tenant_metric
      assert bodies["tenant.example.com"] =~ @tenant_metric
      refute bodies["tenant.example.com"] =~ @global_metric
    end
  end

  describe "multiple URLs" do
    test "pushes both metric sets to every URL" do
      emit_tenant_metric()
      parent = self()

      # 2 metric sets x 2 URLs
      Req.Test.expect(MetricsPusher, 4, fn conn ->
        send(parent, {:req_called, conn.host, Req.Test.raw_body(conn)})
        Req.Test.text(conn, "")
      end)

      {:ok, _pid} =
        start_and_allow_pusher(
          urls: [
            "http://regional.example.com/api/v1/import/prometheus",
            "http://central.example.com/api/v1/import/prometheus"
          ],
          compress: false
        )

      bodies_by_host =
        for _ <- 1..4, reduce: %{} do
          acc ->
            assert_receive {:req_called, host, body}, 1000
            Map.update(acc, host, [body], &[body | &1])
        end

      for host <- ["regional.example.com", "central.example.com"] do
        bodies = Map.fetch!(bodies_by_host, host)
        assert length(bodies) == 2
        assert Enum.any?(bodies, &(&1 =~ @global_metric))
        assert Enum.any?(bodies, &(&1 =~ @tenant_metric))
      end
    end

    test "sends the same auth and extra labels to every URL" do
      parent = self()

      Req.Test.expect(MetricsPusher, 4, fn conn ->
        send(parent, {:req_called, conn.host, Conn.get_req_header(conn, "authorization"), conn.query_string})
        Req.Test.text(conn, "")
      end)

      {:ok, _pid} =
        start_and_allow_pusher(
          urls: [
            "http://regional.example.com/api/v1/import/prometheus",
            "http://central.example.com/api/v1/import/prometheus"
          ],
          user: "realtime",
          auth: "hunter2",
          compress: false,
          extra_labels: [{"service", "realtime"}]
        )

      hosts =
        for _ <- 1..4 do
          assert_receive {:req_called, host, auth_header, query_string}, 1000
          assert auth_header == ["Basic #{Base.encode64("realtime:hunter2")}"]
          assert "extra_label=service=realtime" in decode_params(query_string)
          host
        end

      assert Enum.frequencies(hosts) == %{"regional.example.com" => 2, "central.example.com" => 2}
    end

    test "a failing URL does not stop pushes to the other URLs" do
      parent = self()

      log =
        capture_log(fn ->
          Req.Test.expect(MetricsPusher, 4, fn conn ->
            send(parent, {:req_called, conn.host})

            case conn.host do
              "broken.example.com" -> Conn.send_resp(conn, 500, "")
              _ -> Req.Test.text(conn, "")
            end
          end)

          {:ok, pid} =
            start_and_allow_pusher(
              urls: [
                "http://broken.example.com/api/v1/import/prometheus",
                "http://healthy.example.com/api/v1/import/prometheus"
              ],
              compress: false
            )

          hosts =
            for _ <- 1..4 do
              assert_receive {:req_called, host}, 1000
              host
            end

          assert Enum.frequencies(hosts) == %{"broken.example.com" => 2, "healthy.example.com" => 2}
          assert Process.alive?(pid)
          :sys.get_state(pid)
        end)

      assert log =~ "metrics to http://broken.example.com/api/v1/import/prometheus"
      refute log =~ "metrics to http://healthy.example.com"
    end

    test "an exception while fetching one metric set still pushes the other set to every URL" do
      parent = self()

      Req.Test.expect(MetricsPusher, 2, fn conn ->
        send(parent, {:req_called, conn.host, Req.Test.raw_body(conn)})
        Req.Test.text(conn, "")
      end)

      stub(Realtime.TenantPromEx, :get_metrics, fn -> raise RuntimeError, "boom" end)

      log =
        capture_log(fn ->
          opts = [
            urls: [
              "http://regional.example.com/api/v1/import/prometheus",
              "http://central.example.com/api/v1/import/prometheus"
            ],
            compress: false,
            interval: :timer.minutes(5)
          ]

          pid = start_supervised!(Supervisor.child_spec({MetricsPusher, opts}, id: MetricsPusher))
          Req.Test.allow(MetricsPusher, self(), pid)
          allow(Realtime.TenantPromEx, self(), pid)
          send(pid, :push)

          for _ <- 1..2 do
            assert_receive {:req_called, _host, body}, 1000
            assert body =~ @global_metric
          end

          assert Process.alive?(pid)
          :sys.get_state(pid)
        end)

      assert log =~ "MetricsPusher: Exception fetching tenant metrics"
      assert log =~ "error_code=MetricsPusherException"
    end

    test ":tenant scope pushes tenant metrics to every URL" do
      emit_tenant_metric()
      parent = self()

      Req.Test.expect(MetricsPusher, 2, fn conn ->
        send(parent, {:req_called, conn.host, Req.Test.raw_body(conn)})
        Req.Test.text(conn, "")
      end)

      {:ok, _pid} =
        start_and_allow_pusher(
          scope: :tenant,
          urls: [
            "http://regional.example.com/api/v1/import/prometheus",
            "http://central.example.com/api/v1/import/prometheus"
          ],
          compress: false
        )

      bodies =
        for _ <- 1..2, into: %{} do
          assert_receive {:req_called, host, body}, 1000
          {host, body}
        end

      for host <- ["regional.example.com", "central.example.com"] do
        assert bodies[host] =~ @tenant_metric
        refute bodies[host] =~ @global_metric
      end
    end
  end

  describe "child_specs/1" do
    test "starts nothing when both pushers are disabled" do
      assert MetricsPusher.child_specs(metrics_enabled: false, tenant_enabled: false) == []
    end

    test "starts one pusher for both metric sets when only the main pusher is enabled" do
      specs = MetricsPusher.child_specs(metrics_enabled: true, tenant_enabled: false)
      assert scopes(specs) == [{MetricsPusher, :all}]
    end

    test "splits global and tenant pushers when both are enabled" do
      specs = MetricsPusher.child_specs(metrics_enabled: true, tenant_enabled: true)
      assert scopes(specs) == [{MetricsPusher.Global, :global}, {MetricsPusher.Tenant, :tenant}]
    end

    test "starts nothing when only the tenant pusher is enabled" do
      specs = MetricsPusher.child_specs(metrics_enabled: false, tenant_enabled: true)

      # The tenant pusher is only started when the main pusher is also enabled,
      # so this should return an empty list.
      assert scopes(specs) == []
    end
  end

  # Helper function to start MetricsPusher and allow it to use Req.Test
  defp start_and_allow_pusher(opts) do
    opts = Keyword.put(opts, :interval, :timer.minutes(5))
    id = Keyword.get(opts, :name, MetricsPusher)
    pid = start_supervised!(Supervisor.child_spec({MetricsPusher, opts}, id: id))
    Req.Test.allow(MetricsPusher, self(), pid)
    send(pid, :push)
    {:ok, pid}
  end

  defp scopes(child_specs) do
    Enum.map(child_specs, fn %{id: id, start: {_, _, [opts]}} -> {id, opts[:scope]} end)
  end

  defp decode_params(query_string) do
    query_string |> String.split("&") |> Enum.map(&URI.decode_www_form/1)
  end

  defp emit_tenant_metric do
    :telemetry.execute([:realtime, :channel, :input_bytes], %{size: 1024}, %{tenant: "test_tenant"})
  end
end
