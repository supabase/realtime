defmodule RealtimeWeb.RealtimeChannelTest do
  # Can't run async true because under the hood Cachex is used and it doesn't see Ecto Sandbox
  # Also using global otel_simple_processor
  use RealtimeWeb.ChannelCase, async: false

  import ExUnit.CaptureLog

  alias Phoenix.Socket
  alias RealtimeWeb.Joken.CurrentTime
  alias RealtimeWeb.UserSocket

  @default_limits %{
    max_concurrent_users: 200,
    max_events_per_second: 100,
    max_joins_per_second: 100,
    max_channels_per_client: 100,
    max_bytes_per_second: 100_000
  }

  @parent_id "b7ad6b7169203331"
  @traceparent "00-0af7651916cd43dd8448eb211c80319c-#{@parent_id}-01"
  @span_parent_id Integer.parse(@parent_id, 16) |> elem(0)

  setup do
    start_supervised!(CurrentTime.Mock)
    tenant = Containers.checkout_tenant(run_migrations: true)

    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())

    {:ok, tenant: tenant}
  end

  describe "connect/3" do
    test "successful connection", %{tenant: tenant} do
      jwt = Generators.generate_jwt_token(tenant)
      {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))

      assert socket.assigns.claims["role"] == "authenticated"
      assert socket.assigns.tenant == tenant.external_id
      assert socket.assigns.limits == @default_limits

      # parent span is properly propagated
      attributes = :otel_attributes.new([external_id: tenant.external_id], 128, :infinity)
      assert_receive {:span, span(name: "websocket.connect", attributes: ^attributes, parent_span_id: @span_parent_id)}
    end
  end

  describe "maximum number of connected clients per tenant" do
    test "not reached", %{tenant: tenant} do
      jwt = Generators.generate_jwt_token(tenant)
      {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))

      socket = Socket.assign(socket, %{limits: %{@default_limits | max_concurrent_users: 1}})
      assert {:ok, _, %Socket{}} = subscribe_and_join(socket, "realtime:test", %{})
    end

    test "reached", %{tenant: tenant} do
      jwt = Generators.generate_jwt_token(tenant)
      {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))

      socket_at_capacity =
        Socket.assign(socket, %{limits: %{@default_limits | max_concurrent_users: 0}})

      socket_over_capacity =
        Socket.assign(socket, %{limits: %{@default_limits | max_concurrent_users: -1}})

      assert {:error, %{reason: "Too many connected users"}} =
               subscribe_and_join(socket_at_capacity, "realtime:test", %{})

      assert {:error, %{reason: "Too many connected users"}} =
               subscribe_and_join(socket_over_capacity, "realtime:test", %{})
    end
  end

  describe "JWT token validations" do
    test "token has valid expiration", %{tenant: tenant} do
      jwt = Generators.generate_jwt_token(tenant)
      {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))

      assert {:ok, _, %Socket{}} = subscribe_and_join(socket, "realtime:test", %{})
      # no error
      assert_receive {:span, span(name: "websocket.connect", status: :undefined)}
    end

    test "token has invalid expiration", %{tenant: tenant} do
      assert capture_log(fn ->
               jwt = Generators.generate_jwt_token(tenant, %{role: "authenticated", exp: System.system_time(:second)})

               assert {:error, :expired_token} =
                        connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))
             end) =~ "InvalidJWTToken: Token has expired"

      jwt = Generators.generate_jwt_token(tenant, %{role: "authenticated", exp: System.system_time(:second) - 1})

      assert capture_log(fn ->
               assert {:error, :expired_token} =
                        connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))
             end) =~ "InvalidJWTToken: Token has expired"

      assert_receive {:span, span(name: "websocket.connect", status: status(code: :error, message: "InvalidJWTToken"))}
    end

    test "missing role claims returns a error", %{tenant: tenant} do
      jwt = Generators.generate_jwt_token(tenant, %{exp: System.system_time(:second) + 1000})

      log =
        capture_log(fn ->
          assert {:error, :missing_claims} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))
        end)

      assert log =~ "InvalidJWTToken: Fields `role` and `exp` are required in JWT"
      assert_receive {:span, span(name: "websocket.connect", status: status(code: :error, message: "InvalidJWTToken"))}
    end

    test "missing exp claims returns a error", %{tenant: tenant} do
      jwt = Generators.generate_jwt_token(tenant, %{role: "authenticated"})

      log =
        capture_log(fn ->
          assert {:error, :missing_claims} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))
        end)

      assert log =~ "InvalidJWTToken: Fields `role` and `exp` are required in JWT"
      assert_receive {:span, span(name: "websocket.connect", status: status(code: :error, message: "InvalidJWTToken"))}
    end

    test "missing claims returns a error with sub in metadata if available", %{tenant: tenant} do
      sub = random_string()

      jwt = Generators.generate_jwt_token(tenant, %{exp: System.system_time(:second) + 10_000, sub: sub})

      log =
        capture_log(fn ->
          assert {:error, :missing_claims} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))
        end)

      assert log =~ "InvalidJWTToken: Fields `role` and `exp` are required in JWT"
      assert log =~ "sub=#{sub}"
      assert_receive {:span, span(name: "websocket.connect", status: status(code: :error, message: "InvalidJWTToken"))}
    end

    test "expired token returns a error with sub data if available", %{tenant: tenant} do
      sub = random_string()

      jwt =
        Generators.generate_jwt_token(tenant, %{role: "authenticated", exp: System.system_time(:second) - 1, sub: sub})

      log =
        capture_log(fn ->
          assert {:error, :expired_token} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))
        end)

      assert log =~ "InvalidJWTToken: Token has expired"
      assert log =~ "sub=#{sub}"
      assert_receive {:span, span(name: "websocket.connect", status: status(code: :error, message: "InvalidJWTToken"))}
    end
  end

  describe "checks tenant db connectivity" do
    test "successful connection proceeds with join", %{tenant: tenant} do
      jwt = Generators.generate_jwt_token(tenant)

      {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))
      assert {:ok, _, %Socket{}} = subscribe_and_join(socket, "realtime:test", %{})
    end

    test "unsuccessful connection halts join", %{tenant: tenant} do
      extension = %{
        "type" => "postgres_cdc_rls",
        "settings" => %{
          "db_host" => "127.0.0.1",
          "db_name" => "false",
          "db_user" => "false",
          "db_password" => "false",
          "poll_interval" => 100,
          "poll_max_changes" => 100,
          "poll_max_record_bytes" => 1_048_576,
          "region" => "us-east-1",
          "ssl_enforced" => false
        }
      }

      {:ok, tenant} = update_extension(tenant, extension)
      jwt = Generators.generate_jwt_token(tenant)
      {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))

      assert {:error, %{reason: "Realtime was unable to connect to the project database"}} =
               subscribe_and_join(socket, "realtime:test", %{})
    end

    test "lack of connections halts join", %{tenant: tenant} do
      extension =
        %{
          "type" => "postgres_cdc_rls",
          "settings" => %{
            "db_host" => "127.0.0.1",
            "db_name" => "postgres",
            "db_user" => "supabase_admin",
            "db_password" => "postgres",
            "poll_interval" => 100,
            "poll_max_changes" => 100,
            "poll_max_record_bytes" => 1_048_576,
            "region" => "us-east-1",
            "ssl_enforced" => false,
            "db_pool" => 100,
            "subcriber_pool_size" => 100,
            "subs_pool_size" => 100
          }
        }

      {:ok, tenant} = update_extension(tenant, extension)

      jwt = Generators.generate_jwt_token(tenant)
      {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))

      assert {:error, %{reason: "Database can't accept more connections, Realtime won't connect"}} =
               subscribe_and_join(socket, "realtime:test", %{})
    end
  end

  defp conn_opts(tenant, token, params \\ %{}) do
    [
      connect_info: %{
        uri: URI.parse("https://#{tenant.external_id}.localhost:4000/socket/websocket"),
        x_headers: [{"x-api-key", token}],
        trace_context_headers: [{"traceparent", @traceparent}]
      },
      params: params
    ]
  end

  defp update_extension(tenant, extension) do
    db_port = Realtime.Crypto.decrypt!(hd(tenant.extensions).settings["db_port"])

    extensions = [
      put_in(extension, ["settings", "db_port"], db_port)
    ]

    Realtime.Api.update_tenant(tenant, %{extensions: extensions})
  end
end
