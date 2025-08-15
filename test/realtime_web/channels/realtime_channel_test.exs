defmodule RealtimeWeb.RealtimeChannelTest do
  # Can't run async true because under the hood Cachex is used and it doesn't see Ecto Sandbox
  use RealtimeWeb.ChannelCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Realtime.GenCounter
  alias Phoenix.Socket
  alias Phoenix.Channel.Server

  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Connect
  alias Realtime.RateCounter
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

  setup :rls_context

  describe "presence" do
    test "events are counted", %{tenant: tenant} do
      jwt = Generators.generate_jwt_token(tenant)
      {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))

      assert {:ok, _, %Socket{} = socket} = subscribe_and_join(socket, "realtime:test", %{})

      presence_diff = %Socket.Broadcast{event: "presence_diff", payload: %{joins: %{}, leaves: %{}}}
      send(socket.channel_pid, presence_diff)

      assert_receive %Socket.Message{topic: "realtime:test", event: "presence_state", payload: %{}}

      assert_receive %Socket.Message{
        topic: "realtime:test",
        event: "presence_diff",
        payload: %{joins: %{}, leaves: %{}}
      }

      tenant_id = tenant.external_id

      # Wait for RateCounter to tick
      Process.sleep(1100)

      assert {:ok, %RateCounter{id: {:channel, :presence_events, ^tenant_id}, bucket: bucket}} =
               RateCounter.get(socket.assigns.presence_rate_counter)

      # presence_state + presence_diff
      assert 2 in bucket
    end

    test "log if limit is reached", %{tenant: tenant} do
      jwt = Generators.generate_jwt_token(tenant)
      {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))

      assert {:ok, _, %Socket{} = socket} = subscribe_and_join(socket, "realtime:test", %{})
      GenCounter.add(socket.assigns.presence_rate_counter.id, 1000)
      # Wait for RateCounter to tick
      Process.sleep(1100)

      log =
        capture_log(fn ->
          presence_diff = %Socket.Broadcast{event: "presence_diff", payload: %{joins: %{}, leaves: %{}}}
          send(socket.channel_pid, presence_diff)

          assert_receive %Socket.Message{topic: "realtime:test", event: "presence_state", payload: %{}}

          assert_receive %Socket.Message{
            topic: "realtime:test",
            event: "presence_diff",
            payload: %{joins: %{}, leaves: %{}}
          }
        end)

      assert log =~ "Too many presence messages per second"
    end

    test "rate counter is restarted if not up and running", %{tenant: tenant} do
      jwt = Generators.generate_jwt_token(tenant)
      {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))

      assert {:ok, _, %Socket{} = socket} = subscribe_and_join(socket, "realtime:test", %{})
      rate_counter = socket.assigns.presence_rate_counter

      assert [{pid, _}] = Registry.lookup(Realtime.Registry.Unique, {RateCounter, :rate_counter, rate_counter.id})
      Process.monitor(pid)
      RateCounter.stop(tenant.external_id)
      assert_receive {:DOWN, _ref, :process, ^pid, _reason}

      presence_diff = %Socket.Broadcast{event: "presence_diff", payload: %{joins: %{}, leaves: %{}}}
      send(socket.channel_pid, presence_diff)

      assert_receive %Socket.Message{topic: "realtime:test", event: "presence_state", payload: %{}}

      assert_receive %Socket.Message{
        topic: "realtime:test",
        event: "presence_diff",
        payload: %{joins: %{}, leaves: %{}}
      }

      assert [{new_pid, _}] = Registry.lookup(Realtime.Registry.Unique, {RateCounter, :rate_counter, rate_counter.id})
      assert pid != new_pid
    end
  end

  describe "unexpected errors" do
    test "unexpected error on Connect", %{tenant: tenant} do
      jwt = Generators.generate_jwt_token(tenant)
      {:ok, %Socket{} = socket} = connect(UserSocket, %{}, conn_opts(tenant, jwt))

      expect(Connect, :lookup_or_start_connection, fn _ ->
        {:error, "Realtime was unable to connect to the project database"}
      end)

      assert capture_log(fn ->
               assert {:error, %{reason: "Unknown Error on Channel"}} =
                        subscribe_and_join(socket, "realtime:test", %{})
             end) =~ "UnknownErrorOnChannel: Realtime was unable to connect to the project database"
    end

    test "unexpected error while setting policies", %{tenant: tenant} do
      jwt = Generators.generate_jwt_token(tenant)
      {:ok, %Socket{} = socket} = connect(UserSocket, %{}, conn_opts(tenant, jwt))

      expect(Authorization, :get_read_authorizations, fn _, _, _ ->
        {:error, "Realtime was unable to connect to the project database"}
      end)

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

      assert {:error, %{reason: "ConnectionRateLimitReached: Too many connected users"}} =
               subscribe_and_join(socket_at_capacity, "realtime:test", %{})

      assert {:error, %{reason: "ConnectionRateLimitReached: Too many connected users"}} =
               subscribe_and_join(socket_over_capacity, "realtime:test", %{})
    end
  end

  describe "access_token" do
    @tag policies: [:authenticated_all_topic_read]
    test "new valid access_token", %{tenant: tenant} do
      jwt = Generators.generate_jwt_token(tenant)
      {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))

      assert socket = subscribe_and_join!(socket, "realtime:test", %{"config" => %{"private" => true}})
      old_confirm_ref = socket.assigns.confirm_token_ref

      assert socket.assigns.policies == %Realtime.Tenants.Authorization.Policies{
               broadcast: %Realtime.Tenants.Authorization.Policies.BroadcastPolicies{read: true, write: nil},
               presence: %Realtime.Tenants.Authorization.Policies.PresencePolicies{read: true, write: nil}
             }

      new_token =
        Generators.generate_jwt_token(tenant, %{
          exp: System.system_time(:second) + 10_000,
          role: "authenticated",
          sub: "123"
        })

      assert new_token != jwt

      push(socket, "access_token", %{"access_token" => new_token})

      socket = Server.socket(socket.channel_pid)

      assert socket.assigns.access_token == new_token
      assert socket.assigns.confirm_token_ref != old_confirm_ref
    end

    @tag policies: [:authenticated_all_topic_read]
    test "new valid access_token and policy has changed", %{tenant: tenant} do
      jwt = Generators.generate_jwt_token(tenant)
      {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))

      assert socket = subscribe_and_join!(socket, "realtime:test", %{"config" => %{"private" => true}})

      assert socket.assigns.policies == %Realtime.Tenants.Authorization.Policies{
               broadcast: %Realtime.Tenants.Authorization.Policies.BroadcastPolicies{read: true, write: nil},
               presence: %Realtime.Tenants.Authorization.Policies.PresencePolicies{read: true, write: nil}
             }

      new_token =
        Generators.generate_jwt_token(tenant, %{
          exp: System.system_time(:second) + 10_000,
          role: "authenticated",
          sub: "123"
        })

      assert new_token != jwt

      # RLS policies removed so it should now fail
      {:ok, db_conn} = Realtime.Database.connect(tenant, "realtime_test")
      clean_table(db_conn, "realtime", "messages")

      push(socket, "access_token", %{"access_token" => new_token})

      # Channel closes
      assert_process_down(socket.channel_pid)
    end

    test "new valid access_token but Connect timed out", %{tenant: tenant} do
      jwt = Generators.generate_jwt_token(tenant)
      {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))

      assert %Socket{channel_pid: channel_pid} = socket = subscribe_and_join!(socket, "realtime:test", %{})

      new_token =
        Generators.generate_jwt_token(tenant, %{
          exp: System.system_time(:second) + 10_000,
          role: "authenticated",
          sub: "123"
        })

      assert new_token != jwt

      log =
        capture_log(fn ->
          expect(Connect, :lookup_or_start_connection, fn _ -> {:error, :rpc_error, :timeout} end)
          allow(Connect, self(), channel_pid)

          push(socket, "access_token", %{"access_token" => new_token})

          # Channel closes
          assert_process_down(channel_pid)
        end)

      assert log =~ "Node request timeout"
    end

    test "new valid access_token but Connect had an error", %{tenant: tenant} do
      jwt = Generators.generate_jwt_token(tenant)
      {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))

      assert %Socket{channel_pid: channel_pid} = socket = subscribe_and_join!(socket, "realtime:test", %{})

      new_token =
        Generators.generate_jwt_token(tenant, %{
          exp: System.system_time(:second) + 10_000,
          role: "authenticated",
          sub: "123"
        })

      assert new_token != jwt

      log =
        capture_log(fn ->
          expect(Connect, :lookup_or_start_connection, fn _ -> {:error, :rpc_error, {:EXIT, :actual_error}} end)
          allow(Connect, self(), channel_pid)

          push(socket, "access_token", %{"access_token" => new_token})

          # Channel closes
          assert_process_down(channel_pid)
        end)

      assert log =~ "RPC call error: {:EXIT, :actual_error}"
    end

    test "new broken access_token", %{tenant: tenant} do
      jwt = Generators.generate_jwt_token(tenant)
      {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))

      assert %Socket{channel_pid: channel_pid} = socket = subscribe_and_join!(socket, "realtime:test", %{})

      new_token = "not even a JWT"

      push(socket, "access_token", %{"access_token" => new_token})

      # Channel closes
      assert_process_down(channel_pid)

      assert_receive %Socket.Message{
        topic: "realtime:test",
        event: "system",
        payload: %{
          message: "The token provided is not a valid JWT",
          status: "error",
          extension: "system",
          channel: "test"
        }
      }

      # Socket also closes...
      assert_receive {:socket_close, ^channel_pid, :normal}
    end

    test "new JWT missing role claim", %{tenant: tenant} do
      jwt = Generators.generate_jwt_token(tenant)
      {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))

      assert %Socket{channel_pid: channel_pid} = socket = subscribe_and_join!(socket, "realtime:test", %{})

      new_token = Generators.generate_jwt_token(tenant, %{exp: System.system_time(:second) + 10_000})

      push(socket, "access_token", %{"access_token" => new_token})

      # Channel closes
      assert_process_down(channel_pid)

      assert_receive %Socket.Message{
        topic: "realtime:test",
        event: "system",
        payload: %{
          message: "Fields `role` and `exp` are required in JWT",
          status: "error",
          extension: "system",
          channel: "test"
        }
      }

      # Socket also closes...
      assert_receive {:socket_close, ^channel_pid, :normal}
    end

    test "new JWT missing exp claim", %{tenant: tenant} do
      jwt = Generators.generate_jwt_token(tenant)
      {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))

      assert %Socket{channel_pid: channel_pid} = socket = subscribe_and_join!(socket, "realtime:test", %{})

      new_token = Generators.generate_jwt_token(tenant, %{role: "authenticated"})

      push(socket, "access_token", %{"access_token" => new_token})

      # Channel closes
      assert_process_down(channel_pid)

      assert_receive %Socket.Message{
        topic: "realtime:test",
        event: "system",
        payload: %{
          message: "Fields `role` and `exp` are required in JWT",
          status: "error",
          extension: "system",
          channel: "test"
        }
      }

      # Socket also closes...
      assert_receive {:socket_close, ^channel_pid, :normal}
    end

    test "new expired JWT", %{tenant: tenant} do
      jwt = Generators.generate_jwt_token(tenant)
      {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))

      assert %Socket{channel_pid: channel_pid} = socket = subscribe_and_join!(socket, "realtime:test", %{})

      new_token =
        Generators.generate_jwt_token(tenant, %{role: "authenticated", exp: System.system_time(:second) - 1000})

      push(socket, "access_token", %{"access_token" => new_token})

      # Channel closes
      assert_process_down(channel_pid)

      assert_receive %Socket.Message{
        topic: "realtime:test",
        event: "system",
        payload: %{
          message: message,
          status: "error",
          extension: "system",
          channel: "test"
        }
      }

      assert message =~ ~r{Token has expired \d+ seconds ago}

      # Socket also closes...
      assert_receive {:socket_close, ^channel_pid, :normal}
    end
  end

  describe "confirm token" do
    test "token has expired", %{tenant: tenant} do
      jwt = Generators.generate_jwt_token(tenant, %{role: "authenticated", exp: System.system_time(:second) + 2})
      {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, jwt))

      assert %Socket{channel_pid: channel_pid} = subscribe_and_join!(socket, "realtime:test", %{})

      Process.sleep(2000)
      send(channel_pid, :confirm_token)

      # Channel closes
      assert_process_down(channel_pid)

      assert_receive %Socket.Message{
        topic: "realtime:test",
        event: "system",
        payload: %{
          message: "Token has expired 0 seconds ago",
          status: "error",
          extension: "system",
          channel: "test"
        }
      }
    end
  end

  describe "access_token validations" do
    test "access_token has expired", %{tenant: tenant} do
      api_key = Generators.generate_jwt_token(tenant)
      jwt = Generators.generate_jwt_token(tenant, %{role: "authenticated", exp: System.system_time(:second) - 1})

      assert {:ok, socket} = connect(UserSocket, %{}, conn_opts(tenant, api_key))

      assert {:error, %{reason: "InvalidJWTToken: Token has expired " <> _}} =
               subscribe_and_join(socket, "realtime:test", %{"access_token" => jwt})
    end

    test "access_token has expired log_level=warning", %{tenant: tenant} do
      api_key = Generators.generate_jwt_token(tenant)
      jwt = Generators.generate_jwt_token(tenant, %{role: "authenticated", exp: System.system_time(:second) - 1})

      assert {:ok, socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, api_key))

      assert {:error, %{reason: "InvalidJWTToken: Token has expired " <> _}} =
               subscribe_and_join(socket, "realtime:test", %{"access_token" => jwt})
    end

    test "access_token missing exp claim on join", %{tenant: tenant} do
      api_key = Generators.generate_jwt_token(tenant)
      jwt = Generators.generate_jwt_token(tenant, %{role: "authenticated"})

      assert {:ok, socket} = connect(UserSocket, %{}, conn_opts(tenant, api_key))

      assert {:error, %{reason: "InvalidJWTToken: Fields `role` and `exp` are required in JWT"}} =
               subscribe_and_join(socket, "realtime:test", %{"access_token" => jwt})
    end

    test "access_token missing exp claim on join log_level=warning", %{tenant: tenant} do
      api_key = Generators.generate_jwt_token(tenant)
      jwt = Generators.generate_jwt_token(tenant, %{role: "authenticated"})

      assert {:ok, socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, api_key))

      assert {:error, %{reason: "InvalidJWTToken: Fields `role` and `exp` are required in JWT"}} =
               subscribe_and_join(socket, "realtime:test", %{"access_token" => jwt})
    end

    test "access_token missing role claim on join", %{tenant: tenant} do
      api_key = Generators.generate_jwt_token(tenant)
      jwt = Generators.generate_jwt_token(tenant, %{exp: System.system_time(:second) + 1000})

      assert {:ok, socket} = connect(UserSocket, %{}, conn_opts(tenant, api_key))

      assert {:error, %{reason: "InvalidJWTToken: Fields `role` and `exp` are required in JWT"}} =
               subscribe_and_join(socket, "realtime:test", %{"access_token" => jwt})
    end

    test "access_token missing role claim on join log_level=warning", %{tenant: tenant} do
      api_key = Generators.generate_jwt_token(tenant)
      jwt = Generators.generate_jwt_token(tenant, %{exp: System.system_time(:second) + 1000})

      assert {:ok, socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, api_key))

      assert {:error, %{reason: "InvalidJWTToken: Fields `role` and `exp` are required in JWT"}} =
               subscribe_and_join(socket, "realtime:test", %{"access_token" => jwt})
    end

    test "missing claims returns error no logs", %{tenant: tenant} do
      sub = random_string()
      iss = "https://#{random_string()}.com"
      exp = System.system_time(:second) + 10_000

      api_key = Generators.generate_jwt_token(tenant)
      jwt = Generators.generate_jwt_token(tenant, %{exp: exp, sub: sub, iss: iss})

      assert {:ok, socket} = connect(UserSocket, %{}, conn_opts(tenant, api_key))

      log =
        capture_log(fn ->
          assert {:error, %{reason: "InvalidJWTToken: Fields `role` and `exp` are required in JWT"}} =
                   subscribe_and_join(socket, "realtime:test", %{"access_token" => jwt})
        end)

      refute log =~ "InvalidJWTToken: Fields `role` and `exp` are required in JWT"
    end

    test "missing claims returns a error with token exp, iss and sub in metadata if available log_level=warning", %{
      tenant: tenant
    } do
      sub = random_string()
      iss = "https://#{random_string()}.com"
      exp = System.system_time(:second) + 10_000

      api_key = Generators.generate_jwt_token(tenant)
      jwt = Generators.generate_jwt_token(tenant, %{exp: exp, sub: sub, iss: iss})

      assert {:ok, socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, api_key))

      log =
        capture_log(fn ->
          assert {:error, %{reason: "InvalidJWTToken: Fields `role` and `exp` are required in JWT"}} =
                   subscribe_and_join(socket, "realtime:test", %{"access_token" => jwt})
        end)

      assert log =~ "InvalidJWTToken: Fields `role` and `exp` are required in JWT"
      assert log =~ "sub=#{sub}"
      assert log =~ "iss=#{iss}"
      assert log =~ "exp=#{exp}"
    end

    test "expired jwt returns error no logs", %{tenant: tenant} do
      sub = random_string()

      api_key = Generators.generate_jwt_token(tenant)

      jwt =
        Generators.generate_jwt_token(tenant, %{role: "authenticated", exp: System.system_time(:second) - 1, sub: sub})

      assert {:ok, socket} = connect(UserSocket, %{}, conn_opts(tenant, api_key))

      log =
        capture_log(fn ->
          assert {:error, %{reason: "InvalidJWTToken: Token has expired " <> _}} =
                   subscribe_and_join(socket, "realtime:test", %{"access_token" => jwt})
        end)

      refute log =~ "InvalidJWTToken: Token has expired"
    end

    test "expired jwt returns a error with sub data if available log_level=warning", %{tenant: tenant} do
      sub = random_string()

      api_key = Generators.generate_jwt_token(tenant)

      jwt =
        Generators.generate_jwt_token(tenant, %{role: "authenticated", exp: System.system_time(:second) - 1, sub: sub})

      assert {:ok, socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, api_key))

      log =
        capture_log(fn ->
          assert {:error, %{reason: "InvalidJWTToken: Token has expired " <> _}} =
                   subscribe_and_join(socket, "realtime:test", %{"access_token" => jwt})
        end)

      assert log =~ "InvalidJWTToken: Token has expired"
      assert log =~ "sub=#{sub}"
    end
  end

  describe "API Key validations" do
    test "api_key has not expired", %{tenant: tenant} do
      api_key = Generators.generate_jwt_token(tenant)
      {:ok, %Socket{} = socket} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, api_key))

      assert {:ok, _, %Socket{}} = subscribe_and_join(socket, "realtime:test", %{})
    end

    test "api_key has expired", %{tenant: tenant} do
      assert capture_log(fn ->
               api_key =
                 Generators.generate_jwt_token(tenant, %{role: "authenticated", exp: System.system_time(:second)})

               assert {:error, :expired_token} =
                        connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, api_key))

               Process.sleep(300)
             end) =~ "InvalidJWTToken: Token has expired"

      api_key = Generators.generate_jwt_token(tenant, %{role: "authenticated", exp: System.system_time(:second) - 1})

      assert capture_log(fn ->
               assert {:error, :expired_token} =
                        connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, api_key))
             end) =~ "InvalidJWTToken: Token has expired"
    end

    test "missing role claims returns a error", %{tenant: tenant} do
      api_key = Generators.generate_jwt_token(tenant, %{exp: System.system_time(:second) + 1000})

      log =
        capture_log(fn ->
          assert {:error, :missing_claims} =
                   connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, api_key))
        end)

      assert log =~ "InvalidJWTToken: Fields `role` and `exp` are required in JWT"
    end

    test "missing exp claims returns a error", %{tenant: tenant} do
      api_key = Generators.generate_jwt_token(tenant, %{role: "authenticated"})

      log =
        capture_log(fn ->
          assert {:error, :missing_claims} =
                   connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, api_key))
        end)

      assert log =~ "InvalidJWTToken: Fields `role` and `exp` are required in JWT"
    end

    test "missing claims returns a error with token exp, iss and sub in metadata if available", %{tenant: tenant} do
      sub = random_string()
      iss = "https://#{random_string()}.com"
      exp = System.system_time(:second) + 10_000

      api_key = Generators.generate_jwt_token(tenant, %{exp: exp, sub: sub, iss: iss})

      log =
        capture_log(fn ->
          assert {:error, :missing_claims} =
                   connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, api_key))

          Process.sleep(300)
        end)

      assert log =~ "InvalidJWTToken: Fields `role` and `exp` are required in JWT"
      assert log =~ "sub=#{sub}"
      assert log =~ "iss=#{iss}"
      assert log =~ "exp=#{exp}"
    end

    test "expired api_key returns a error with sub data if available", %{tenant: tenant} do
      sub = random_string()

      api_key =
        Generators.generate_jwt_token(tenant, %{role: "authenticated", exp: System.system_time(:second) - 1, sub: sub})

      log =
        capture_log(fn ->
          assert {:error, :expired_token} = connect(UserSocket, %{"log_level" => "warning"}, conn_opts(tenant, api_key))

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

      assert {:error, %{reason: "UnableToConnectToProject: Realtime was unable to connect to the project database"}} =
               subscribe_and_join(socket, "realtime:test", %{"config" => %{"private" => true}})
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

      assert {:error,
              %{reason: "DatabaseLackOfConnections: Database can't accept more connections, Realtime won't connect"}} =
               subscribe_and_join(socket, "realtime:test", %{"config" => %{"private" => true}})
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

  defp assert_process_down(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end

  defp rls_context(%{tenant: tenant, policies: policies}) do
    {:ok, conn} = Realtime.Database.connect(tenant, "realtime_test", :stop)
    create_rls_policies(conn, policies, %{topic: "realtime:test"})
    :ok
  end

  defp rls_context(_), do: :ok
end
