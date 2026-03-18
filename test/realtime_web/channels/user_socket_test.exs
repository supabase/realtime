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
