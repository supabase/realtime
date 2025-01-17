defmodule Realtime.LogsTest do
  use ExUnit.Case

  describe "Jason.Encoder implementation" do
    test "encodes DBConnection.ConnectionError" do
      error = %DBConnection.ConnectionError{
        message: "connection lost",
        reason: :timeout,
        severity: :error
      }

      encoded = Jason.encode!(error)
      assert encoded =~ "message: \"connection lost\""
      assert encoded =~ "reason: :timeout"
      assert encoded =~ "severity: :error"
    end

    test "encodes Postgrex.Error" do
      error = %Postgrex.Error{
        message: "relation not found",
        postgres: %{
          code: "42P01",
          schema: "public",
          table: "users"
        }
      }

      encoded = Jason.encode!(error)
      assert encoded =~ "message: \"relation not found\""
      assert encoded =~ "schema: \"public\""
      assert encoded =~ "table: \"users\""
      assert encoded =~ "code: \"42P01\""
    end
  end
end
