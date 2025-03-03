defmodule RealtimeWeb.RealtimeChannelTest do
  use RealtimeWeb.ChannelCase

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
  setup do
    start_supervised!(CurrentTime.Mock)
    :ok
  end

  describe "maximum number of connected clients per tenant" do
    test "not reached" do
      tenant = Containers.checkout_tenant(true)
      on_exit(fn -> Containers.checkin_tenant(tenant) end)

      jwt = Generators.generate_jwt_token(tenant)
      {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))

      socket = Socket.assign(socket, %{limits: %{@default_limits | max_concurrent_users: 1}})
      assert {:ok, _, %Socket{}} = subscribe_and_join(socket, "realtime:test", %{})
    end

    test "reached" do
      tenant = Containers.checkout_tenant(true)
      on_exit(fn -> Containers.checkin_tenant(tenant) end)
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
    test "token has valid expiration" do
      tenant = Containers.checkout_tenant(true)
      on_exit(fn -> Containers.checkin_tenant(tenant) end)

      jwt = Generators.generate_jwt_token(tenant)
      {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))

      assert {:ok, _, %Socket{}} = subscribe_and_join(socket, "realtime:test", %{})
    end

    test "token has invalid expiration" do
      tenant = Containers.checkout_tenant(true)
      on_exit(fn -> Containers.checkin_tenant(tenant) end)

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

    test "missing role claims returns a error" do
      tenant = Containers.checkout_tenant(true)
      on_exit(fn -> Containers.checkin_tenant(tenant) end)

      jwt = Generators.generate_jwt_token(tenant, %{exp: System.system_time(:second) + 1000})

      log =
        capture_log(fn ->
          assert {:error, :missing_claims} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))
        end)

      assert log =~ "InvalidJWTToken: Fields `role` and `exp` are required in JWT"
    end

    test "missing exp claims returns a error" do
      tenant = Containers.checkout_tenant(true)
      on_exit(fn -> Containers.checkin_tenant(tenant) end)

      jwt = Generators.generate_jwt_token(tenant, %{role: "authenticated"})

      log =
        capture_log(fn ->
          assert {:error, :missing_claims} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))
        end)

      assert log =~ "InvalidJWTToken: Fields `role` and `exp` are required in JWT"
    end

    test "missing claims returns a error with sub in metadata if available" do
      tenant = Containers.checkout_tenant(true)
      on_exit(fn -> Containers.checkin_tenant(tenant) end)
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

    test "expired token returns a error with sub data if available" do
      tenant = Containers.checkout_tenant(true)
      on_exit(fn -> Containers.checkin_tenant(tenant) end)
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
    test "successful connection proceeds with join" do
      tenant = Containers.checkout_tenant(true)
      on_exit(fn -> Containers.checkin_tenant(tenant) end)

      jwt = Generators.generate_jwt_token(tenant)

      {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))
      assert {:ok, _, %Socket{}} = subscribe_and_join(socket, "realtime:test", %{})
    end

    test "unsuccessful connection halts join" do
      port = Enum.random(5500..9000)

      extensions = [
        %{
          "type" => "postgres_cdc_rls",
          "settings" => %{
            "db_host" => "127.0.0.1",
            "db_name" => "false",
            "db_user" => "false",
            "db_password" => "false",
            "db_port" => "#{port}",
            "poll_interval" => 100,
            "poll_max_changes" => 100,
            "poll_max_record_bytes" => 1_048_576,
            "region" => "us-east-1",
            "ssl_enforced" => false
          }
        }
      ]

      tenant = tenant_fixture(%{extensions: extensions})
      jwt = Generators.generate_jwt_token(tenant)
      {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))

      assert {:error, %{reason: "Realtime was unable to connect to the project database"}} =
               subscribe_and_join(socket, "realtime:test", %{})
    end

    test "lack of connections halts join" do
      port = Enum.random(5500..9000)

      extensions = [
        %{
          "type" => "postgres_cdc_rls",
          "settings" => %{
            "db_host" => "127.0.0.1",
            "db_name" => "postgres",
            "db_user" => "supabase_admin",
            "db_password" => "postgres",
            "db_port" => "#{port}",
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
      ]

      tenant = tenant_fixture(%{extensions: extensions})
      tenant = Containers.initialize(tenant, true, false)
      on_exit(fn -> Containers.stop_container(tenant) end)

      jwt = Generators.generate_jwt_token(tenant)
      {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))

      assert {:error, %{reason: "Database can't accept more connections, Realtime won't connect"}} =
               subscribe_and_join(socket, "realtime:test", %{})
    end
  end

  def handle_telemetry(event, metadata, _, pid: pid), do: send(pid, {event, metadata})

  describe "billable events" do
    setup do
      events = [
        [:channel, :joins],
        [:channel, :events],
        [:channel, :db_events]
      ]

      :telemetry.attach_many(__MODULE__, events, &__MODULE__.handle_telemetry/4, pid: self())

      tenant = Containers.checkout_tenant(true)

      on_exit(fn ->
        :telemetry.detach(__MODULE__)
        Containers.checkin_tenant(tenant)
      end)

      %{tenant: tenant}
    end

    test "rules are properly full lifecycle of connection", %{tenant: tenant} do
      topic = "realtime:test"
      jwt = Generators.generate_jwt_token(tenant)
      {:ok, %Socket{} = socket} = connect(UserSocket, %{}, conn_opts(tenant, jwt))
      assert {:ok, _, %Socket{}} = subscribe_and_join(socket, topic, %{})

      assert_receive {:telemetry, _, %{event: [:channel, :joins], metadata: %{count: 1}}}, 500
      refute_receive {:telemetry, _, %{event: [:channel, :events], metadata: %{count: 1}}}, 500
      refute_receive {:telemetry, _, %{event: [:channel, :db_events], metadata: %{count: 1}}}, 500

      broadcast_from(socket, topic, %{event: "test_event"})

      refute_receive {:telemetry, _, %{event: [:channel, :joins], metadata: %{count: 0}}}, 500
      assert_receive {:telemetry, _, %{event: [:channel, :events], metadata: %{count: 1}}}, 500
      assert_receive {:telemetry, _, %{event: [:channel, :db_events], metadata: %{count: 1}}}, 500
    end
  end

  defp conn_opts(tenant, token) do
    [
      connect_info: %{
        uri: URI.parse("https://#{tenant.external_id}.localhost:4000/socket/websocket"),
        x_headers: [{"x-api-key", token}]
      }
    ]
  end
end
