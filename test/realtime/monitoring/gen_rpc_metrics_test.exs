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

    test "metric matches on both sides", %{node: node} do
      # We need to generate some load on gen_rpc first
      Realtime.GenRpc.call(node, String, :to_integer, ["25"], key: 1)
      Realtime.GenRpc.call(node, String, :to_integer, ["25"], key: 2)

      local_metrics = GenRpcMetrics.info()[node]
      remote_metrics = :erpc.call(node, GenRpcMetrics, :info, [])[node()]

      assert local_metrics[:connections] == remote_metrics[:connections]

      assert local_metrics[:send_avg] == remote_metrics[:recv_avg]
      assert local_metrics[:recv_avg] == remote_metrics[:send_avg]

      assert local_metrics[:send_oct] == remote_metrics[:recv_oct]
      assert local_metrics[:recv_oct] == remote_metrics[:send_oct]

      assert local_metrics[:send_cnt] == remote_metrics[:recv_cnt]
      assert local_metrics[:recv_cnt] == remote_metrics[:send_cnt]

      assert local_metrics[:send_max] == remote_metrics[:recv_max]
      assert local_metrics[:recv_max] == remote_metrics[:send_max]

      assert local_metrics[:send_max] == remote_metrics[:recv_max]
      assert local_metrics[:recv_max] == remote_metrics[:send_max]
    end
  end
end
