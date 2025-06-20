defmodule RealtimeWeb.RealtimeChannelTest do
  # Can't run async true because under the hood Cachex is used and it doesn't see Ecto Sandbox
  use RealtimeWeb.ChannelCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Phoenix.Socket
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Connect
  alias RealtimeWeb.UserSocket

  @default_limits %{
    max_concurrent_users: 200,
    max_events_per_second: 100,
    max_joins_per_second: 100,
    max_channels_per_client: 100,
    max_bytes_per_second: 100_000
  }
  setup do
    tenant = Containers.checkout_tenant(run_migrations: true)
    {:ok, tenant: tenant}
  end

  describe "unexpected errors" do
    test "unexpected error on Connect", %{tenant: tenant} do
      jwt = Generators.generate_jwt_token(tenant)
      {:ok, %Socket{} = socket} = connect(UserSocket, %{}, conn_opts(tenant, jwt))

      expect(Connect, :lookup_or_start_connection, fn _ -> {:error, :unexpected_error} end)

      assert capture_log(fn ->
               assert {:error, %{reason: "Unknown Error on Channel"}} = subscribe_and_join(socket, "realtime:test", %{})
             end) =~ "UnknownErrorOnChannel"
    end

    test "unexpected error while setting policies", %{tenant: tenant} do
      jwt = Generators.generate_jwt_token(tenant)
      {:ok, %Socket{} = socket} = connect(UserSocket, %{}, conn_opts(tenant, jwt))

      expect(Authorization, :get_read_authorizations, fn _, _, _ -> {:error, :unexpected_error} end)

      assert capture_log(fn ->
               assert {:error, %{reason: "Realtime was unable to connect to the project database"}} =
                        subscribe_and_join(socket, "realtime:test", %{"config" => %{"private" => true}})
             end) =~ "UnableToSetPolicies"
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
    end

    test "token has invalid expiration", %{tenant: tenant} do
      assert capture_log(fn ->
               jwt = Generators.generate_jwt_token(tenant, %{role: "authenticated", exp: System.system_time(:second)})

               assert {:error, :expired_token} =
                        connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))

               Process.sleep(300)
             end) =~ "InvalidJWTToken: Token has expired"

      jwt = Generators.generate_jwt_token(tenant, %{role: "authenticated", exp: System.system_time(:second) - 1})

      assert capture_log(fn ->
               assert {:error, :expired_token} =
                        connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))
             end) =~ "InvalidJWTToken: Token has expired"
    end

    test "missing role claims returns a error", %{tenant: tenant} do
      jwt = Generators.generate_jwt_token(tenant, %{exp: System.system_time(:second) + 1000})

      log =
        capture_log(fn ->
          assert {:error, :missing_claims} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))
        end)

      assert log =~ "InvalidJWTToken: Fields `role` and `exp` are required in JWT"
    end

    test "missing exp claims returns a error", %{tenant: tenant} do
      jwt = Generators.generate_jwt_token(tenant, %{role: "authenticated"})

      log =
        capture_log(fn ->
          assert {:error, :missing_claims} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))
        end)

      assert log =~ "InvalidJWTToken: Fields `role` and `exp` are required in JWT"
    end

    test "missing claims returns a error with sub in metadata if available", %{tenant: tenant} do
      sub = random_string()

      jwt = Generators.generate_jwt_token(tenant, %{exp: System.system_time(:second) + 10_000, sub: sub})

      log =
        capture_log(fn ->
          assert {:error, :missing_claims} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))

          Process.sleep(300)
        end)

      assert log =~ "InvalidJWTToken: Fields `role` and `exp` are required in JWT"
      assert log =~ "sub=#{sub}"
    end

    test "expired token returns a error with sub data if available", %{tenant: tenant} do
      sub = random_string()

      jwt =
        Generators.generate_jwt_token(tenant, %{role: "authenticated", exp: System.system_time(:second) - 1, sub: sub})

      log =
        capture_log(fn ->
          assert {:error, :expired_token} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))

          Process.sleep(300)
        end)

      assert log =~ "InvalidJWTToken: Token has expired"
      assert log =~ "sub=#{sub}"
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

  test "registers transport pid and channel pid per tenant", %{tenant: tenant} do
    jwt = Generators.generate_jwt_token(tenant)
    {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))

    assert {:ok, _, %Socket{transport_pid: transport_pid_1} = socket} =
             subscribe_and_join(socket, "realtime:#{random_string()}", %{})

    assert {:ok, _, %Socket{transport_pid: ^transport_pid_1}} =
             subscribe_and_join(socket, "realtime:#{random_string()}", %{})

    assert [{_, ^transport_pid_1}] = Registry.lookup(RealtimeWeb.SocketDisconnect.Registry, tenant.external_id)
  end

  defp conn_opts(tenant, token, params \\ %{}) do
    [
      connect_info: %{
        uri: URI.parse("https://#{tenant.external_id}.localhost:4000/socket/websocket"),
        x_headers: [{"x-api-key", token}]
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
