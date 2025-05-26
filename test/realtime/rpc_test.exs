defmodule Realtime.RpcTest do
  # async: false due using global otel_simple_processor
  use ExUnit.Case, async: false
  use Realtime.Tracing

  import ExUnit.CaptureLog

  alias Realtime.Rpc

  @parent_id "b7ad6b7169203331"
  @traceparent "00-0af7651916cd43dd8448eb211c80319c-#{@parent_id}-01"
  @span_parent_id Integer.parse(@parent_id, 16) |> elem(0)
  @aux_mod (quote do
              defmodule TestRpc do
                def test_raise, do: raise("test")
                def test_timeout, do: Process.sleep(200)
                def test_success, do: {:ok, "success"}
              end
            end)

  Code.eval_quoted(@aux_mod)

  def handle_telemetry(event, measurements, metadata, pid: pid), do: send(pid, {event, measurements, metadata})

  setup do
    {:ok, node} = Clustered.start(@aux_mod)
    :telemetry.attach(__MODULE__, [:realtime, :rpc], &__MODULE__.handle_telemetry/4, pid: self())
    on_exit(fn -> :telemetry.detach(__MODULE__) end)

    %{node: node}
  end

  describe "call/5" do
    test "successful RPC call returns exactly what the original function returns", %{node: node} do
      assert {:ok, "success"} = Rpc.call(node, TestRpc, :test_success, [])
      origin_node = node()

      assert_receive {[:realtime, :rpc], %{latency: _},
                      %{
                        mod: TestRpc,
                        func: :test_success,
                        origin_node: ^origin_node,
                        target_node: ^node
                      }}
    end

    test "raised exceptions are properly caught and logged", %{node: node} do
      assert {:badrpc, {:EXIT, {%RuntimeError{message: "test"}, [{TestRpc, :test_raise, 0, _}]}}} =
               Rpc.call(node, TestRpc, :test_raise, [])

      origin_node = node()

      assert_receive {[:realtime, :rpc], %{latency: _},
                      %{
                        mod: TestRpc,
                        func: :test_raise,
                        origin_node: ^origin_node,
                        target_node: ^node
                      }}
    end

    test "timeouts are properly caught and logged", %{node: node} do
      assert {:badrpc, :timeout} =
               Rpc.call(node, TestRpc, :test_timeout, [], timeout: 100)

      origin_node = node()

      assert_receive {[:realtime, :rpc], %{latency: _},
                      %{
                        mod: TestRpc,
                        func: :test_timeout,
                        origin_node: ^origin_node,
                        target_node: ^node
                      }}
    end
  end

  describe "enhanced_call/5" do
    test "successful RPC call returns exactly what the original function returns", %{node: node} do
      assert {:ok, "success"} = Rpc.enhanced_call(node, TestRpc, :test_success)
      origin_node = node()

      assert_receive {[:realtime, :rpc], %{latency: _},
                      %{
                        mod: TestRpc,
                        func: :test_success,
                        origin_node: ^origin_node,
                        target_node: ^node,
                        success: true
                      }}
    end

    test "raised exceptions are properly caught and logged", %{node: node} do
      assert capture_log(fn ->
               assert {:error, :rpc_error, %RuntimeError{message: "test"}} =
                        Rpc.enhanced_call(node, TestRpc, :test_raise)
             end) =~ "ErrorOnRpcCall"

      origin_node = node()

      assert_receive {[:realtime, :rpc], %{latency: _},
                      %{
                        mod: TestRpc,
                        func: :test_raise,
                        origin_node: ^origin_node,
                        target_node: ^node,
                        success: false
                      }}
    end

    test "timeouts are properly caught and logged", %{node: node} do
      assert capture_log(fn ->
               assert {:error, :rpc_error, :timeout} =
                        Rpc.enhanced_call(node, TestRpc, :test_timeout, [], timeout: 100)
             end) =~ "ErrorOnRpcCall"

      origin_node = node()

      assert_receive {[:realtime, :rpc], %{latency: 0},
                      %{
                        mod: TestRpc,
                        func: :test_timeout,
                        origin_node: ^origin_node,
                        target_node: ^node
                      }}
    end
  end

  describe "enhanced_call/5 with tracing" do
    setup %{node: node} do
      :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
      :otel_propagator_text_map.extract([{"traceparent", @traceparent}])
      # Set the other node to forward traces to this node as well
      :erpc.call(node, :otel_simple_processor, :set_exporter, [:otel_exporter_pid, self()])
      :ok
    end

    test "successful RPC local call" do
      assert {:ok, "success"} =
               Rpc.enhanced_call(Node.self(), TestRpc, :test_success, [],
                 tracing_span_name: "test",
                 tenant: "test_tenant"
               )

      # Local span
      assert_receive {:span, span(name: "local.test", attributes: attributes, parent_span_id: @span_parent_id)}

      assert attributes(map: %{mod: TestRpc, func: :test_success, arity: 0}) = attributes

      refute_receive {:span, _}
    end

    test "successful RPC remote call", %{node: node} do
      assert {:ok, "success"} =
               Rpc.enhanced_call(node, TestRpc, :test_success, [], tracing_span_name: "test", tenant: "test_tenant")

      # Remote span
      assert_receive {:span, span(name: "remote.test", attributes: attributes, parent_span_id: @span_parent_id)}

      assert attributes(
               map: %{
                 external_id: "test_tenant",
                 mod: TestRpc,
                 func: :test_success,
                 arity: 0,
                 node: ^node
               }
             ) = attributes

      # Local span
      assert_receive {:span, span(name: "local.test", attributes: attributes, parent_span_id: @span_parent_id)}

      assert attributes(map: %{mod: TestRpc, func: :test_success, arity: 0}) = attributes

      refute_receive {:span, _}
    end

    test "remote call raised exceptions are properly caught and logged", %{node: node} do
      assert capture_log(fn ->
               assert {:error, :rpc_error, %RuntimeError{message: "test"}} =
                        Rpc.enhanced_call(node, TestRpc, :test_raise, [],
                          tracing_span_name: "test",
                          tenant: "test_tenant"
                        )
             end) =~ "ErrorOnRpcCall"

      # Remote span
      assert_receive {:span, span(name: "remote.test", attributes: attributes, parent_span_id: @span_parent_id)}

      assert attributes(
               map: %{
                 external_id: "test_tenant",
                 mod: TestRpc,
                 func: :test_raise,
                 arity: 0,
                 node: ^node
               }
             ) = attributes

      # Local span
      assert_receive {:span, span(name: "local.test", attributes: attributes, parent_span_id: @span_parent_id)}

      assert attributes(map: %{mod: TestRpc, func: :test_raise, arity: 0}) = attributes

      refute_receive {:span, _}
    end

    test "local call raised exceptions are properly caught and logged" do
      assert capture_log(fn ->
               assert {:error, :rpc_error, %RuntimeError{message: "test"}} =
                        Rpc.enhanced_call(Node.self(), TestRpc, :test_raise, [],
                          tracing_span_name: "test",
                          tenant: "test_tenant"
                        )
             end) =~ "ErrorOnRpcCall"

      # Local span
      assert_receive {:span, span(name: "local.test", attributes: attributes, parent_span_id: @span_parent_id)}

      assert attributes(map: %{mod: TestRpc, func: :test_raise, arity: 0}) = attributes

      refute_receive {:span, _}
    end

    test "remote timeouts are properly caught and logged", %{node: node} do
      assert capture_log(fn ->
               assert {:error, :rpc_error, :timeout} =
                        Rpc.enhanced_call(node, TestRpc, :test_timeout, [],
                          timeout: 100,
                          tracing_span_name: "test",
                          tenant: "test_tenant"
                        )
             end) =~ "ErrorOnRpcCall"

      # Remote span
      assert_receive {:span, span(name: "remote.test", attributes: attributes, parent_span_id: @span_parent_id)}

      assert attributes(
               map: %{
                 external_id: "test_tenant",
                 mod: TestRpc,
                 func: :test_timeout,
                 arity: 0,
                 node: ^node
               }
             ) = attributes

      # Local span
      assert_receive {:span, span(name: "local.test", attributes: attributes, parent_span_id: @span_parent_id)}, 200

      assert attributes(map: %{mod: TestRpc, func: :test_timeout, arity: 0}) = attributes

      refute_receive {:span, _}
    end

    test "local timeouts are properly caught and logged" do
      assert capture_log(fn ->
               assert {:error, :rpc_error, :timeout} =
                        Rpc.enhanced_call(Node.self(), TestRpc, :test_timeout, [],
                          timeout: 100,
                          tracing_span_name: "test",
                          tenant: "test_tenant"
                        )
             end) =~ "ErrorOnRpcCall"

      # Local span
      assert_receive {:span, span(name: "local.test", attributes: attributes, parent_span_id: @span_parent_id)}, 200

      assert attributes(map: %{mod: TestRpc, func: :test_timeout, arity: 0}) = attributes

      refute_receive {:span, _}
    end
  end
end
