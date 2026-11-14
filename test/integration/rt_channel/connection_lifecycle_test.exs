defmodule Realtime.Integration.RtChannel.ConnectionLifecycleTest do
  use RealtimeWeb.ConnCase,
    async: true,
    parameterize: [
      %{serializer: Phoenix.Socket.V1.JSONSerializer},
      %{serializer: RealtimeWeb.Socket.V2Serializer}
    ]

  import ExUnit.CaptureLog
  import Generators

  alias Forum.Muster
  alias Phoenix.Socket.Message
  alias Realtime.Integration.WebsocketClient
  alias Realtime.Tenants
  alias Realtime.Tenants.Connect
  alias RealtimeWeb.UserSocket

  @moduletag :capture_log

  @service_restart_close_code 1012
  @going_away_close_code 1001

  setup [:checkout_tenant]

  describe "socket connect - tenant not found" do
    test "logs TenantNotFound and rejects connection for unknown external_id", %{serializer: serializer} do
      external_id = "nonexistent-#{System.unique_integer([:positive])}"
      fake_tenant = %{external_id: external_id}
      # Our code does not store values that are not Tenant structs
      # but we do it here to avoid an Ecto.Sandbox issue due to the async tests
      # Because Cachex.fetch will try to call the DB when there is no cached information
      Cachex.put(Realtime.Tenants.Cache, {:get_tenant_by_external_id, external_id}, {:error, :not_found})

      log =
        capture_log(fn ->
          assert {:error, %Mint.WebSocket.UpgradeFailureError{status_code: 404}} =
                   WebsocketClient.connect(self(), uri(fake_tenant, serializer), serializer, [
                     {"x-api-key", "some-token"}
                   ])
        end)

      assert log =~ "TenantNotFound"
    end
  end

  describe "socket connect - missing api key" do
    test "logs MissingAPIKey and rejects connection when no token provided", %{tenant: tenant, serializer: serializer} do
      log =
        capture_log(fn ->
          assert {:error, %Mint.WebSocket.UpgradeFailureError{status_code: 401}} =
                   WebsocketClient.connect(self(), uri(tenant, serializer), serializer, [])
        end)

      assert log =~ "MissingAPIKey"
    end
  end

  describe "socket connect - malformed token" do
    test "logs MalformedJWT and rejects connection with a 401", %{tenant: tenant, serializer: serializer} do
      log =
        capture_log(fn ->
          assert {:error, %Mint.WebSocket.UpgradeFailureError{status_code: 401}} =
                   WebsocketClient.connect(self(), uri(tenant, serializer), serializer, [
                     {"x-api-key", "not-a-jwt"}
                   ])
        end)

      assert log =~ "MalformedJWT"
    end
  end

  describe "replication connection establishment" do
    test "Connect signals replication readiness on its syn topic with the replication_conn pid" do
      tenant = TestTenantDb.checkout_tenant(run_migrations: true)

      Phoenix.PubSub.subscribe(Realtime.PubSub, Connect.syn_topic(tenant.external_id))
      {:ok, _db_conn} = Connect.lookup_or_start_connection(tenant.external_id)

      assert_receive %Phoenix.Socket.Broadcast{event: "ready", payload: %{replication_conn: replication_conn}}
                     when is_pid(replication_conn),
                     5000

      assert {:ok, ^replication_conn} = Connect.replication_status(tenant.external_id)
    end

    test "clients that opt in receive the replication established system message, even after streaming has started",
         %{serializer: serializer} do
      tenant = TestTenantDb.checkout_tenant(run_migrations: true)

      Phoenix.PubSub.subscribe(Realtime.PubSub, Connect.syn_topic(tenant.external_id))
      {:ok, _db_conn} = Connect.lookup_or_start_connection(tenant.external_id)

      assert_receive %Phoenix.Socket.Broadcast{event: "ready", payload: %{replication_conn: replication_conn}}
                     when is_pid(replication_conn),
                     5000

      {socket1, _} = get_connection(tenant, serializer, role: "authenticated")
      {socket2, _} = get_connection(tenant, serializer, role: "authenticated")

      config = %{broadcast: %{self: true, replication_ready: true}, private: false}
      topic1 = "realtime:#{random_string()}"
      topic2 = "realtime:#{random_string()}"

      WebsocketClient.join(socket1, topic1, %{config: config})
      WebsocketClient.join(socket2, topic2, %{config: config})

      assert_receive %Message{event: "phx_reply", topic: ^topic1, payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "phx_reply", topic: ^topic2, payload: %{"status" => "ok"}}, 500

      assert_receive %Message{
                       event: "system",
                       topic: ^topic1,
                       payload: %{"message" => "Replication connection established"}
                     },
                     2000

      assert_receive %Message{
                       event: "system",
                       topic: ^topic2,
                       payload: %{"message" => "Replication connection established"}
                     },
                     2000
    end
  end

  describe "socket disconnect - tenant suspension" do
    setup [:rls_context]

    test "tenant already suspended", %{tenant: tenant, serializer: serializer} do
      log =
        capture_log(fn ->
          change_tenant_configuration(tenant, :suspend, true)

          {:error, %Mint.WebSocket.UpgradeFailureError{status_code: 403}} =
            get_connection(tenant, serializer, role: "anon")

          refute_receive _any
        end)

      assert log =~ "RealtimeDisabledForTenant"
    end

    test "connected socket is closed and cannot reconnect", %{tenant: tenant, topic: topic, serializer: serializer} do
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: %{broadcast: %{self: true}, private: false}})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500

      {:ok, _} = Realtime.Api.update_tenant_by_external_id(tenant.external_id, %{suspend: true})

      assert_receive {:close_code, @service_restart_close_code}, 1000
      assert_process_down(socket)

      assert {:error, %Mint.WebSocket.UpgradeFailureError{status_code: 403}} =
               get_connection(tenant, serializer, role: "authenticated")
    end

    test "socket that does not drain is killed", %{tenant: tenant, topic: topic, serializer: serializer} do
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: %{broadcast: %{self: true}, private: false}})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500

      # A suspended transport never handles the drain, like one that is stuck or missed the broadcast
      [{transport_pid, _}] = Registry.lookup(Realtime.PubSub, UserSocket.subscribers_id(tenant.external_id))
      :ok = :sys.suspend(transport_pid)
      ref = Process.monitor(transport_pid)

      {:ok, _} = Realtime.Api.update_tenant_by_external_id(tenant.external_id, %{suspend: true})

      assert_receive {:DOWN, ^ref, :process, ^transport_pid, :killed}, 1000
      assert_process_down(socket)
      refute_received {:close_code, _}
    end
  end

  describe "socket disconnect - configuration changes" do
    setup [:rls_context]

    test "on jwks the socket closes and sends a system message", %{tenant: tenant, topic: topic, serializer: serializer} do
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500

      Realtime.Api.update_tenant_by_external_id(tenant.external_id, %{jwt_jwks: %{keys: ["potato"]}})

      assert_receive {:close_code, @service_restart_close_code}, 1000

      assert_process_down(socket)
    end

    test "on jwt_secret the socket closes and sends a system message", %{
      tenant: tenant,
      topic: topic,
      serializer: serializer
    } do
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500

      Realtime.Api.update_tenant_by_external_id(tenant.external_id, %{jwt_secret: "potato"})

      assert_receive {:close_code, @service_restart_close_code}, 1000

      assert_process_down(socket)
    end

    test "on private_only the socket closes and sends a system message", %{
      tenant: tenant,
      topic: topic,
      serializer: serializer
    } do
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500

      Realtime.Api.update_tenant_by_external_id(tenant.external_id, %{private_only: true})

      assert_receive {:close_code, @service_restart_close_code}, 1000

      assert_process_down(socket)
    end

    test "on other param changes the socket won't close and no message is sent", %{
      tenant: tenant,
      topic: topic,
      serializer: serializer
    } do
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500

      Realtime.Api.update_tenant_by_external_id(tenant.external_id, %{max_concurrent_users: 100})

      refute_receive %Message{
                       topic: ^realtime_topic,
                       event: "system",
                       payload: %{
                         "extension" => "system",
                         "message" => "Server requested disconnect",
                         "status" => "ok"
                       }
                     },
                     500

      assert :ok = WebsocketClient.send_heartbeat(socket)
      refute_receive {:close_code, @service_restart_close_code}
    end
  end

  describe "socket disconnect - token expiry" do
    setup [:rls_context]

    test "invalid JWT with expired token", %{tenant: tenant, serializer: serializer} do
      log =
        capture_log(fn ->
          assert {:error, %Mint.WebSocket.UpgradeFailureError{status_code: 401}} =
                   get_connection(tenant, serializer,
                     role: "authenticated",
                     claims: %{:exp => System.system_time(:second) - 1000},
                     params: %{log_level: :info}
                   )
        end)

      assert log =~ "InvalidJWTToken: Token has expired"
    end
  end

  describe "socket disconnect" do
    setup [:rls_context]

    test "on disconnect called, socket is killed", %{
      tenant: tenant,
      serializer: serializer
    } do
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
      config = %{broadcast: %{self: true}, private: false}

      topics =
        for i <- 1..10 do
          topic = "realtime:#{serializer}:#{i}"
          WebsocketClient.join(socket, topic, %{config: config})

          assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 500
          topic
        end

      assert :ok = WebsocketClient.send_heartbeat(socket)
      # heartbeat reply
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: "phoenix"}, 500

      UserSocket.disconnect(tenant.external_id)

      for topic <- topics do
        assert_receive %Message{
                         topic: ^topic,
                         event: "system",
                         payload: %{
                           "extension" => "system",
                           "message" => "Server requested disconnect",
                           "status" => "ok"
                         }
                       },
                       5000
      end

      assert_receive {:close_code, @service_restart_close_code}, 1000
      refute_receive _any

      assert_process_down(socket, 1000)
    end
  end

  describe "socket disconnect - tenant deleted during session" do
    setup [:rls_context]

    test "sends disconnect to socket when tenant not found during channel join", %{
      tenant: tenant,
      topic: topic,
      serializer: serializer
    } do
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500

      Cachex.put(Realtime.Tenants.Cache, {:get_tenant_by_external_id, tenant.external_id}, {:error, :not_found})

      realtime_topic_2 = "realtime:#{random_string()}"
      WebsocketClient.join(socket, realtime_topic_2, %{config: config})

      assert_receive {:close_code, @going_away_close_code}, 1000

      assert_process_down(socket, 1000)
    end
  end

  describe "rate limits - concurrent users" do
    setup [:rls_context]

    test "max_concurrent_users limit respected", %{tenant: tenant, serializer: serializer} do
      Tenants.get_tenant_by_external_id(tenant.external_id)
      change_tenant_configuration(tenant, :max_concurrent_users, 1)

      {socket1, _} = get_connection(tenant, serializer, role: "authenticated")
      {socket2, _} = get_connection(tenant, serializer, role: "authenticated")
      config = %{broadcast: %{self: true}, private: false}
      topic1 = "realtime:#{random_string()}"
      topic2 = "realtime:#{random_string()}"
      WebsocketClient.join(socket1, topic1, %{config: config})
      WebsocketClient.join(socket1, topic2, %{config: config})

      assert_receive %Message{
                       event: "phx_reply",
                       topic: ^topic1,
                       payload: %{"response" => %{"postgres_changes" => []}, "status" => "ok"}
                     },
                     500

      assert_receive %Message{
                       event: "phx_reply",
                       topic: ^topic2,
                       payload: %{"response" => %{"postgres_changes" => []}, "status" => "ok"}
                     },
                     500

      topic3 = "realtime:#{random_string()}"
      WebsocketClient.join(socket2, topic3, %{config: config})

      assert_receive %Message{
                       event: "phx_reply",
                       topic: ^topic3,
                       payload: %{
                         "response" => %{
                           "reason" => "ConnectionRateLimitReached: Too many connected users"
                         },
                         "status" => "error"
                       }
                     },
                     500

      Realtime.Tenants.Cache.update_cache(%{tenant | max_concurrent_users: 2})

      WebsocketClient.join(socket2, topic3, %{config: config})

      assert_receive %Message{
                       event: "phx_reply",
                       topic: ^topic3,
                       payload: %{"response" => %{"postgres_changes" => []}, "status" => "ok"}
                     },
                     500
    end
  end

  describe "rate limits - events per second" do
    setup [:rls_context]

    test "max_events_per_second limit respected", %{tenant: tenant, serializer: serializer} do
      RateCounterHelper.stop(tenant.external_id)

      log =
        capture_log(fn ->
          {socket, _} = get_connection(tenant, serializer, role: "authenticated")
          config = %{broadcast: %{self: true, ack: false}, private: false, presence: %{enabled: false}}
          realtime_topic = "realtime:#{random_string()}"

          WebsocketClient.join(socket, realtime_topic, %{config: config})
          assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^realtime_topic}, 500

          for _ <- 1..1000, Process.alive?(socket) do
            WebsocketClient.send_event(socket, realtime_topic, "broadcast", %{})
            assert_receive %Message{event: "broadcast", topic: ^realtime_topic}, 500
          end

          RateCounterHelper.tick_tenant_rate_counters!(tenant.external_id)

          WebsocketClient.send_event(socket, realtime_topic, "broadcast", %{})

          assert_receive %Message{event: "phx_close"}, 1000
        end)

      assert log =~ "MessagePerSecondRateLimitReached"
    end
  end

  describe "rate limits - channels per client" do
    setup [:rls_context]

    test "max_channels_per_client limit respected", %{tenant: tenant, serializer: serializer} do
      change_tenant_configuration(tenant, :max_channels_per_client, 1)

      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic_1 = "realtime:#{random_string()}"
      realtime_topic_2 = "realtime:#{random_string()}"

      WebsocketClient.join(socket, realtime_topic_1, %{config: config})
      WebsocketClient.join(socket, realtime_topic_2, %{config: config})

      assert_receive %Message{
                       event: "phx_reply",
                       payload: %{"response" => %{"postgres_changes" => []}, "status" => "ok"},
                       topic: ^realtime_topic_1
                     },
                     500

      assert_receive %Message{
                       event: "phx_reply",
                       payload: %{
                         "status" => "error",
                         "response" => %{
                           "reason" => "ChannelRateLimitReached: Too many channels"
                         }
                       },
                       topic: ^realtime_topic_2
                     },
                     500

      refute_receive %Message{event: "phx_reply", topic: ^realtime_topic_2}, 500

      Realtime.Tenants.Cache.update_cache(%{tenant | max_channels_per_client: 2})

      WebsocketClient.join(socket, realtime_topic_2, %{config: config})

      assert_receive %Message{
                       event: "phx_reply",
                       payload: %{"response" => %{"postgres_changes" => []}, "status" => "ok"},
                       topic: ^realtime_topic_2
                     },
                     500
    end

    test "a channel that is left frees its slot", %{tenant: tenant, serializer: serializer} do
      change_tenant_configuration(tenant, :max_channels_per_client, 1)
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")

      topic = join_channel!(socket)
      :ok = WebsocketClient.leave(socket, topic, %{})
      assert_receive %Message{event: "phx_close", topic: ^topic}, 500

      join_channel!(socket)
    end

    test "a channel that crashes frees its slot", %{tenant: tenant, serializer: serializer} do
      change_tenant_configuration(tenant, :max_channels_per_client, 1)
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")

      topic = join_channel!(socket)

      [%{pid: transport}] =
        Enum.filter(Phoenix.Debug.list_sockets(), &(&1.id == UserSocket.subscribers_id(tenant.external_id)))

      {:ok, [%{pid: channel_pid}]} = Phoenix.Debug.list_channels(transport)
      Process.exit(channel_pid, :kill)
      assert_receive %Message{event: "phx_error", topic: ^topic}, 500

      join_channel!(socket)
    end

    test "rejoining a topic replaces its channel instead of taking another slot", %{
      tenant: tenant,
      serializer: serializer
    } do
      change_tenant_configuration(tenant, :max_channels_per_client, 2)
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")

      topic = join_channel!(socket)
      ^topic = join_channel!(socket, topic)
      join_channel!(socket)

      assert_channel_limit_reached(socket)
    end

    test "each socket has its own limit", %{tenant: tenant, serializer: serializer} do
      change_tenant_configuration(tenant, :max_channels_per_client, 1)
      {socket1, _} = get_connection(tenant, serializer, role: "authenticated")
      {socket2, _} = get_connection(tenant, serializer, role: "authenticated")

      join_channel!(socket1)
      join_channel!(socket2)

      assert_channel_limit_reached(socket1)
      assert_channel_limit_reached(socket2)
    end
  end

  describe "rate limits - joins per second" do
    setup [:rls_context]

    test "max_joins_per_second limit respected", %{tenant: tenant, serializer: serializer} do
      # The joins counter starts on connect and ticks on its own every 5s, averaging over the buckets so far.
      # A low limit keeps the join loop far shorter than that tick so only the manual tick below evaluates it:
      # buckets [20, 0] average to 20 / 2 / 5s = 2 joins per second.
      # CI used to struggle trying to go over the higher limit within the 5 seconds.
      change_tenant_configuration(tenant, :max_joins_per_second, 1)
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{random_string()}"

      log =
        capture_log(fn ->
          for _ <- 1..20 do
            WebsocketClient.join(socket, realtime_topic, %{config: config})
            assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^realtime_topic}, 500
          end

          RateCounterHelper.tick_tenant_rate_counters!(tenant.external_id)

          WebsocketClient.join(socket, realtime_topic, %{config: config})
          assert_process_down(socket)
        end)

      assert log =~
               "project=#{tenant.external_id} external_id=#{tenant.external_id} [critical] ClientJoinRateLimitReached: Too many joins per second"

      assert length(String.split(log, "ClientJoinRateLimitReached")) <= 3
    end
  end

  describe "rate limits - node join budget" do
    setup [:rls_context]

    test "refuses joins over the tenant's budget on the node and keeps the socket connected", %{
      tenant: tenant,
      serializer: serializer
    } do
      enable_tenant_flag!(tenant, "node_join_budget")
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
      config = %{broadcast: %{self: true}, private: false}
      [topic_1 | _] = topics = for _ <- 1..50, do: "realtime:#{random_string()}"

      for topic <- topics, do: WebsocketClient.join(socket, topic, %{config: config})

      replies =
        for topic <- topics do
          assert_receive %Message{event: "phx_reply", payload: %{"status" => status} = reply, topic: ^topic}, 10_000
          {status, reply["response"]}
        end

      # config/test.exs makes the budget max(10, 2 * sockets) joins per second with a 2 second burst, so with one socket
      # the first 20 joins always fit and the rest outrun the refill of 10 per second
      refused = {"error", %{"reason" => "JoinsRateLimitReached: Too many joins per second"}}
      {first_20, rest} = Enum.split(replies, 20)
      assert Enum.all?(first_20, &match?({"ok", _}, &1))
      assert Enum.all?(rest, &(match?({"ok", _}, &1) or &1 == refused))
      refused_count = Enum.count(rest, &(&1 == refused))
      assert refused_count in 1..30
      assert node_join_budget_exceeded(tenant) == refused_count

      payload = %{"event" => "TEST", "payload" => %{"msg" => 1}, "type" => "broadcast"}
      WebsocketClient.send_event(socket, topic_1, "broadcast", payload)
      assert_receive %Message{event: "broadcast", payload: ^payload, topic: ^topic_1}, 500
    end

    test "refuses new connections while the tenant's budget on the node is used up", %{
      tenant: tenant,
      serializer: serializer
    } do
      enable_tenant_flag!(tenant, "node_join_budget")
      future = System.monotonic_time(:microsecond) + 60_000_000
      Stream.repeatedly(fn -> Realtime.Tenants.NodeJoinBudget.take(tenant, future) end) |> Enum.find(&(&1 == :error))

      log =
        capture_log(fn ->
          assert {:error, %Mint.WebSocket.UpgradeFailureError{status_code: 429}} =
                   get_connection(tenant, serializer, role: "authenticated")
        end)

      assert log =~ "JoinsRateLimitReached"
    end
  end

  describe "rate limits - joins per socket" do
    setup [:rls_context]

    test "rejects joins past the socket's burst and keeps the socket connected", %{
      tenant: tenant,
      serializer: serializer
    } do
      # The burst is the tenant's channel cap
      change_tenant_configuration(tenant, :max_channels_per_client, 10)
      enable_tenant_flag!(tenant, "socket_join_limit")
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
      config = %{broadcast: %{self: true}, private: false}
      [topic_1 | _] = topics = for _ <- 1..30, do: "realtime:#{random_string()}"

      for topic <- topics, do: WebsocketClient.join(socket, topic, %{config: config})

      replies =
        for topic <- topics do
          assert_receive %Message{event: "phx_reply", payload: %{"status" => status} = reply, topic: ^topic}, 5_000
          {status, reply["response"]}
        end

      # The first 10 joins use the burst. The 20 sent right after them would need 10 seconds of refill at the 2 joins
      # per second of config/test.exs to all pass the bucket, and the ones that pass hit the channel cap instead
      rejected = {"error", %{"reason" => "SocketJoinRateLimitReached: Too many joins on this socket"}}
      too_many_channels = {"error", %{"reason" => "ChannelRateLimitReached: Too many channels"}}
      {first_10, rest} = Enum.split(replies, 10)
      assert Enum.all?(first_10, &match?({"ok", _}, &1))
      assert rejected in rest
      assert Enum.all?(rest, &(&1 in [rejected, too_many_channels]))

      payload = %{"event" => "TEST", "payload" => %{"msg" => 1}, "type" => "broadcast"}
      WebsocketClient.send_event(socket, topic_1, "broadcast", payload)
      assert_receive %Message{event: "broadcast", payload: ^payload, topic: ^topic_1}, 500
    end
  end

  describe "Muster channel join" do
    setup [:rls_context]

    test "registers the joined socket in the real Muster scope", %{
      tenant: tenant,
      serializer: serializer
    } do
      scope = Application.fetch_env!(:realtime, :muster_scope)
      group = tenant.external_id

      # Nothing has joined this tenant's group yet.
      assert Muster.local_member_count(scope, group) == 0

      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
      topic = "realtime:#{random_string()}"
      WebsocketClient.join(socket, topic, %{config: %{broadcast: %{self: false}, private: false}})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 500

      # Once we get the reply for the join we 100% sure that the join has been registered
      assert Muster.local_member_count(scope, group) == 1
      assert [pid] = Muster.local_members(scope, group)
      assert Muster.local_member?(scope, group, pid)
      assert Muster.targets(scope, group, Muster.view_hash(scope)) == {:ok, [node()]}
    end
  end

  # Regression guard for REAL-981: Phoenix 1.8.3 started dropping channel pushes
  # without a join_ref, which broke SDK clients that omit it. Phoenix 1.8.12 fixed
  # that (phoenixframework/phoenix#6800); pushes with a stale join_ref are still
  # dropped by design.
  describe "join_ref leniency" do
    test "presence track still gets a reply and diff with a missing join_ref", %{
      tenant: tenant,
      serializer: serializer
    } do
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
      topic = "realtime:#{random_string()}"
      config = %{presence: %{key: "", enabled: true}, private: false}

      WebsocketClient.join(socket, topic, %{config: config})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 500
      assert_receive %Message{event: "presence_state", topic: ^topic}, 500

      missing = %{type: "presence", event: "TRACK", payload: %{name: "missing-join-ref"}}
      send_raw(socket, serializer, topic, "presence", missing, "1002", nil)

      assert_receive %Message{event: "phx_reply", ref: "1002", payload: %{"status" => "ok"}, topic: ^topic}, 500
      assert_receive %Message{event: "presence_diff", topic: ^topic}, 500
    end

    test "acknowledged broadcast still gets a reply with a missing join_ref", %{
      tenant: tenant,
      serializer: serializer
    } do
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
      topic = "realtime:#{random_string()}"
      config = %{broadcast: %{self: true, ack: true}, private: false}

      WebsocketClient.join(socket, topic, %{config: config})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 500

      broadcast = %{"event" => "TEST", "payload" => %{"msg" => 1}, "type" => "broadcast"}

      send_raw(socket, serializer, topic, "broadcast", broadcast, "2002", nil)
      assert_receive %Message{event: "phx_reply", ref: "2002", payload: %{"status" => "ok"}, topic: ^topic}, 500
      assert_receive %Message{event: "broadcast", payload: ^broadcast, topic: ^topic}, 500
    end
  end

  # Bypasses WebsocketClient's automatic join_ref tracking to simulate a client
  # pushing with a missing (nil) join_ref after a valid join.
  defp send_raw(socket, serializer, topic, event, payload, ref, join_ref) do
    msg = %Message{topic: topic, event: event, payload: payload, ref: ref, join_ref: join_ref}
    {:socket_push, :text, chardata} = serializer.encode!(msg)
    WebsocketClient.send(socket, {:text, IO.chardata_to_string(chardata)})
  end

  defp join_channel!(socket, topic \\ "realtime:#{random_string()}") do
    :ok = WebsocketClient.join(socket, topic, %{config: %{broadcast: %{self: true}, private: false}})
    assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 500
    topic
  end

  defp assert_channel_limit_reached(socket) do
    topic = "realtime:#{random_string()}"
    :ok = WebsocketClient.join(socket, topic, %{config: %{broadcast: %{self: true}, private: false}})

    assert_receive %Message{
                     event: "phx_reply",
                     payload: %{
                       "status" => "error",
                       "response" => %{"reason" => "ChannelRateLimitReached: Too many channels"}
                     },
                     topic: ^topic
                   },
                   500
  end

  # The flag is created disabled and enabled only for this tenant, so it does not leak into other tests
  defp enable_tenant_flag!(tenant, name) do
    {:ok, flag} = Realtime.Api.upsert_feature_flag(%{name: name, enabled: false})
    Realtime.FeatureFlags.Cache.update_cache(flag)
    {:ok, tenant} = Realtime.FeatureFlags.set_tenant_flag(name, tenant.external_id, true)
    Tenants.Cache.update_cache(tenant)
    on_exit(fn -> Realtime.FeatureFlags.Cache.invalidate_cache(name) end)
  end

  defp node_join_budget_exceeded(tenant) do
    Realtime.TenantPromEx
    |> PromEx.get_metrics()
    |> MetricsHelper.search("realtime_channel_node_join_budget_exceeded", tenant: tenant.external_id)
  end
end
