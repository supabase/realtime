defmodule Realtime.Integration.RtChannel.PresenceTest do
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
  alias Realtime.Tenants.Connect

  @moduletag :capture_log

  setup [:checkout_tenant_and_connect]

  describe "public presence" do
    setup [:rls_context]

    test "public presence", %{tenant: tenant, serializer: serializer} do
      {socket, _} = get_connection(tenant, serializer)
      config = %{presence: %{key: "", enabled: true}, private: false}
      topic = "realtime:any"

      WebsocketClient.join(socket, topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 300
      assert_receive %Message{event: "presence_state", payload: %{}, topic: ^topic}, 500

      payload = %{
        type: "presence",
        event: "TRACK",
        payload: %{name: "realtime_presence_96", t: 1814.7000000029802}
      }

      WebsocketClient.send_event(socket, topic, "presence", payload)

      assert_receive %Message{event: "presence_diff", payload: %{"joins" => joins, "leaves" => %{}}, topic: ^topic}

      join_payload = joins |> Map.values() |> hd() |> get_in(["metas"]) |> hd()
      assert get_in(join_payload, ["name"]) == payload.payload.name
      assert get_in(join_payload, ["t"]) == payload.payload.t
    end

    test "presence enabled if param enabled is set in configuration for public channels", %{
      tenant: tenant,
      topic: topic,
      serializer: serializer
    } do
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
      topic = "realtime:#{topic}"

      WebsocketClient.join(socket, topic, %{config: %{private: false, presence: %{enabled: true}}})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state"}, 500
    end

    test "presence disabled if param 'enabled' is set to false in configuration for public channels", %{
      tenant: tenant,
      topic: topic,
      serializer: serializer
    } do
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
      topic = "realtime:#{topic}"

      WebsocketClient.join(socket, topic, %{config: %{private: false, presence: %{enabled: false}}})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      refute_receive %Message{event: "presence_state"}, 500
    end

    test "presence automatically enabled when user sends track message for public channel", %{
      tenant: tenant,
      serializer: serializer
    } do
      {socket, _} = get_connection(tenant, serializer)
      config = %{presence: %{key: "", enabled: false}, private: false}
      topic = "realtime:any"

      WebsocketClient.join(socket, topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 300
      refute_receive %Message{event: "presence_state"}, 500

      payload = %{
        type: "presence",
        event: "TRACK",
        payload: %{name: "realtime_presence_96", t: 1814.7000000029802}
      }

      WebsocketClient.send_event(socket, topic, "presence", payload)

      assert_receive %Message{event: "presence_diff", payload: %{"joins" => joins, "leaves" => %{}}, topic: ^topic}

      join_payload = joins |> Map.values() |> hd() |> get_in(["metas"]) |> hd()
      assert get_in(join_payload, ["name"]) == payload.payload.name
      assert get_in(join_payload, ["t"]) == payload.payload.t
    end
  end

  describe "private presence" do
    setup [:rls_context]

    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence]
    test "private presence with read and write permissions will be able to track and receive presence changes",
         %{tenant: tenant, topic: topic, serializer: serializer} do
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
      config = %{presence: %{key: "", enabled: true}, private: true}
      topic = "realtime:#{topic}"

      WebsocketClient.join(socket, topic, %{config: config})
      assert_receive %Message{event: "presence_state", payload: %{}, topic: ^topic}, 500

      payload = %{
        type: "presence",
        event: "TRACK",
        payload: %{name: "realtime_presence_96", t: 1814.7000000029802}
      }

      WebsocketClient.send_event(socket, topic, "presence", payload)
      refute_receive %Message{event: "phx_leave", topic: ^topic}
      assert_receive %Message{event: "presence_diff", payload: %{"joins" => joins, "leaves" => %{}}, topic: ^topic}, 500
      join_payload = joins |> Map.values() |> hd() |> get_in(["metas"]) |> hd()
      assert get_in(join_payload, ["name"]) == payload.payload.name
      assert get_in(join_payload, ["t"]) == payload.payload.t
    end

    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence],
         mode: :distributed
    test "private presence with read and write permissions will be able to track and receive presence changes using a remote node",
         %{tenant: tenant, topic: topic, serializer: serializer} do
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
      config = %{presence: %{key: "", enabled: true}, private: true}
      topic = "realtime:#{topic}"

      WebsocketClient.join(socket, topic, %{config: config})
      assert_receive %Message{event: "presence_state", payload: %{}, topic: ^topic}, 500

      payload = %{
        type: "presence",
        event: "TRACK",
        payload: %{name: "realtime_presence_96", t: 1814.7000000029802}
      }

      WebsocketClient.send_event(socket, topic, "presence", payload)
      refute_receive %Message{event: "phx_leave", topic: ^topic}
      assert_receive %Message{event: "presence_diff", payload: %{"joins" => joins, "leaves" => %{}}, topic: ^topic}, 500
      join_payload = joins |> Map.values() |> hd() |> get_in(["metas"]) |> hd()
      assert get_in(join_payload, ["name"]) == payload.payload.name
      assert get_in(join_payload, ["t"]) == payload.payload.t
    end

    @tag policies: [:authenticated_read_broadcast_and_presence]
    test "private presence with read permissions will be able to receive presence changes but won't be able to track",
         %{tenant: tenant, topic: topic, serializer: serializer} do
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
      {secondary_socket, _} = get_connection(tenant, serializer, role: "service_role")
      config = fn key -> %{presence: %{key: key, enabled: true}, private: true} end
      topic = "realtime:#{topic}"

      WebsocketClient.join(socket, topic, %{config: config.("authenticated")})

      payload = %{
        type: "presence",
        event: "TRACK",
        payload: %{name: "realtime_presence_96", t: 1814.7000000029802}
      }

      # This will be ignored
      WebsocketClient.send_event(socket, topic, "presence", payload)

      assert_receive %Message{topic: ^topic, event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state", payload: %{}, ref: nil, topic: ^topic}
      refute_receive %Message{event: "presence_diff", payload: _, ref: _, topic: ^topic}

      payload = %{
        type: "presence",
        event: "TRACK",
        payload: %{name: "realtime_presence_97", t: 1814.7000000029802}
      }

      # This will be tracked
      WebsocketClient.join(secondary_socket, topic, %{config: config.("service_role")})
      WebsocketClient.send_event(secondary_socket, topic, "presence", payload)

      assert_receive %Message{topic: ^topic, event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{topic: ^topic, event: "presence_diff", payload: %{"joins" => joins, "leaves" => %{}}}
      assert_receive %Message{event: "presence_state", payload: %{}, ref: nil, topic: ^topic}

      join_payload = joins |> Map.values() |> hd() |> get_in(["metas"]) |> hd()
      assert get_in(join_payload, ["name"]) == payload.payload.name
      assert get_in(join_payload, ["t"]) == payload.payload.t

      assert_receive %Message{topic: ^topic, event: "presence_diff"} = res

      assert join_payload =
               res
               |> Map.from_struct()
               |> get_in([:payload, "joins", "service_role", "metas"])
               |> hd()

      assert get_in(join_payload, ["name"]) == payload.payload.name
      assert get_in(join_payload, ["t"]) == payload.payload.t
    end

    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence]
    test "presence enabled if param enabled is set in configuration for private channels", %{
      tenant: tenant,
      topic: topic,
      serializer: serializer
    } do
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
      topic = "realtime:#{topic}"

      WebsocketClient.join(socket, topic, %{config: %{private: true, presence: %{enabled: true}}})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state"}, 500
    end

    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence]
    test "presence disabled if param 'enabled' is set to false in configuration for private channels", %{
      tenant: tenant,
      topic: topic,
      serializer: serializer
    } do
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
      topic = "realtime:#{topic}"

      WebsocketClient.join(socket, topic, %{config: %{private: true, presence: %{enabled: false}}})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      refute_receive %Message{event: "presence_state"}, 500
    end

    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence]
    test "presence automatically enabled when user sends track message for private channel",
         %{tenant: tenant, topic: topic, serializer: serializer} do
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
      config = %{presence: %{key: "", enabled: false}, private: true}
      topic = "realtime:#{topic}"

      WebsocketClient.join(socket, topic, %{config: config})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 300
      refute_receive %Message{event: "presence_state"}, 500

      payload = %{
        type: "presence",
        event: "TRACK",
        payload: %{name: "realtime_presence_96", t: 1814.7000000029802}
      }

      WebsocketClient.send_event(socket, topic, "presence", payload)

      assert_receive %Message{event: "presence_diff", payload: %{"joins" => joins, "leaves" => %{}}, topic: ^topic}, 500
      join_payload = joins |> Map.values() |> hd() |> get_in(["metas"]) |> hd()
      assert get_in(join_payload, ["name"]) == payload.payload.name
      assert get_in(join_payload, ["t"]) == payload.payload.t
    end
  end

  describe "database connection errors" do
    setup [:rls_context]

    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence]
    test "handles lack of connection to database error on private channels", %{
      tenant: tenant,
      topic: topic,
      serializer: serializer
    } do
      topic = "realtime:#{topic}"
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
      WebsocketClient.join(socket, topic, %{config: %{private: true, presence: %{enabled: true}}})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 300
      assert_receive %Message{event: "presence_state"}

      log =
        capture_log(fn ->
          :syn.update_registry(Connect, tenant.external_id, fn _pid, meta -> %{meta | conn: nil} end)
          payload = %{type: "presence", event: "TRACK", payload: %{name: "realtime_presence_96", t: 1814.7000000029802}}
          WebsocketClient.send_event(socket, topic, "presence", payload)

          refute_receive %Message{event: "presence_diff"}, 500
          # Waiting more than 5 seconds as this is the amount of time we will wait for the Connection to be ready
          refute_receive %Message{event: "phx_leave", topic: ^topic}, 16000
        end)

      assert log =~ ~r/external_id=#{tenant.external_id}.*UnableToHandlePresence/
    end

    @tag policies: []
    test "lack of connection to database error does not impact public channels", %{
      tenant: tenant,
      topic: topic,
      serializer: serializer
    } do
      topic = "realtime:#{topic}"
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
      WebsocketClient.join(socket, topic, %{config: %{private: false, presence: %{enabled: true}}})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 300
      assert_receive %Message{event: "presence_state"}

      log =
        capture_log(fn ->
          :syn.update_registry(Connect, tenant.external_id, fn _pid, meta -> %{meta | conn: nil} end)
          payload = %{type: "presence", event: "TRACK", payload: %{name: "realtime_presence_96", t: 1814.7000000029802}}
          WebsocketClient.send_event(socket, topic, "presence", payload)

          assert_receive %Message{event: "presence_diff"}, 500
          refute_receive %Message{event: "phx_leave", topic: ^topic}
        end)

      refute log =~ ~r/external_id=#{tenant.external_id}.*UnableToHandlePresence/
    end
  end
end
