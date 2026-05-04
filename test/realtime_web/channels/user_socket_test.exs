defmodule RealtimeWeb.UserSocketTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias RealtimeWeb.Socket.V2Serializer
  alias RealtimeWeb.UserSocket

  @socket %Phoenix.Socket{
    serializer: V2Serializer,
    assigns: %{tenant: "test-tenant", access_token: "test-token", log_level: :error}
  }
  @state {%{channels: %{}, channels_inverse: %{}}, @socket}

  describe "disconnect/1" do
    test "returns :ok" do
      assert :ok = UserSocket.disconnect("tenant-disconnect-ok")
    end

    test "broadcasts socket drain to subscribers topic" do
      tenant_id = "tenant-disconnect-drain"
      Phoenix.PubSub.subscribe(Realtime.PubSub, UserSocket.subscribers_id(tenant_id))

      UserSocket.disconnect(tenant_id)

      assert_receive :socket_drain
    end

    test "broadcasts system disconnect message to operations topic" do
      tenant_id = "tenant-disconnect-ops"
      Phoenix.PubSub.subscribe(Realtime.PubSub, "realtime:operations:" <> tenant_id)

      UserSocket.disconnect(tenant_id)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "system",
        payload: %{extension: "system", status: "ok", message: "Server requested disconnect"}
      }
    end

    test "logs a warning with tenant id" do
      tenant_id = "tenant-disconnect-log"

      log =
        capture_log(fn ->
          UserSocket.disconnect(tenant_id)
        end)

      assert log =~ "Disconnecting all sockets for tenant #{tenant_id}"
    end
  end

  describe "handle_in/2 with invalid messages" do
    test "does not crash and logs when message is an array with not enough items" do
      raw = Jason.encode!(["join_ref", "ref", "topic"])

      log =
        capture_log(fn ->
          assert {:ok, @state} = UserSocket.handle_in({raw, [opcode: :text]}, @state)
        end)

      assert log =~ "MalformedWebSocketMessage"
    end

    test "does not crash and logs when message is a map" do
      raw = Jason.encode!(%{"topic" => "t", "event" => "e", "payload" => %{}})

      log =
        capture_log(fn ->
          assert {:ok, @state} = UserSocket.handle_in({raw, [opcode: :text]}, @state)
        end)

      assert log =~ "MalformedWebSocketMessage"
    end

    test "does not crash and logs when message is empty string" do
      log =
        capture_log(fn ->
          assert {:ok, @state} = UserSocket.handle_in({"", [opcode: :text]}, @state)
        end)

      assert log =~ "MalformedWebSocketMessage"
    end

    test "does not crash and logs when message is invalid JSON" do
      log =
        capture_log(fn ->
          assert {:ok, @state} = UserSocket.handle_in({"not json", [opcode: :text]}, @state)
        end)

      assert log =~ "MalformedWebSocketMessage"
    end

    test "does not crash and logs on unexpected errors" do
      log =
        capture_log(fn ->
          assert {:ok, @state} = UserSocket.handle_in({:not_a_binary, [opcode: :text]}, @state)
        end)

      assert log =~ "UnknownErrorOnWebSocketMessage"
    end
  end
end
