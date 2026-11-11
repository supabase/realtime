defmodule Realtime.RegionMembershipTest do
  use ExUnit.Case, async: false

  alias Realtime.Nodes

  @region "ap-southeast-2"

  test "a node that leaves stops being listed in its region" do
    {:ok, node} = Clustered.start(nil, extra_config: [{:realtime, :region, @region}])

    eventually(fn -> node in Nodes.region_nodes(@region) end)

    :ok = :erpc.call(node, Realtime.RegionMembership, :leave, [])

    eventually(fn -> node not in Nodes.region_nodes(@region) end)
  end

  test "a restart after shutdown began does not rejoin the region" do
    {:ok, node} = Clustered.start(nil, extra_config: [{:realtime, :region, @region}])

    eventually(fn -> node in Nodes.region_nodes(@region) end)

    :erpc.call(node, Application, :put_env, [:realtime, :shutdown_in_progress, true])
    pid = :erpc.call(node, Process, :whereis, [Realtime.RegionMembership])
    :erpc.call(node, Process, :exit, [pid, :kill])

    eventually(fn -> node not in Nodes.region_nodes(@region) end)

    new_pid = :erpc.call(node, Process, :whereis, [Realtime.RegionMembership])
    assert is_pid(new_pid) and new_pid != pid
    refute node in Nodes.region_nodes(@region)
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
