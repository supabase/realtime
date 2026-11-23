defmodule RealtimeWeb.Dashboard.MusterTest do
  # async: false - the rendered-page tests need Mimic in global mode, also manipulates the env
  use RealtimeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mimic

  alias RealtimeWeb.Dashboard.Muster

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
    # Called directly from the test process, so private mode isolates the expectations
    # from app processes that also call Forum.Muster leading to flakies.
    setup :set_mimic_private

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

  describe "gather_local_group_info/1" do
    # Same as `gather_local_info/0` above.
    setup :set_mimic_private

    test "returns the inspected node's scope, view hash, router and local count" do
      # Local-only reads (no router RPC); each happens once, so expect pins the count.
      expect(Forum.Muster, :view_hash, fn _scope -> 123_456 end)
      expect(Forum.Muster, :router, fn _scope, _group -> {:ok, node()} end)
      expect(Forum.Muster, :local_member_count, fn _scope, _group -> 3 end)
      # The local reader must not touch the router; that is group_data/2's job.
      reject(&Forum.Muster.targets/3)
      reject(&Forum.Muster.occupancy/2)

      assert {:ok, info} = Muster.gather_local_group_info("tenant-1")

      assert is_atom(info.scope)
      assert info.view_hash == 123_456
      assert info.router == {:ok, node()}
      assert info.local_member_count == 3
    end

    test "returns an error when the scope has published no state yet" do
      expect(Forum.Muster, :view_hash, fn _scope -> raise ArgumentError end)

      assert {:error, msg} = Muster.gather_local_group_info("tenant-1")
      assert msg =~ "no published state"
    end
  end

  describe "rendered page" do
    # Global mode: the group lookup reads run in gen_rpc acceptor processes (GenRpc.call
    # goes through gen_rpc even for node()), which private mode can't reach. Global
    # stubs are also seen by app processes, e.g. tenant-tagged broadcasts call
    # Forum.Muster.router/view_hash/targets, so these tests stub to avoid creating flakies.
    setup :set_mimic_global

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

    test "the group lookup form renders the router, targets and counts", %{conn: conn} do
      stub(Forum.Muster, :summary, fn _scope -> summary() end)
      stub(Forum.Muster, :view_hash, fn _scope -> 123_456 end)
      stub(Forum.Muster, :router, fn _scope, _group -> {:ok, node()} end)
      stub(Forum.Muster, :local_member_count, fn _scope, _group -> 7 end)
      stub(Forum.Muster, :targets, fn _scope, _group, _vh -> {:ok, [:"a@127.0.0.1", :"z@127.0.0.1"]} end)
      stub(Forum.Muster, :occupancy, fn _scope, _group -> [:"a@127.0.0.1", :"z@127.0.0.1"] end)

      {:ok, view, _html} = live(conn, "/admin/dashboard/muster")

      html = view |> form("form[phx-submit='lookup_group']", %{group: "tenant-1"}) |> render_submit()

      assert html =~ "Group lookup"
      assert html =~ "tenant-1"
      # Local member count for the inspected node.
      assert html =~ "Local members here"
      assert html =~ "7"
      # targets/3 result with its node count.
      assert html =~ "a@127.0.0.1"
      assert html =~ "(2 nodes)"
    end

    test "the Clear button resets the group lookup", %{conn: conn} do
      stub(Forum.Muster, :summary, fn _scope -> summary() end)
      stub(Forum.Muster, :view_hash, fn _scope -> 123_456 end)
      stub(Forum.Muster, :router, fn _scope, _group -> {:ok, node()} end)
      stub(Forum.Muster, :local_member_count, fn _scope, _group -> 7 end)
      stub(Forum.Muster, :targets, fn _scope, _group, _vh -> {:ok, [:"a@127.0.0.1"]} end)
      stub(Forum.Muster, :occupancy, fn _scope, _group -> [:"a@127.0.0.1"] end)

      {:ok, view, _html} = live(conn, "/admin/dashboard/muster")

      html = view |> form("form[phx-submit='lookup_group']", %{group: "tenant-1"}) |> render_submit()
      assert html =~ "Local members here"

      cleared = view |> element("button[phx-click='clear_group']") |> render_click()
      # The lookup result is gone and the Clear button hides once there is no query.
      refute cleared =~ "Local members here"
      refute cleared =~ "phx-click=\"clear_group\""
    end

    test "the group lookup form surfaces a flood result", %{conn: conn} do
      stub(Forum.Muster, :summary, fn _scope -> summary() end)
      stub(Forum.Muster, :view_hash, fn _scope -> 1 end)
      stub(Forum.Muster, :router, fn _scope, _group -> {:ok, node()} end)
      stub(Forum.Muster, :local_member_count, fn _scope, _group -> 0 end)
      stub(Forum.Muster, :targets, fn _scope, _group, _vh -> {:error, :flood} end)
      stub(Forum.Muster, :occupancy, fn _scope, _group -> [] end)

      {:ok, view, _html} = live(conn, "/admin/dashboard/muster")
      html = view |> form("form[phx-submit='lookup_group']", %{group: "tenant-1"}) |> render_submit()

      assert html =~ "flood"
    end

    test "the group lookup surfaces a rebalancing router without asking any router", %{conn: conn} do
      nodes = [:"a@127.0.0.1", :"b@127.0.0.1"]
      stub(Forum.Muster, :summary, fn _scope -> summary() end)
      stub(Forum.Muster, :view_hash, fn _scope -> 1 end)
      stub(Forum.Muster, :router, fn _scope, _group -> {:rebalancing, nodes} end)
      stub(Forum.Muster, :local_member_count, fn _scope, _group -> 0 end)
      # No single router while rebalancing, so neither router RPC is consulted.
      # App processes don't reach targets/occupancy either: with this router stub a
      # tenant-tagged broadcast takes the flood branch.
      reject(&Forum.Muster.targets/3)
      reject(&Forum.Muster.occupancy/2)

      {:ok, view, _html} = live(conn, "/admin/dashboard/muster")
      html = view |> form("form[phx-submit='lookup_group']", %{group: "tenant-1"}) |> render_submit()

      assert html =~ "rebalancing"
      assert html =~ "a@127.0.0.1"
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
