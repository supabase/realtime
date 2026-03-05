defmodule RealtimeWeb.Plugs.MetricsModeTest do
  use RealtimeWeb.ConnCase, async: true

  alias RealtimeWeb.Plugs.MetricsMode

  setup do
    original = Application.get_env(:realtime, :metrics_separation_enabled)
    on_exit(fn -> Application.put_env(:realtime, :metrics_separation_enabled, original) end)
    :ok
  end

  describe "call/2" do
    test "dispatches tenant-metrics path to 404 in legacy mode", %{conn: conn} do
      Application.put_env(:realtime, :metrics_separation_enabled, false)
      conn = %{conn | path_info: ["tenant-metrics", "some_tenant"]}
      conn = MetricsMode.call(conn, [])
      assert conn.status == 404
      assert conn.halted
    end

    test "passes through unchanged when metrics_separation_enabled is true", %{conn: conn} do
      Application.put_env(:realtime, :metrics_separation_enabled, true)
      result = MetricsMode.call(conn, [])
      refute result.halted
    end
  end
end
