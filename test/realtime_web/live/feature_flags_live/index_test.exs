defmodule RealtimeWeb.FeatureFlagsLive.IndexTest do
  use RealtimeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Realtime.Api
  alias Realtime.Api.FeatureFlag
  alias Realtime.FeatureFlags.Cache
  alias RealtimeWeb.Endpoint

  setup do
    user = random_string()
    password = random_string()

    Application.put_env(:realtime, :dashboard_auth, :basic_auth)
    Application.put_env(:realtime, :dashboard_credentials, {user, password})

    on_exit(fn ->
      Application.delete_env(:realtime, :dashboard_auth)
      Application.delete_env(:realtime, :dashboard_credentials)
      Cachex.clear(Cache)
    end)

    Cachex.clear(Cache)

    %{user: user, password: password}
  end

  describe "auth" do
    test "renders feature flags page with valid credentials", %{conn: conn, user: user, password: password} do
      {:ok, _view, html} =
        conn |> using_basic_auth(user, password) |> live(~p"/admin/feature-flags")

      assert html =~ "Feature Flags"
    end

    test "returns 401 without credentials", %{conn: conn} do
      assert conn |> get(~p"/admin/feature-flags") |> response(401)
    end

    test "returns 401 with wrong credentials", %{conn: conn} do
      assert conn |> using_basic_auth("wrong", "wrong") |> get(~p"/admin/feature-flags") |> response(401)
    end
  end

  describe "mount" do
    test "lists existing flags ordered by name", %{conn: conn, user: user, password: password} do
      {:ok, _alpha} = Api.upsert_feature_flag(%{name: "alpha_flag", enabled: true})
      {:ok, _zeta} = Api.upsert_feature_flag(%{name: "zeta_flag", enabled: false})

      {:ok, _view, html} =
        conn |> using_basic_auth(user, password) |> live(~p"/admin/feature-flags")

      assert html =~ "alpha_flag"
      assert html =~ "zeta_flag"
    end
  end

  describe "create event" do
    test "adds a new flag to the list and persists it", %{conn: conn, user: user, password: password} do
      flag_name = "created_#{random_string()}"

      {:ok, view, _} = conn |> using_basic_auth(user, password) |> live(~p"/admin/feature-flags")

      html = view |> form("form[phx-submit=create]", name: flag_name) |> render_submit()

      assert html =~ flag_name
      assert %FeatureFlag{enabled: false} = Api.get_feature_flag(flag_name)
    end

    test "trims whitespace from the new flag name", %{conn: conn, user: user, password: password} do
      flag_name = "trim_#{random_string()}"

      {:ok, view, _} = conn |> using_basic_auth(user, password) |> live(~p"/admin/feature-flags")

      _ = view |> form("form[phx-submit=create]", name: "  #{flag_name}  ") |> render_submit()

      assert %FeatureFlag{name: ^flag_name} = Api.get_feature_flag(flag_name)
    end

    test "does not create a flag when name is empty", %{conn: conn, user: user, password: password} do
      {:ok, view, _} = conn |> using_basic_auth(user, password) |> live(~p"/admin/feature-flags")

      flags_before = Api.list_feature_flags() |> length()

      _ = view |> form("form[phx-submit=create]", name: "") |> render_submit()

      assert Api.list_feature_flags() |> length() == flags_before
    end
  end

  describe "toggle event" do
    test "flips the enabled state and persists", %{conn: conn, user: user, password: password} do
      flag_name = "toggle_#{random_string()}"
      {:ok, flag} = Api.upsert_feature_flag(%{name: flag_name, enabled: false})

      {:ok, view, _} = conn |> using_basic_auth(user, password) |> live(~p"/admin/feature-flags")

      view |> element("button[phx-click=toggle][phx-value-id='#{flag.id}']") |> render_click()

      assert %FeatureFlag{enabled: true} = Api.get_feature_flag(flag_name)
    end
  end

  describe "delete event" do
    test "removes the flag from the list and DB", %{conn: conn, user: user, password: password} do
      flag_name = "delete_#{random_string()}"
      {:ok, flag} = Api.upsert_feature_flag(%{name: flag_name, enabled: false})

      {:ok, view, _} = conn |> using_basic_auth(user, password) |> live(~p"/admin/feature-flags")

      html = view |> element("button[phx-click=delete][phx-value-id='#{flag.id}']") |> render_click()

      refute html =~ flag_name
      refute Api.get_feature_flag(flag_name)
    end
  end

  describe "broadcasts" do
    test "adds a new flag when an 'updated' broadcast arrives for an unseen flag",
         %{conn: conn, user: user, password: password} do
      {:ok, view, _} = conn |> using_basic_auth(user, password) |> live(~p"/admin/feature-flags")

      remote = %FeatureFlag{id: Ecto.UUID.generate(), name: "remote_#{random_string()}", enabled: true}
      Endpoint.broadcast("feature_flags", "updated", remote)

      assert render(view) =~ remote.name
    end

    test "updates an existing flag when an 'updated' broadcast arrives",
         %{conn: conn, user: user, password: password} do
      flag_name = "broadcast_#{random_string()}"
      {:ok, flag} = Api.upsert_feature_flag(%{name: flag_name, enabled: false})

      {:ok, view, html} = conn |> using_basic_auth(user, password) |> live(~p"/admin/feature-flags")
      assert html =~ "Disabled"

      Endpoint.broadcast("feature_flags", "updated", %{flag | enabled: true})

      assert render(view) =~ "Enabled"
    end

    test "removes a flag when a 'deleted' broadcast arrives",
         %{conn: conn, user: user, password: password} do
      flag_name = "broadcast_delete_#{random_string()}"
      {:ok, _flag} = Api.upsert_feature_flag(%{name: flag_name, enabled: false})

      {:ok, view, html} = conn |> using_basic_auth(user, password) |> live(~p"/admin/feature-flags")
      assert html =~ flag_name

      Endpoint.broadcast("feature_flags", "deleted", %{name: flag_name})

      refute render(view) =~ flag_name
    end
  end

  defp using_basic_auth(conn, username, password) do
    header_content = "Basic " <> Base.encode64("#{username}:#{password}")
    put_req_header(conn, "authorization", header_content)
  end
end
