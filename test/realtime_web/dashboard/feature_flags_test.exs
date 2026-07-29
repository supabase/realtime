defmodule RealtimeWeb.Dashboard.FeatureFlagsTest do
  use RealtimeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Realtime.Api

  @path "/admin/dashboard/feature_flags"

  setup do
    Application.put_env(:realtime, :dashboard_auth, :basic_auth)
    Application.put_env(:realtime, :dashboard_credentials, {"user", "pass"})

    on_exit(fn ->
      Application.delete_env(:realtime, :dashboard_auth)
      Application.delete_env(:realtime, :dashboard_credentials)
    end)

    %{conn: using_basic_auth(build_conn(), "user", "pass")}
  end

  test "renders the add form", %{conn: conn} do
    {:ok, _view, html} = live(conn, @path)

    assert html =~ "Feature Flags"
    assert html =~ "New flag name"
  end

  test "creates a new flag", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    html = view |> element("form[phx-submit='create']") |> render_submit(%{name: "brand_new_flag"})

    assert html =~ "brand_new_flag"
    assert %Api.FeatureFlag{enabled: false} = Api.get_feature_flag("brand_new_flag")
  end

  test "trims whitespace around the flag name", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    view |> element("form[phx-submit='create']") |> render_submit(%{name: "  spaced_flag  "})

    assert Api.get_feature_flag("spaced_flag")
    refute Api.get_feature_flag("  spaced_flag  ")
  end

  test "rejects a duplicate flag name and leaves the existing flag untouched", %{conn: conn} do
    {:ok, existing} = Api.create_feature_flag(%{name: "dup_flag", enabled: true, rollout_percentage: 30})

    {:ok, view, _html} = live(conn, @path)

    html = view |> element("form[phx-submit='create']") |> render_submit(%{name: "dup_flag"})

    assert html =~ "already exists"
    assert html =~ "dup_flag"

    # The existing flag must not be clobbered (upsert would reset enabled/rollout).
    reloaded = Api.get_feature_flag("dup_flag")
    assert reloaded.id == existing.id
    assert reloaded.enabled == true
    assert reloaded.rollout_percentage == 30
    assert Api.list_feature_flags() |> Enum.count(&(&1.name == "dup_flag")) == 1
  end

  test "ignores an empty flag name", %{conn: conn} do
    before = Api.list_feature_flags() |> Enum.map(& &1.name) |> Enum.sort()

    {:ok, view, _html} = live(conn, @path)

    view |> element("form[phx-submit='create']") |> render_submit(%{name: "   "})

    assert Api.list_feature_flags() |> Enum.map(& &1.name) |> Enum.sort() == before
  end

  test "toggles a flag's enabled state", %{conn: conn} do
    {:ok, flag} = Api.create_feature_flag(%{name: "toggle_flag", enabled: false})

    {:ok, view, _html} = live(conn, @path)

    view |> element("button[phx-click='toggle'][phx-value-id='#{flag.id}']") |> render_click()

    assert Api.get_feature_flag("toggle_flag").enabled == true
  end

  test "deletes a flag", %{conn: conn} do
    {:ok, flag} = Api.create_feature_flag(%{name: "delete_flag", enabled: false})

    {:ok, view, _html} = live(conn, @path)

    view |> element("button[phx-click='delete'][phx-value-id='#{flag.id}']") |> render_click()

    refute Api.get_feature_flag("delete_flag")
  end

  defp using_basic_auth(conn, username, password) do
    header_content = "Basic " <> Base.encode64("#{username}:#{password}")
    put_req_header(conn, "authorization", header_content)
  end
end
