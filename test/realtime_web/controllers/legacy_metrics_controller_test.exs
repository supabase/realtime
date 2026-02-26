defmodule RealtimeWeb.LegacyMetricsControllerTest do
  use RealtimeWeb.ConnCase, async: false
  alias Realtime.GenRpc

  import ExUnit.CaptureLog
  use Mimic

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

  @tenant_metrics [
    "realtime_channel_events",
    "realtime_channel_presence_events",
    "realtime_channel_db_events",
    "realtime_channel_joins",
    "realtime_channel_input_bytes",
    "realtime_channel_output_bytes",
    "realtime_tenants_payload_size",
    "realtime_replication_poller_query_duration",
    "realtime_tenants_read_authorization_check",
    "realtime_tenants_write_authorization_check",
    "realtime_tenants_broadcast_from_database_latency_committed_at",
    "realtime_tenants_broadcast_from_database_latency_inserted_at",
    "realtime_tenants_replay",
    "realtime_channel_error"
  ]

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

  setup_all do
    metrics_tags = %{
      region: "ap-southeast-2",
      host: "anothernode@something.com",
      id: "someid"
    }

    {:ok, _} =
      Clustered.start(nil,
        extra_config: [{:realtime, :region, "ap-southeast-2"}, {:realtime, :metrics_tags, metrics_tags}]
      )

    :ok
  end

  setup %{conn: conn} do
    previous = Application.get_env(:realtime, :metrics_separation_enabled)
    Application.put_env(:realtime, :metrics_separation_enabled, false)
    on_exit(fn -> Application.put_env(:realtime, :metrics_separation_enabled, previous) end)

    jwt_secret = Application.fetch_env!(:realtime, :metrics_jwt_secret)
    token = generate_jwt_token(jwt_secret, %{})

    {:ok, conn: put_req_header(conn, "authorization", "Bearer #{token}")}
  end

  describe "GET /metrics (legacy combined)" do
    test "contains both global and tenant metrics", %{conn: conn} do
      fire_all_tenant_events()

      response =
        conn
        |> get(~p"/metrics")
        |> text_response(200)

      for metric <- @global_metrics do
        assert response =~ "# HELP #{metric}", "expected global metric #{metric} to be present"
      end

      for metric <- @tenant_metrics do
        assert response =~ "# HELP #{metric}", "expected tenant metric #{metric} to be present"
      end
    end

    test "returns 200 and logs error on node timeout", %{conn: conn} do
      Mimic.stub(GenRpc, :call, fn node, mod, func, args, opts ->
        if node != node() do
          {:error, :rpc_error, :timeout}
        else
          call_original(GenRpc, :call, [node, mod, func, args, opts])
        end
      end)

      log =
        capture_log(fn ->
          response =
            conn
            |> get(~p"/metrics")
            |> text_response(200)

          refute response =~ "region=\"ap-southeast-2\""
          assert response =~ "region=\"us-east-1\""
        end)

      assert log =~ "Cannot fetch metrics from the node"
    end

    test "returns 403 when authorization header is missing", %{conn: conn} do
      conn
      |> delete_req_header("authorization")
      |> get(~p"/metrics")
      |> response(403)
    end

    test "returns 403 when authorization header is wrong", %{conn: conn} do
      conn
      |> put_req_header("authorization", "Bearer #{generate_jwt_token("bad_secret", %{})}")
      |> get(~p"/metrics")
      |> response(403)
    end
  end

  describe "GET /metrics/:region (legacy combined)" do
    test "contains both global and tenant metrics for region", %{conn: conn} do
      fire_all_tenant_events()

      response =
        conn
        |> get(~p"/metrics/us-east-1")
        |> text_response(200)

      for metric <- @global_metrics do
        assert response =~ "# HELP #{metric}", "expected global metric #{metric} to be present"
      end

      for metric <- @tenant_metrics do
        assert response =~ "# HELP #{metric}", "expected tenant metric #{metric} to be present"
      end
    end

    test "returns 200 and logs error on node timeout", %{conn: conn} do
      Mimic.stub(GenRpc, :call, fn _node, _mod, _func, _args, _opts ->
        {:error, :rpc_error, :timeout}
      end)

      log =
        capture_log(fn ->
          assert conn |> get(~p"/metrics/ap-southeast-2") |> text_response(200) == ""
        end)

      assert log =~ "Cannot fetch metrics from the node"
    end

    test "returns 403 when authorization header is missing", %{conn: conn} do
      conn
      |> delete_req_header("authorization")
      |> get(~p"/metrics/ap-southeast-2")
      |> response(403)
    end

    test "returns 403 when authorization header is wrong", %{conn: conn} do
      conn
      |> put_req_header("authorization", "Bearer #{generate_jwt_token("bad_secret", %{})}")
      |> get(~p"/metrics/ap-southeast-2")
      |> response(403)
    end
  end

  describe "GET /tenant-metrics (legacy mode)" do
    test "returns 404", %{conn: conn} do
      conn
      |> get(~p"/tenant-metrics")
      |> response(404)
    end
  end

  describe "GET /tenant-metrics/:region (legacy mode)" do
    test "returns 404", %{conn: conn} do
      conn
      |> get(~p"/tenant-metrics/ap-southeast-2")
      |> response(404)
    end
  end
end
