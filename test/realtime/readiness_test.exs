defmodule Realtime.ReadinessTest do
  # async: false: joins the global RegionNodes scope and changes Application env
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Realtime.Readiness

  # The test node itself is in RegionNodes under "us-east-1" (config/test.exs).
  setup do
    original = Application.get_env(:realtime, :readiness_min_nodes_per_region)
    Readiness.reset()

    on_exit(fn ->
      Application.put_env(:realtime, :readiness_min_nodes_per_region, original)
      Application.put_env(:realtime, :shutdown_in_progress, false)
      Readiness.reset()
    end)
  end

  defp min_nodes(minimums), do: Application.put_env(:realtime, :readiness_min_nodes_per_region, minimums)

  defp spawn_fake_node(region, node) do
    parent = self()

    fun = fn ->
      :syn.join(RegionNodes, region, self(), node: node)
      send(parent, :joined)

      receive do
        :ok -> :ok
      end
    end

    {:ok, _pid} = start_supervised({Task, fun}, id: {region, node})
    assert_receive :joined
  end

  test "ready when no minimum is configured" do
    min_nodes([])
    assert Readiness.check() == :ok
  end

  test "counts this node in its own region" do
    min_nodes([{"us-east-1", 1}])
    assert Readiness.check() == :ok
  end

  test "waits until every listed region has its minimum" do
    min_nodes([{"us-east-1", 2}, {"eu-west-1", 1}])
    assert Readiness.check() == {:error, {:waiting_for_nodes, [{"us-east-1", 1, 2}, {"eu-west-1", 0, 1}]}}

    spawn_fake_node("eu-west-1", :eu_node_1)
    assert Readiness.check() == {:error, {:waiting_for_nodes, [{"us-east-1", 1, 2}]}}

    spawn_fake_node("us-east-1", :us_node_2)
    assert Readiness.check() == :ok
  end

  test "stays ready after a region drops below its minimum" do
    min_nodes([{"eu-west-1", 1}])
    spawn_fake_node("eu-west-1", :eu_node_1)
    assert Readiness.check() == :ok

    :ok = stop_supervised({"eu-west-1", :eu_node_1})
    assert Realtime.Nodes.region_nodes("eu-west-1") == []
    assert Readiness.check() == :ok
  end

  test "not ready while shutting down, configured or not" do
    min_nodes([])
    Application.put_env(:realtime, :shutdown_in_progress, true)
    assert Readiness.check() == {:error, :shutdown_in_progress}

    min_nodes([{"us-east-1", 1}])
    Application.put_env(:realtime, :shutdown_in_progress, false)
    assert Readiness.check() == :ok
    Application.put_env(:realtime, :shutdown_in_progress, true)
    assert Readiness.check() == {:error, :shutdown_in_progress}
  end

  test "logs what it waits for once, and again only when that changes" do
    min_nodes([{"us-east-1", 1}, {"eu-west-1", 2}])

    log =
      capture_log(fn ->
        for _ <- 1..5, do: Readiness.check()
      end)

    assert count(log, "Readiness: waiting for nodes: eu-west-1 0/2") == 1

    log =
      capture_log(fn ->
        spawn_fake_node("eu-west-1", :eu_node_1)
        for _ <- 1..5, do: Readiness.check()
      end)

    assert count(log, "Readiness: waiting for nodes: eu-west-1 1/2") == 1
    refute log =~ "0/2"

    log =
      capture_log(fn ->
        spawn_fake_node("eu-west-1", :eu_node_2)
        for _ <- 1..5, do: Readiness.check()
      end)

    assert count(log, "Readiness: ready, minimum nodes per region reached: us-east-1=1,eu-west-1=2") == 1
    refute log =~ "waiting for nodes"
  end

  defp count(log, line), do: log |> String.split(line) |> length() |> Kernel.-(1)
end
