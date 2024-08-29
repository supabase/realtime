defmodule Realtime.RpcTest do
  use ExUnit.Case
  alias Realtime.Rpc
  import ExUnit.CaptureLog

  defmodule TestRpc do
    def test_raise, do: raise("test")
    def test_timeout, do: :timer.sleep(1000)
    def test_success, do: {:ok, "success"}
  end

  describe "enhanced_call/5" do
    test "successful RPC call returns exactly what the original function returns" do
      assert {:ok, "success"} = Rpc.enhanced_call(node(), TestRpc, :test_success)
    end

    test "raised exceptions are properly caught and logged" do
      assert capture_log(fn ->
               assert {:error, "RPC call error"} = Rpc.enhanced_call(node(), TestRpc, :test_raise)
             end) =~ "ErrorOnRpcCall"
    end

    test "timeouts are properly caught and logged" do
      assert capture_log(fn ->
               assert {:error, "RPC call error"} =
                        Rpc.enhanced_call(node(), TestRpc, :test_timeout, 500)
             end) =~ "ErrorOnRpcCall"
    end
  end
end
