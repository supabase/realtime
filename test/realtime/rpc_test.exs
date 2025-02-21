defmodule Realtime.RpcTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias Realtime.Rpc

  defmodule TestRpc do
    def test_raise, do: raise("test")
    def test_timeout, do: Process.sleep(200)
    def test_success, do: {:ok, "success"}
  end

  def handle_telemetry(event, measurements, metadata, pid: pid), do: send(pid, {event, measurements, metadata})

  setup do
    :telemetry.attach(__MODULE__, [:realtime, :rpc], &__MODULE__.handle_telemetry/4, pid: self())
    on_exit(fn -> :telemetry.detach(__MODULE__) end)
    :ok
  end

  describe "call/5" do
    test "successful RPC call returns exactly what the original function returns" do
      assert {:ok, "success"} = Rpc.call(node(), TestRpc, :test_success, [])

      assert_receive {[:realtime, :rpc], %{latency: _},
                      %{
                        mod: Realtime.RpcTest.TestRpc,
                        func: :test_success,
                        origin_node: :nonode@nohost,
                        target_node: :nonode@nohost
                      }}
    end

    test "raised exceptions are properly caught and logged" do
      assert {:badrpc,
              {:EXIT,
               {%RuntimeError{message: "test"},
                [
                  {Realtime.RpcTest.TestRpc, :test_raise, 0,
                   [file: ~c"test/realtime/rpc_test.exs", line: 9, error_info: %{module: Exception}]}
                ]}}} =
               Rpc.call(node(), TestRpc, :test_raise, [])

      assert_receive {[:realtime, :rpc], %{latency: _},
                      %{
                        mod: Realtime.RpcTest.TestRpc,
                        func: :test_raise,
                        origin_node: :nonode@nohost,
                        target_node: :nonode@nohost
                      }}
    end

    test "timeouts are properly caught and logged" do
      assert {:badrpc, :timeout} =
               Rpc.call(node(), TestRpc, :test_timeout, [], timeout: 100)

      assert_receive {[:realtime, :rpc], %{latency: _},
                      %{
                        mod: Realtime.RpcTest.TestRpc,
                        func: :test_timeout,
                        origin_node: :nonode@nohost,
                        target_node: :nonode@nohost
                      }}
    end
  end

  describe "enhanced_call/5" do
    test "successful RPC call returns exactly what the original function returns" do
      assert {:ok, "success"} = Rpc.enhanced_call(node(), TestRpc, :test_success)

      assert_receive {[:realtime, :rpc], %{latency: _},
                      %{
                        mod: Realtime.RpcTest.TestRpc,
                        func: :test_success,
                        origin_node: :nonode@nohost,
                        target_node: :nonode@nohost,
                        success: true
                      }}
    end

    test "raised exceptions are properly caught and logged" do
      assert capture_log(fn ->
               assert {:error, :rpc_error, %RuntimeError{message: "test"}} =
                        Rpc.enhanced_call(node(), TestRpc, :test_raise)
             end) =~ "ErrorOnRpcCall"

      assert_receive {[:realtime, :rpc], %{latency: _},
                      %{
                        mod: Realtime.RpcTest.TestRpc,
                        func: :test_raise,
                        origin_node: :nonode@nohost,
                        target_node: :nonode@nohost,
                        success: false
                      }}
    end

    test "timeouts are properly caught and logged" do
      assert capture_log(fn ->
               assert {:error, :rpc_error, :timeout} =
                        Rpc.enhanced_call(node(), TestRpc, :test_timeout, [], timeout: 100)
             end) =~ "ErrorOnRpcCall"

      assert_receive {[:realtime, :rpc], %{latency: 0},
                      %{
                        mod: Realtime.RpcTest.TestRpc,
                        func: :test_timeout,
                        origin_node: :nonode@nohost,
                        target_node: :nonode@nohost
                      }}
    end
  end
end
