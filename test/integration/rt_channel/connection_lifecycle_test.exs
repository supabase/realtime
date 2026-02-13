defmodule Realtime.Integration.RtChannel.ConnectionLifecycleTest do
  use RealtimeWeb.ConnCase,
    async: true,
    parameterize: [
      %{serializer: Phoenix.Socket.V1.JSONSerializer},
      %{serializer: RealtimeWeb.Socket.V2Serializer}
    ]

  import ExUnit.CaptureLog
  import Generators

  alias Phoenix.Socket.Message
  alias Realtime.Integration.WebsocketClient
  alias Realtime.Tenants
  alias RealtimeWeb.SocketDisconnect

  @moduletag :capture_log

  setup [:checkout_tenant_and_connect]

  describe "socket disconnect - tenant suspension" do
    setup [:rls_context]

    test "tenant already suspended", %{tenant: tenant, serializer: serializer} do
      log =
        capture_log(fn ->
          change_tenant_configuration(tenant, :suspend, true)
          {:error, %Mint.WebSocket.UpgradeFailureError{}} = get_connection(tenant, serializer, role: "anon")
          refute_receive _any
        end)

      assert log =~ "RealtimeDisabledForTenant"
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
      assert_receive %Message{event: "presence_state"}, 500

      Realtime.Api.update_tenant_by_external_id(tenant.external_id, %{jwt_jwks: %{keys: ["potato"]}})
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
      assert_receive %Message{event: "presence_state"}, 500

      Realtime.Api.update_tenant_by_external_id(tenant.external_id, %{jwt_secret: "potato"})
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
      assert_receive %Message{event: "presence_state"}, 500

      Realtime.Api.update_tenant_by_external_id(tenant.external_id, %{private_only: true})
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
      assert_receive %Message{event: "presence_state"}, 500

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

      Process.sleep(500)
      assert :ok = WebsocketClient.send_heartbeat(socket)
    end
  end

  describe "socket disconnect - token expiry" do
    setup [:rls_context]

    test "invalid JWT with expired token", %{tenant: tenant, serializer: serializer} do
      log =
        capture_log(fn ->
          get_connection(tenant, serializer,
            role: "authenticated",
            claims: %{:exp => System.system_time(:second) - 1000},
            params: %{log_level: :info}
          )
        end)

      assert log =~ "InvalidJWTToken: Token has expired"
    end
  end

  describe "socket disconnect - distributed disconnect" do
    setup [:rls_context]

    test "check registry of SocketDisconnect and on distribution called, kill socket", %{
      tenant: tenant,
      serializer: serializer
    } do
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
      config = %{broadcast: %{self: true}, private: false}

      for _ <- 1..10 do
        topic = "realtime:#{random_string()}"
        WebsocketClient.join(socket, topic, %{config: config})

        assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 500
        assert_receive %Message{event: "presence_state", topic: ^topic}, 500
      end

      assert :ok = WebsocketClient.send_heartbeat(socket)

      SocketDisconnect.distributed_disconnect(tenant.external_id)

      assert_process_down(socket)
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

      assert_receive %Message{event: "presence_state", topic: ^realtime_topic_1}, 500

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
      refute_receive %Message{event: "presence_state", topic: ^realtime_topic_2}, 500

      Realtime.Tenants.Cache.update_cache(%{tenant | max_channels_per_client: 2})

      WebsocketClient.join(socket, realtime_topic_2, %{config: config})

      assert_receive %Message{
                       event: "phx_reply",
                       payload: %{"response" => %{"postgres_changes" => []}, "status" => "ok"},
                       topic: ^realtime_topic_2
                     },
                     500
    end
  end

  describe "rate limits - joins per second" do
    setup [:rls_context]

    test "max_joins_per_second limit respected", %{tenant: tenant, serializer: serializer} do
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{random_string()}"

      log =
        capture_log(fn ->
          for _ <- 1..300 do
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
end
