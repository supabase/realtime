defmodule Realtime.PromEx.Plugins.GenRpcTest do
  # Async false due to Clustered usage
  use ExUnit.Case, async: false
  alias Realtime.PromEx.Plugins

  defmodule MetricsTest do
    use PromEx, otp_app: :metrics_test
    @impl true
    def plugins do
      [{Plugins.GenRpc, poll_rate: 100}]
    end
  end

  setup_all do
    {:ok, node} = Clustered.start()
    start_supervised!(MetricsTest)
    # Send some data back and forth
    25 = :gen_rpc.call(node, String, :to_integer, ["25"])
    # Wait for MetricsTest to fetch metrics
    Process.sleep(200)
    %{node: node}
  end

  describe "pooling metrics" do
    setup do
      %{metrics: PromEx.get_metrics(MetricsTest)}
    end

    test "send_pending_bytes", %{metrics: metrics, node: node} do
      assert metric_value(metrics, "gen_rpc_send_pending_bytes", origin_node: node(), target_node: node) == 0
    end

    test "send_count", %{metrics: metrics, node: node} do
      value = metric_value(metrics, "gen_rpc_send_count", origin_node: node(), target_node: node)
      assert is_integer(value)
      assert value > 0
    end

    test "send_bytes", %{metrics: metrics, node: node} do
      value = metric_value(metrics, "gen_rpc_send_bytes", origin_node: node(), target_node: node)
      assert is_integer(value)
      assert value > 0
    end

    test "recv_count", %{metrics: metrics, node: node} do
      value = metric_value(metrics, "gen_rpc_recv_count", origin_node: node(), target_node: node)
      assert is_integer(value)
      assert value > 0
    end

    test "recv_bytes", %{metrics: metrics, node: node} do
      value = metric_value(metrics, "gen_rpc_recv_bytes", origin_node: node(), target_node: node)
      assert is_integer(value)
      assert value > 0
    end

    test "queue_size", %{metrics: metrics, node: node} do
      value = metric_value(metrics, "gen_rpc_queue_size_bytes", origin_node: node(), target_node: node)
      assert is_integer(value)
    end
  end

  defp metric_value(metrics, metric, expected_tags), do: MetricsHelper.search(metrics, metric, expected_tags)
end
