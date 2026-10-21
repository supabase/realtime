defmodule Realtime.PromExTest do
  use ExUnit.Case, async: true
  doctest Realtime.PromEx
  alias Realtime.Nodes
  alias Realtime.PromEx
  alias RealtimeWeb.RequestMetrics

  describe "get_metrics/0" do
    test "builds metrics in prometheus format which includes host region and id" do
      metrics = PromEx.get_metrics() |> IO.iodata_to_binary()
      [_name, host] = node() |> Atom.to_string() |> String.split("@", parts: 2)
      id = Nodes.short_node_id_from_name(node())

      assert String.contains?(
               metrics,
               "# HELP beam_system_schedulers_online_info The number of scheduler threads that are online."
             )

      assert String.contains?(metrics, "# TYPE beam_system_schedulers_online_info gauge")

      assert String.contains?(
               metrics,
               "beam_system_schedulers_online_info{host=\"#{host}\",id=\"#{id}\",region=\"us-east-1\"}"
             )
    end

    # The plugin test uses its own PromEx module, so this is what catches a plugin that is not registered.
    test "includes the client request counter used by the SLO" do
      RequestMetrics.record(:broadcast, :ws, :success)

      metrics = PromEx.get_metrics() |> IO.iodata_to_binary()

      assert metrics =~ ~r/realtime_client_requests_total\{[^}]*outcome="success"[^}]*\} \d+/
    end
  end
end
