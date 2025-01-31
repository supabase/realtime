defmodule RealtimeWeb.RealtimeChannelTest do
  use ExUnit.Case, async: false
  use RealtimeWeb.ChannelCase

  import Mock
  import ExUnit.CaptureLog

  alias Phoenix.Socket
  alias RealtimeWeb.ChannelsAuthorization
  alias RealtimeWeb.Joken.CurrentTime
  alias RealtimeWeb.UserSocket

  @tenant_external_id "dev_tenant"

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
      with_mock ChannelsAuthorization, [],
        authorize_conn: fn _, _, _ ->
          {:ok, %{"exp" => Joken.current_time() + 1_000, "role" => "postgres"}}
        end do
        {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts())

        socket = Socket.assign(socket, %{limits: %{@default_limits | max_concurrent_users: 1}})
        assert {:ok, _, %Socket{}} = subscribe_and_join(socket, "realtime:test", %{})
      end
    end

    test "reached" do
      with_mock ChannelsAuthorization, [],
        authorize_conn: fn _, _, _ ->
          {:ok, %{"exp" => Joken.current_time() + 1_000, "role" => "postgres"}}
        end do
        {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts())

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
  end

  describe "JWT token validations" do
    test "token has valid expiration" do
      with_mock ChannelsAuthorization, [],
        authorize_conn: fn _, _, _ ->
          {:ok, %{"exp" => Joken.current_time() + 1, "role" => "postgres"}}
        end do
        {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts())

        assert {:ok, _, %Socket{}} = subscribe_and_join(socket, "realtime:test", %{})
      end
    end

    test "token has invalid expiration" do
      with_mock ChannelsAuthorization, [],
        authorize_conn: fn _, _, _ ->
          {:ok, %{"exp" => Joken.current_time(), "role" => "postgres"}}
        end do
        {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts())

        assert capture_log(fn ->
                 assert {:error, %{reason: "Token expiration time is invalid"}} =
                          subscribe_and_join(socket, "realtime:test", %{})

                 Process.sleep(300)
               end) =~ "InvalidJWTExpiration: Token expiration time is invalid"
      end

      with_mock ChannelsAuthorization, [],
        authorize_conn: fn _, _, _ ->
          {:ok, %{"exp" => Joken.current_time() - 1, "role" => "postgres"}}
        end do
        {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts())

        assert capture_log(fn ->
                 assert {:error, %{reason: "Token expiration time is invalid"}} =
                          subscribe_and_join(socket, "realtime:test", %{})

                 Process.sleep(300)
               end) =~ "InvalidJWTExpiration: Token expiration time is invalid"
      end
    end

    test "missing claims returns a error" do
      with_mock ChannelsAuthorization, [], authorize_conn: fn _, _, _ -> {:error, :missing_claims} end do
        log =
          capture_log(fn ->
            assert {:error, :missing_claims} =
                     connect(UserSocket, %{"log_level" => "warning"}, conn_opts())

            Process.sleep(300)
          end)

        assert log =~ "InvalidJWTToken: Fields `role` and `exp` are required in JWT"
      end
    end

    test "missing claims returns a error with sub in metadata if available" do
      with_mock ChannelsAuthorization, [], authorize_conn: fn _, _, _ -> {:error, :missing_claims} end do
        sub = random_string()
        conn_opts = conn_opts(@tenant_external_id, %{sub: sub})

        log =
          capture_log(fn ->
            assert {:error, :missing_claims} =
                     connect(UserSocket, %{"log_level" => "warning"}, conn_opts)

            Process.sleep(300)
          end)

        assert log =~ "InvalidJWTToken: Fields `role` and `exp` are required in JWT"
        assert log =~ "sub=#{sub}"
      end
    end

    test "expired token returns a error" do
      with_mock ChannelsAuthorization, [],
        authorize_conn: fn _, _, _ ->
          {:error, :expired_token, "InvalidJWTToken: Token as expired 1000 seconds ago"}
        end do
        sub = random_string()
        conn_opts = conn_opts(@tenant_external_id, %{sub: sub})

        log =
          capture_log(fn ->
            assert {:error, :expired_token} =
                     connect(UserSocket, %{"log_level" => "warning"}, conn_opts)

            Process.sleep(300)
          end)

        assert log =~ "InvalidJWTToken: Token as expired 1000 seconds ago"
        assert log =~ "sub=#{sub}"
      end
    end

    test "expired token returns a error with sub in metadata if available" do
      with_mock ChannelsAuthorization, [],
        authorize_conn: fn _, _, _ ->
          {:error, :expired_token, "InvalidJWTToken: Token as expired 1000 seconds ago"}
        end do
        log =
          capture_log(fn ->
            assert {:error, :expired_token} =
                     connect(UserSocket, %{"log_level" => "warning"}, conn_opts())

            Process.sleep(300)
          end)

        assert log =~ "InvalidJWTToken: Token as expired 1000 seconds ago"
      end
    end
  end

  describe "checks tenant db connectivity" do
    setup_with_mocks([
      {ChannelsAuthorization, [],
       authorize_conn: fn _, _, _ ->
         {:ok, %{"exp" => Joken.current_time() + 1_000, "role" => "postgres"}}
       end}
    ]) do
      :ok
    end

    test "successful connection proceeds with join" do
      {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts())
      assert {:ok, _, %Socket{}} = subscribe_and_join(socket, "realtime:test", %{})
    end

    test "unsuccessful connection halts join" do
      extensions = [
        %{
          "type" => "postgres_cdc_rls",
          "settings" => %{
            "db_host" => "127.0.0.1",
            "db_name" => "false",
            "db_user" => "false",
            "db_password" => "false",
            "db_port" => "5433",
            "poll_interval" => 100,
            "poll_max_changes" => 100,
            "poll_max_record_bytes" => 1_048_576,
            "region" => "us-east-1",
            "ssl_enforced" => false
          }
        }
      ]

      tenant = tenant_fixture(%{extensions: extensions})

      {:ok, %Socket{} = socket} =
        connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant.external_id))

      assert {:error, %{reason: "Realtime was unable to connect to the project database"}} =
               subscribe_and_join(socket, "realtime:test", %{})
    end

    test "lack of connections halts join" do
      extensions = [
        %{
          "type" => "postgres_cdc_rls",
          "settings" => %{
            "db_host" => "localhost",
            "db_name" => "postgres",
            "db_user" => "supabase_admin",
            "db_password" => "postgres",
            "db_port" => "5433",
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

      {:ok, %Socket{} = socket} =
        connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant.external_id))

      assert {:error, %{reason: "Database can't accept more connections, Realtime won't connect"}} =
               subscribe_and_join(socket, "realtime:test", %{})
    end
  end

  defp conn_opts(tenant_id \\ @tenant_external_id, claims \\ %{}) do
    [
      connect_info: %{
        uri: URI.parse("https://#{tenant_id}.localhost:4000/socket/websocket"),
        x_headers: [{"x-api-key", generate_jwt_token("secret", claims)}]
      }
    ]
  end
end
