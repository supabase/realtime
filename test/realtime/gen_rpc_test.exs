defmodule Realtime.GenRpcTest do
  # Async false due to Clustered usage
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Realtime.GenRpc

  setup context do
    {:ok, node} = Clustered.start(nil, extra_config: context[:extra_config] || [])

    %{node: node}
  end

  describe "call/5" do
    setup do
      :telemetry.attach(__MODULE__, [:realtime, :rpc], &__MODULE__.handle_telemetry/4, pid: self())
      on_exit(fn -> :telemetry.detach(__MODULE__) end)
    end

    test "returns the result calling local node" do
      current_node = node()

      assert GenRpc.call(current_node, Map, :fetch, [%{a: 1}, :a], tenant_id: "123") == {:ok, 1}

      assert_receive {[:realtime, :rpc], %{latency: _},
                      %{
                        origin_node: ^current_node,
                        target_node: ^current_node,
                        success: true,
                        tenant: "123",
                        mechanism: :gen_rpc
                      }}
    end

    test "returns the result with an error tuple calling local node" do
      current_node = node()

      assert GenRpc.call(current_node, File, :open, ["/not-existing.file"], tenant_id: "123") == {:error, :enoent}

      assert_receive {[:realtime, :rpc], %{latency: _},
                      %{
                        origin_node: ^current_node,
                        target_node: ^current_node,
                        success: false,
                        tenant: "123",
                        mechanism: :gen_rpc
                      }}
    end

    test "returns the result calling remote node", %{node: node} do
      current_node = node()
      assert GenRpc.call(node, Map, :fetch, [%{a: 1}, :a], tenant_id: "123") == {:ok, 1}

      assert_receive {[:realtime, :rpc], %{latency: _},
                      %{
                        origin_node: ^current_node,
                        target_node: ^node,
                        success: true,
                        tenant: "123",
                        mechanism: :gen_rpc
                      }}
    end

    test "returns the result with an error tuple calling remote node", %{node: node} do
      current_node = node()

      assert GenRpc.call(node, File, :open, ["/not-existing.file"], tenant_id: "123") == {:error, :enoent}

      assert_receive {[:realtime, :rpc], %{latency: _},
                      %{
                        origin_node: ^current_node,
                        target_node: ^node,
                        success: false,
                        tenant: "123",
                        mechanism: :gen_rpc
                      }}
    end

    test "local node timeout error" do
      current_node = node()

      log =
        capture_log(fn ->
          assert GenRpc.call(current_node, Process, :sleep, [500], timeout: 100, tenant_id: 123) ==
                   {:error, :rpc_error, :timeout}
        end)

      assert log =~
               "project=123 external_id=123 [error] ErrorOnRpcCall: %{error: :timeout, mod: Process, func: :sleep, target: :\"main@127.0.0.1\"}"

      assert_receive {[:realtime, :rpc], %{latency: _},
                      %{
                        origin_node: ^current_node,
                        target_node: ^current_node,
                        success: false,
                        tenant: 123,
                        mechanism: :gen_rpc
                      }}
    end

    test "remote node timeout error", %{node: node} do
      current_node = node()

      log =
        capture_log(fn ->
          assert GenRpc.call(node, Process, :sleep, [500], timeout: 100, tenant_id: 123) ==
                   {:error, :rpc_error, :timeout}
        end)

      assert log =~
               ~r/project=123 external_id=123 \[error\] ErrorOnRpcCall: %{\s+error: :timeout,\s+mod: Process,\s+func: :sleep,\s+target:\s+:"#{node}"/

      assert_receive {[:realtime, :rpc], %{latency: _},
                      %{
                        origin_node: ^current_node,
                        target_node: ^node,
                        success: false,
                        tenant: 123,
                        mechanism: :gen_rpc
                      }}
    end

    test "local node exception" do
      current_node = node()

      assert {:error, :rpc_error, _} = GenRpc.call(current_node, Map, :fetch!, [%{}, :a], tenant_id: "123")

      assert_receive {[:realtime, :rpc], %{latency: _},
                      %{
                        origin_node: ^current_node,
                        target_node: ^current_node,
                        success: false,
                        tenant: "123",
                        mechanism: :gen_rpc
                      }}
    end

    test "remote node exception", %{node: node} do
      current_node = node()

      assert {:error, :rpc_error, _} = GenRpc.call(node, Map, :fetch!, [%{}, :a], tenant_id: "123")

      assert_receive {[:realtime, :rpc], %{latency: _},
                      %{
                        origin_node: ^current_node,
                        target_node: ^node,
                        success: false,
                        tenant: "123",
                        mechanism: :gen_rpc
                      }}
    end

    @tag extra_config: [{:gen_rpc, :tcp_server_port, 9999}]
    test "bad tcp error", %{node: node} do
      current_node = node()

      log =
        capture_log(fn ->
          assert GenRpc.call(node, Map, :fetch, [%{a: 1}, :a], tenant_id: 123) == {:error, :rpc_error, :econnrefused}
        end)

      assert log =~
               ~r/project=123 external_id=123 \[error\] ErrorOnRpcCall: %{\s+error: :econnrefused,\s+mod: Map,\s+func: :fetch,\s+target:\s+:"#{node}"/

      assert_receive {[:realtime, :rpc], %{latency: _},
                      %{
                        origin_node: ^current_node,
                        target_node: ^node,
                        success: false,
                        tenant: 123,
                        mechanism: :gen_rpc
                      }}
    end

    test "bad node" do
      node = :"unknown@1.1.1.1"

      log =
        capture_log(fn ->
          assert GenRpc.call(node, Map, :fetch, [%{a: 1}, :a], tenant_id: 123) == {:error, :rpc_error, :badnode}
        end)

      assert log =~
               ~r/project=123 external_id=123 \[error\] ErrorOnRpcCall: %{+error: :badnode, mod: Map, func: :fetch, target: :"#{node}"/
    end
  end

  describe "abcast/4" do
    test "abcast to registered process", %{node: node} do
      name =
        System.unique_integer()
        |> to_string()
        |> String.to_atom()

      :erlang.register(name, self())

      # Use erpc to make the other node abcast to this one
      :erpc.call(node, GenRpc, :abcast, [[node()], name, "a message", []])

      assert_receive "a message"
      refute_receive _any
    end

    @tag extra_config: [{:gen_rpc, :tcp_server_port, 9999}]
    test "tcp error" do
      Logger.put_process_level(self(), :debug)

      log =
        capture_log(fn ->
          assert GenRpc.abcast(Node.list(), :some_process_name, "a message", []) == :ok
          # We have to wait for gen_rpc logs to show up
          Process.sleep(100)
        end)

      assert log =~ "[error] event=connect_to_remote_server"

      refute_receive _any
    end
  end

  describe "multicast/4" do
    test "evals everywhere" do
      parent = self()

      assert GenRpc.multicast(Kernel, :send, [parent, :sent]) == :ok

      assert_receive :sent
      assert_receive :sent
      refute_receive _any
    end

    @tag extra_config: [{:gen_rpc, :tcp_server_port, 9999}]
    test "tcp error" do
      parent = self()
      Logger.put_process_level(self(), :debug)

      log =
        capture_log(fn ->
          assert GenRpc.multicast(Kernel, :send, [parent, :sent]) == :ok
          # We have to wait for gen_rpc logs to show up
          Process.sleep(100)
        end)

      assert log =~ "[error] event=connect_to_remote_server"

      assert_receive :sent
      refute_receive _any
    end
  end

  describe "multicall/4" do
    setup do
      :telemetry.attach(__MODULE__, [:realtime, :rpc], &__MODULE__.handle_telemetry/4, pid: self())
      on_exit(fn -> :telemetry.detach(__MODULE__) end)
    end

    test "returns the result of the function call per node", %{node: node} do
      current_node = node()

      assert GenRpc.multicall(Map, :fetch, [%{a: 1}, :a], tenant_id: "123") == [
               {:"main@127.0.0.1", {:ok, 1}},
               {node, {:ok, 1}}
             ]

      assert_receive {[:realtime, :rpc], %{latency: _},
                      %{
                        origin_node: ^current_node,
                        target_node: ^node,
                        success: true,
                        tenant: "123",
                        mechanism: :gen_rpc
                      }}

      assert_receive {[:realtime, :rpc], %{latency: _},
                      %{
                        origin_node: ^current_node,
                        target_node: ^current_node,
                        success: true,
                        tenant: "123",
                        mechanism: :gen_rpc
                      }}
    end

    test "timeout error", %{node: node} do
      current_node = node()

      log =
        capture_log(fn ->
          assert GenRpc.multicall(Process, :sleep, [500], timeout: 100, tenant_id: 123) == [
                   {:"main@127.0.0.1", {:error, :rpc_error, :timeout}},
                   {node, {:error, :rpc_error, :timeout}}
                 ]
        end)

      assert log =~
               "project=123 external_id=123 [error] ErrorOnRpcCall: %{error: :timeout, mod: Process, func: :sleep, target: :\"main@127.0.0.1\"}"

      assert log =~
               ~r/project=123 external_id=123 \[error\] ErrorOnRpcCall: %{\s+error: :timeout,\s+mod: Process,\s+func: :sleep,\s+target:\s+:"#{node}"/

      assert_receive {[:realtime, :rpc], %{latency: _},
                      %{
                        origin_node: ^current_node,
                        target_node: ^node,
                        success: false,
                        tenant: 123,
                        mechanism: :gen_rpc
                      }}

      assert_receive {[:realtime, :rpc], %{latency: _},
                      %{
                        origin_node: ^current_node,
                        target_node: ^current_node,
                        success: false,
                        tenant: 123,
                        mechanism: :gen_rpc
                      }}
    end

    @tag extra_config: [{:gen_rpc, :tcp_server_port, 9999}]
    test "partial results with bad tcp error", %{node: node} do
      current_node = node()

      log =
        capture_log(fn ->
          assert GenRpc.multicall(Map, :fetch, [%{a: 1}, :a], tenant_id: 123) == [
                   {:"main@127.0.0.1", {:ok, 1}},
                   {node, {:error, :rpc_error, :econnrefused}}
                 ]
        end)

      assert log =~
               ~r/project=123 external_id=123 \[error\] ErrorOnRpcCall: %{\s+error: :econnrefused,\s+mod: Map,\s+func: :fetch,\s+target:\s+:"#{node}"/

      assert_receive {[:realtime, :rpc], %{latency: _},
                      %{
                        origin_node: ^current_node,
                        target_node: ^node,
                        success: false,
                        tenant: 123,
                        mechanism: :gen_rpc
                      }}

      assert_receive {[:realtime, :rpc], %{latency: _},
                      %{
                        origin_node: ^current_node,
                        target_node: ^current_node,
                        success: true,
                        tenant: 123,
                        mechanism: :gen_rpc
                      }}
    end
  end

  def handle_telemetry(event, measurements, metadata, pid: pid), do: send(pid, {event, measurements, metadata})
end
