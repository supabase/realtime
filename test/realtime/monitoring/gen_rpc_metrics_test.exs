defmodule Realtime.GenRpcMetricsTest do
  # Async false due to Clustered usage
  use ExUnit.Case, async: false

  alias Realtime.GenRpcMetrics

  setup_all do
    {:ok, node} = Clustered.start()
    %{node: node}
  end

  describe "info/0 while connected" do
    test "per node metric", %{node: node} do
      # We need to generate some load on gen_rpc first
      Realtime.GenRpc.call(node, String, :to_integer, ["25"], key: 1)
      Realtime.GenRpc.call(node, String, :to_integer, ["25"], key: 2)

      assert %{
               ^node => %{
                 connections: _,
                 queue_size: _,
                 inet_stats: %{
                   recv_oct: _,
                   recv_cnt: _,
                   recv_max: _,
                   recv_avg: _,
                   recv_dvi: _,
                   send_oct: _,
                   send_cnt: _,
                   send_max: _,
                   send_avg: _,
                   send_pend: _
                 }
               }
             } = GenRpcMetrics.info()
    end
  end
end
