defmodule RealtimeWeb.Dashboard.MusterTest do
  # async: false - non-async so `set_mimic_from_context` runs Mimic in global mode
  # (stubs then apply inside the spawned LiveView process), and because the no-scope
  # test briefly mutates the shared :muster_scope app env.
  use RealtimeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mimic

  alias RealtimeWeb.Dashboard.Muster

  setup :set_mimic_from_context

  setup do
    Application.put_env(:realtime, :dashboard_auth, :basic_auth)
    Application.put_env(:realtime, :dashboard_credentials, {"user", "pass"})

    on_exit(fn ->
      Application.delete_env(:realtime, :dashboard_auth)
      Application.delete_env(:realtime, :dashboard_credentials)
    end)

    %{conn: using_basic_auth(build_conn(), "user", "pass")}
  end

  describe "gather_local_info/0" do
    test "returns an error when the coordinator is unavailable" do
      expect(Forum.Muster, :summary, fn _scope -> exit(:noproc) end)

      assert {:error, "Muster coordinator unavailable: :noproc"} = Muster.gather_local_info()
    end

    test "folds the coordinator summary into the shape the page renders" do
      expect(Forum.Muster, :summary, fn _scope -> summary() end)

      assert {:ok, info} = Muster.gather_local_info()

      assert info.scope == :muster_dashboard_test
      assert info.status == :ready
      assert info.view_hash == 123_456
      assert info.members == [:"a@127.0.0.1", :"b@127.0.0.1"]
      assert info.ring_nodes == [:"a@127.0.0.1", :"b@127.0.0.1"]

      assert info.group_counts == [
               occupied: 4,
               cooldown: 1,
               vacant_queued: 0,
               occupied_pending: 0,
               vacant_flushing: 0
             ]

      assert info.group_total == 5

      # occupancy_rows_by_node is sorted by node name for stable rendering.
      assert info.occupancy_by_node == [{:"a@127.0.0.1", 2}, {:"z@127.0.0.1", 1}]
      assert info.occupancy_row_count == 3
    end

    test "defaults group_total to 0 when the summary omits :total" do
      expect(Forum.Muster, :summary, fn _scope -> summary(%{group_state_counts: %{}}) end)

      assert {:ok, info} = Muster.gather_local_info()
      assert info.group_total == 0
      assert info.group_counts == [occupied: 0, cooldown: 0, vacant_queued: 0, occupied_pending: 0, vacant_flushing: 0]
    end
  end

  describe "rendered page" do
    test "renders the live summary for the current node", %{conn: conn} do
      # No stub: Muster runs in the test app, so the real summary renders.
      {:ok, view, html} = live(conn, "/admin/dashboard/muster")

      assert html =~ "Muster"
      assert html =~ "Cluster / readiness"
      assert html =~ "As source"
      assert html =~ "As router"

      # Auto-refresh timer path: LiveDashboard sends :refresh to the LiveView,
      # which re-invokes handle_refresh/1 and re-fetches the snapshot.
      send(view.pid, :refresh)
      assert render(view) =~ "Cluster / readiness"
    end

    test "the Refresh button re-fetches the snapshot", %{conn: conn} do
      stub(Forum.Muster, :summary, fn _scope -> summary() end)

      {:ok, view, _html} = live(conn, "/admin/dashboard/muster")

      html = view |> element("button[phx-click='refresh']") |> render_click()
      assert html =~ "Cluster / readiness"
    end

    test "colors the status badge by lifecycle state", %{conn: conn} do
      for {status, klass} <- [ready: "bg-success", converging: "bg-warning", rebalancing: "bg-danger"] do
        stub(Forum.Muster, :summary, fn _scope -> summary(%{status: status}) end)

        {:ok, _view, html} = live(conn, "/admin/dashboard/muster")

        assert html =~ "badge #{klass}"
        assert html =~ inspect(status)
      end
    end

    test "renders the folded detail rows", %{conn: conn} do
      stub(Forum.Muster, :summary, fn _scope -> summary() end)

      {:ok, _view, html} = live(conn, "/admin/dashboard/muster")

      assert html =~ "Members (2)"
      assert html =~ "Ring Nodes (2)"
      # Per-group state counts render in @group_state_order with a total.
      assert html =~ ":occupied"
      assert html =~ ":vacant_flushing"
      # Router-role occupancy rows render per source node.
      assert html =~ "a@127.0.0.1"
      assert html =~ "z@127.0.0.1"
      assert html =~ "total present"
    end

    test "renders the unavailable state when the coordinator is down", %{conn: conn} do
      stub(Forum.Muster, :summary, fn _scope -> exit(:noproc) end)

      {:ok, _view, html} = live(conn, "/admin/dashboard/muster")

      assert html =~ "unavailable"
      assert html =~ "Muster coordinator unavailable"
      # The detail tables are not rendered in the error branch.
      refute html =~ "Cluster / readiness"
    end
  end

  # A fully-populated summary as Forum.Muster.summary/1 returns it, so tests can
  # stub the coordinator and assert exactly how the page folds and renders it.
  defp summary(overrides \\ %{}) do
    Map.merge(
      %{
        scope: :muster_dashboard_test,
        status: :ready,
        view_hash: 123_456,
        members: [:"a@127.0.0.1", :"b@127.0.0.1"],
        ring_nodes: [:"a@127.0.0.1", :"b@127.0.0.1"],
        peers: 1,
        owed_snapshots: 0,
        applied_snapshot_seq: %{},
        occupancy_row_count: 3,
        occupancy_rows_by_node: %{"z@127.0.0.1": 1, "a@127.0.0.1": 2},
        group_state_counts: %{occupied: 4, cooldown: 1, total: 5}
      },
      overrides
    )
  end

  defp using_basic_auth(conn, username, password) do
    header_content = "Basic " <> Base.encode64("#{username}:#{password}")
    put_req_header(conn, "authorization", header_content)
  end
end
