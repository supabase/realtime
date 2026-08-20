defmodule Realtime.RegionMembershipTest do
  use ExUnit.Case, async: false

  alias Realtime.Nodes

  @region "ap-southeast-2"

  test "a draining node stops being eligible but stays reachable" do
    {:ok, node} =
      Clustered.start(nil,
        extra_config: [{:realtime, :region, @region}],
        phoenix_port: 4040
      )

    eventually(fn -> node in Nodes.eligible_region_nodes(@region) end)

    :ok = :erpc.call(node, Realtime.RegionMembership, :drain, [])

    eventually(fn -> node not in Nodes.eligible_region_nodes(@region) end)
    assert node in Nodes.region_nodes(@region)
    assert :erpc.call(node, Process, :whereis, [Extensions.PostgresCdcRls.Supervisor])
  end

  defp eventually(fun, remaining \\ 5_000)
  defp eventually(fun, remaining) when remaining <= 0, do: assert(fun.())

  defp eventually(fun, remaining) do
    if fun.() do
      :ok
    else
      Process.sleep(50)
      eventually(fun, remaining - 50)
    end
  end
end
