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
    test "does not crash and logs when message is missing ref" do
      raw = Jason.encode!(%{"topic" => "t", "event" => "e", "payload" => %{}})

      log =
        capture_log(fn ->
          assert {:ok, @state} = UserSocket.handle_in({raw, [opcode: :text]}, @state)
        end)

      assert log =~ "MalformedWebSocketMessage"
    end

    test "does not crash and logs when message is missing topic" do
      raw = Jason.encode!(%{"event" => "e", "payload" => %{}, "ref" => "1"})

      log =
        capture_log(fn ->
          assert {:ok, @state} = UserSocket.handle_in({raw, [opcode: :text]}, @state)
        end)

      assert log =~ "MalformedWebSocketMessage"
    end

    test "does not crash and logs when message is missing event" do
      raw = Jason.encode!(%{"topic" => "t", "payload" => %{}, "ref" => "1"})

      log =
        capture_log(fn ->
          assert {:ok, @state} = UserSocket.handle_in({raw, [opcode: :text]}, @state)
        end)

      assert log =~ "MalformedWebSocketMessage"
    end
  end
end
