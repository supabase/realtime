defmodule RealtimeWeb.MetricsControllerTest do
  # Usage of Clustered
  use RealtimeWeb.ConnCase, async: false
  alias Realtime.GenRpc

  import ExUnit.CaptureLog
  use Mimic

  setup :set_mimic_from_context

  # {help_metric, value_metric, tags}
  # help_metric: base name checked against "# HELP <name>" in the response
  # value_metric: metric name passed to MetricsHelper.search (distributions use _count suffix); nil = skip value check
  # tags: label filters for the value assertion; nil = any labels
  @global_metrics [
    # BEAM / OS — polling metrics, no fired events, skip value check
    {"beam_system_schedulers_online_info", nil, nil},
    {"osmon_ram_usage", nil, nil},
    # Phoenix counters — populated by fire_all_tenant_events/0
    {"phoenix_channel_joined_total", "phoenix_channel_joined_total",
     [result: "ok", transport: "websocket", endpoint: "RealtimeWeb.Endpoint"]},
    # Phoenix distributions — value lives under _count suffix
    {"phoenix_channel_handled_in_duration_milliseconds", "phoenix_channel_handled_in_duration_milliseconds_count",
     [endpoint: "RealtimeWeb.Endpoint"]},
    {"phoenix_socket_connected_duration_milliseconds", "phoenix_socket_connected_duration_milliseconds_count",
     [
       result: "ok",
       transport: "websocket",
       endpoint: "RealtimeWeb.Endpoint",
       serializer: "Phoenix.Socket.V2.JSONSerializer"
     ]},
    # Phoenix connections — polling metrics, skip value check
    {"phoenix_connections_active", nil, nil},
    {"phoenix_connections_max", nil, nil},
    # GenRPC call latency — distribution, value lives under _count suffix
    {"realtime_global_rpc", "realtime_global_rpc_count", [success: "true", mechanism: "erpc"]},
    # Global aggregates — sums with no explicit tags (framework adds global labels)
    {"realtime_channel_global_events", "realtime_channel_global_events", nil},
    {"realtime_channel_global_presence_events", "realtime_channel_global_presence_events", nil},
    {"realtime_channel_global_db_events", "realtime_channel_global_db_events", nil},
    {"realtime_channel_global_joins", "realtime_channel_global_joins", nil},
    {"realtime_channel_global_input_bytes", "realtime_channel_global_input_bytes", nil},
    {"realtime_channel_global_output_bytes", "realtime_channel_global_output_bytes", nil},
    {"realtime_channel_global_error", "realtime_channel_global_error", [code: "TestError"]},
    # Global payload size — distribution, value lives under _count suffix
    {"realtime_payload_size", "realtime_payload_size_count", [message_type: "broadcast"]}
  ]

  @tenant_metrics [
    # Per-tenant channel events — sums with tenant tag
    {"realtime_channel_events", "realtime_channel_events", [tenant: "test_tenant"]},
    {"realtime_channel_presence_events", "realtime_channel_presence_events", [tenant: "test_tenant"]},
    {"realtime_channel_db_events", "realtime_channel_db_events", [tenant: "test_tenant"]},
    {"realtime_channel_joins", "realtime_channel_joins", [tenant: "test_tenant"]},
    {"realtime_channel_input_bytes", "realtime_channel_input_bytes", [tenant: "test_tenant"]},
    {"realtime_channel_output_bytes", "realtime_channel_output_bytes", [tenant: "test_tenant"]},
    # Per-tenant distributions — value lives under _count suffix
    {"realtime_tenants_payload_size", "realtime_tenants_payload_size_count",
     [tenant: "test_tenant", message_type: "broadcast"]},
    {"realtime_replication_poller_query_duration", "realtime_replication_poller_query_duration_count",
     [tenant: "test_tenant"]},
    {"realtime_tenants_read_authorization_check", "realtime_tenants_read_authorization_check_count",
     [tenant: "test_tenant"]},
    {"realtime_tenants_write_authorization_check", "realtime_tenants_write_authorization_check_count",
     [tenant: "test_tenant"]},
    {"realtime_tenants_broadcast_from_database_latency_committed_at",
     "realtime_tenants_broadcast_from_database_latency_committed_at_count", [tenant: "test_tenant"]},
    {"realtime_tenants_broadcast_from_database_latency_inserted_at",
     "realtime_tenants_broadcast_from_database_latency_inserted_at_count", [tenant: "test_tenant"]},
    {"realtime_tenants_replay", "realtime_tenants_replay_count", [tenant: "test_tenant"]},
    # Per-tenant errors
    {"realtime_channel_error", "realtime_channel_error", [code: "TestError", tenant: "test_tenant"]}
  ]

  # Fires every telemetry event needed to populate all event-based metrics
  defp fire_all_tenant_events do
    tenant_meta = %{tenant: "test_tenant"}

    :telemetry.execute([:realtime, :channel, :error], %{count: 1}, %{code: "TestError", tenant: "test_tenant"})
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
    jwt_secret = Application.fetch_env!(:realtime, :metrics_jwt_secret)
    token = generate_jwt_token(jwt_secret, %{})

    {:ok, conn: put_req_header(conn, "authorization", "Bearer #{token}")}
  end

  describe "GET /metrics" do
    test "contains both global and tenant metrics with values", %{conn: conn} do
      fire_all_tenant_events()

      response =
        conn
        |> get(~p"/metrics")
        |> text_response(200)

      for {help_metric, value_metric, tags} <- @global_metrics do
        assert response =~ "# HELP #{help_metric}", "expected global metric #{help_metric} to be present"

        if value_metric do
          assert MetricsHelper.search(response, value_metric, tags) > 0,
                 "expected global metric #{value_metric} to have a value with tags #{inspect(tags)}"
        end
      end

      for {help_metric, value_metric, tags} <- @tenant_metrics do
        assert response =~ "# HELP #{help_metric}", "expected tenant metric #{help_metric} to be present"

        if value_metric do
          assert MetricsHelper.search(response, value_metric, tags) > 0,
                 "expected tenant metric #{value_metric} to have a value with tags #{inspect(tags)}"
        end
      end
    end

    test "includes region tags from all nodes", %{conn: conn} do
      response =
        conn
        |> get(~p"/metrics")
        |> text_response(200)

      assert response =~ "region=\"ap-southeast-2\""
      assert response =~ "region=\"us-east-1\""
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

  describe "GET /metrics/:region" do
    test "returns both global and tenant metrics with values scoped to the given region", %{conn: conn} do
      fire_all_tenant_events()

      response =
        conn
        |> get(~p"/metrics/us-east-1")
        |> text_response(200)

      for {help_metric, value_metric, tags} <- @global_metrics do
        assert response =~ "# HELP #{help_metric}", "expected global metric #{help_metric} to be present"

        if value_metric do
          assert MetricsHelper.search(response, value_metric, tags) > 0,
                 "expected global metric #{value_metric} to have a value with tags #{inspect(tags)}"
        end
      end

      for {help_metric, value_metric, tags} <- @tenant_metrics do
        assert response =~ "# HELP #{help_metric}", "expected tenant metric #{help_metric} to be present"

        if value_metric do
          assert MetricsHelper.search(response, value_metric, tags) > 0,
                 "expected tenant metric #{value_metric} to have a value with tags #{inspect(tags)}"
        end
      end
    end

    test "filters metrics to the given region", %{conn: conn} do
      response =
        conn
        |> get(~p"/metrics/ap-southeast-2")
        |> text_response(200)

      assert response =~ "region=\"ap-southeast-2\""
      refute response =~ "region=\"us-east-1\""
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


  describe "JWKS authentication" do
    @es256_jwks %{
      "keys" => [
        %{
          "kty" => "EC",
          "x" => "iX_niXPSL2nW-9IyCELzyceAtuE3B98pWML5tQGACD4",
          "y" => "kT02DoLhXx6gtpkbrN8XwQ2wtzE6cDBaqlWgVXIeqV0",
          "crv" => "P-256",
          "d" => "FBVYnsYA2C3FTggEwV8kCRMo4FLl220_cWY2RdXyb_8",
          "kid" => "key-id-1"
        }
      ]
    }

    # Pre-generated ES256 token signed with the above private key
    @es256_token "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6ImtleS1pZC0xIn0.eyJpYXQiOjE3ODg2NDg1NDQsImV4cCI6MTc4ODY1MjE0NCwicm9sZSI6ImF1dGhlbnRpY2F0ZWQiLCJzdWIiOiJ1c2VyLWlkIn0.kyM903QbEfaQVali0h6p00Q2TMUspizZUerwJ3zvjcg2C1qjmSEO0s728SldHvHKtXrUg9iER8T1eY-RpbhNNQ"

    setup do
      # Store original config values
      original_jwt_secret = Application.get_env(:realtime, :metrics_jwt_secret)
      original_jwks = Application.get_env(:realtime, :metrics_jwt_jwks)

      # Configure for JWKS-only auth (no secret, JWKS only)
      Application.put_env(:realtime, :metrics_jwt_secret, nil)
      Application.put_env(:realtime, :metrics_jwt_jwks, @es256_jwks)

      on_exit(fn ->
        Application.put_env(:realtime, :metrics_jwt_secret, original_jwt_secret)
        Application.put_env(:realtime, :metrics_jwt_jwks, original_jwks)
      end)

      :ok
    end

    test "GET /metrics accepts ES256 JWT from JWKS", %{conn: conn} do
      response =
        conn
        |> put_req_header("authorization", "Bearer #{@es256_token}")
        |> get(~p"/metrics")
        |> response(200)

      assert response =~ "# HELP"
    end

    test "GET /metrics/:region accepts ES256 JWT from JWKS", %{conn: conn} do
      response =
        conn
        |> put_req_header("authorization", "Bearer #{@es256_token}")
        |> get(~p"/metrics/ap-southeast-2")
        |> response(200)

      assert response =~ "# HELP"
    end

    test "GET /metrics rejects JWT with wrong signature" do
      # Generate a token signed with a DIFFERENT key (not in JWKS)
      other_key = %{
        "kty" => "EC",
        "x" => "j-VTe-Qzh6nh-GqPFMlTNuRLn-4sHmU8HuP02ueTd2E",
        "y" => "sZKgHeDwKv-zEUeyqRkwIanCIRvM1Bpob9hkIGQhQ4k",
        "crv" => "P-256",
        "d" => "TBPiDhcBctdrS66G2rgSWHvbwLbTk7kXNHJFSAYo0po"
      }
      {:ok, signer} = Joken.Signer.create("ES256", other_key)
      bad_token = Joken.generate_and_sign!(%{"jti" => "test"}, %{"role" => "authenticated", "exp" => 999_999_999_999}, signer)

      conn = build_conn()

      response =
        conn
        |> put_req_header("authorization", "Bearer " <> bad_token)
        |> get(~p"/metrics")
        |> response(403)

      assert response == ""
    end
  end

end
