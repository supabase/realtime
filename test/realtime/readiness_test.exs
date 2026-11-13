defmodule Realtime.ReadinessTest do
  # async: false: joins the global RegionNodes scope and changes Application env
  use ExUnit.Case, async: false
  use TestHelpers

  import ExUnit.CaptureLog

  alias Realtime.Readiness

  # The test node itself is in RegionNodes under "us-east-1" (config/test.exs). Fake nodes go into a region of the
  # test's own: syn drops a member asynchronously when its process exits, so one test's fake nodes must not count
  # toward another test's region.
  setup do
    original = Application.get_env(:realtime, :readiness_min_nodes_per_region)
    Readiness.reset()

    on_exit(fn ->
      Application.put_env(:realtime, :readiness_min_nodes_per_region, original)
      Application.put_env(:realtime, :shutdown_in_progress, false)
      Readiness.reset()
    end)

    %{region: "test-region-#{System.unique_integer([:positive])}"}
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

  test "waits until every listed region has its minimum", %{region: region} do
    min_nodes([{"us-east-1", 1}, {region, 2}])
    assert Readiness.check() == {:error, {:waiting_for_nodes, [{region, 0, 2}]}}

    spawn_fake_node(region, :fake_node_1)
    assert Readiness.check() == {:error, {:waiting_for_nodes, [{region, 1, 2}]}}

    spawn_fake_node(region, :fake_node_2)
    assert Readiness.check() == :ok
  end

  test "stays ready after a region drops below its minimum", %{region: region} do
    min_nodes([{region, 1}])
    spawn_fake_node(region, :fake_node_1)
    assert Readiness.check() == :ok

    :ok = stop_supervised({region, :fake_node_1})
    assert_eventually Realtime.Nodes.region_nodes(region) == []
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

  test "logs what it waits for once, and again only when that changes", %{region: region} do
    min_nodes([{"us-east-1", 1}, {region, 2}])

    log =
      capture_log(fn ->
        for _ <- 1..5, do: Readiness.check()
      end)

    assert count(log, "Readiness: waiting for nodes: #{region} 0/2") == 1

    log =
      capture_log(fn ->
        spawn_fake_node(region, :fake_node_1)
        for _ <- 1..5, do: Readiness.check()
      end)

    assert count(log, "Readiness: waiting for nodes: #{region} 1/2") == 1
    refute log =~ "0/2"

    log =
      capture_log(fn ->
        spawn_fake_node(region, :fake_node_2)
        for _ <- 1..5, do: Readiness.check()
      end)

    assert count(log, "Readiness: ready, minimum nodes per region reached: us-east-1=1,#{region}=2") == 1
    refute log =~ "waiting for nodes"
  end

  defp count(log, line), do: log |> String.split(line) |> length() |> Kernel.-(1)
end
