defmodule Realtime.DistributedMetricsTest do
  # Async false due to Clustered usage
  use ExUnit.Case, async: false

  alias Realtime.DistributedMetrics

  setup_all do
    {:ok, node} = Clustered.start()
    %{node: node}
  end

  describe "info/0 while connected" do
    test "per node metric", %{node: node} do
      assert %{
               ^node => %{
                 pid: _pid,
                 port: _port,
                 queue_size: {:ok, 0},
                 state: :up,
                 inet_stats: [
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
                 ]
               }
             } = DistributedMetrics.info()
    end

    test "metric matches on both sides", %{node: node} do
      # We need to generate some data first
      Realtime.Rpc.call(node, String, :to_integer, ["25"], key: 1)
      Realtime.Rpc.call(node, String, :to_integer, ["25"], key: 2)

      local_metrics = DistributedMetrics.info()[node][:inet_stats]
      # Use gen_rpc to not use erl dist and change the result
      remote_metrics = :gen_rpc.call(node, DistributedMetrics, :info, [])[node()][:inet_stats]

      # It's not going to 100% the same because erl dist sends pings and other things out of our control

      assert local_metrics[:connections] == remote_metrics[:connections]

      assert_in_delta(local_metrics[:send_avg], remote_metrics[:recv_avg], 5)
      assert_in_delta(local_metrics[:recv_avg], remote_metrics[:send_avg], 5)

      assert_in_delta(local_metrics[:send_oct], remote_metrics[:recv_oct], 5)
      assert_in_delta(local_metrics[:recv_oct], remote_metrics[:send_oct], 5)

      assert_in_delta(local_metrics[:send_max], remote_metrics[:recv_max], 5)
      assert_in_delta(local_metrics[:recv_max], remote_metrics[:send_max], 5)
    end
  end
end
