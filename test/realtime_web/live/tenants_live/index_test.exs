defmodule RealtimeWeb.TenantsLive.IndexTest do
  use RealtimeWeb.ConnCase
  import Phoenix.LiveViewTest
  import Generators
  import Mimic

  describe "TenantsLive Index with basic_auth" do
    setup do
      user = random_string()
      password = random_string()

      Application.put_env(:realtime, :dashboard_auth, :basic_auth)
      Application.put_env(:realtime, :dashboard_credentials, {user, password})

      on_exit(fn ->
        Application.delete_env(:realtime, :dashboard_auth)
        Application.delete_env(:realtime, :dashboard_credentials)
      end)

      %{user: user, password: password}
    end

    test "renders tenant view", %{conn: conn, user: user, password: password} do
      {:ok, _view, html} =
        conn |> using_basic_auth(user, password) |> live(~p"/admin/tenants")

      assert html =~ "Listing all Supabase Realtime tenants."
    end

    test "returns 401 if no credentials", %{conn: conn} do
      assert conn |> get(~p"/admin/tenants") |> response(401)
    end

    test "returns 401 with wrong credentials", %{conn: conn} do
      assert conn |> using_basic_auth("wrong", "wrong") |> get(~p"/admin/tenants") |> response(401)
    end
  end

  describe "TenantsLive Index with zta" do
    setup do
      Application.put_env(:realtime, :dashboard_auth, :zta)

      on_exit(fn -> Application.delete_env(:realtime, :dashboard_auth) end)
    end

    test "renders tenant view with valid cf token", %{conn: conn} do
      stub(NimbleZTA.Cloudflare, :authenticate, fn _name, conn -> {conn, %{email: "user@example.com"}} end)

      {:ok, _view, html} = live(conn, ~p"/admin/tenants")

      assert html =~ "Listing all Supabase Realtime tenants."
    end

    test "returns 403 without cf token", %{conn: conn} do
      stub(NimbleZTA.Cloudflare, :authenticate, fn _name, conn -> {conn, nil} end)

      assert conn |> get(~p"/admin/tenants") |> response(403)
    end

    test "returns 503 when zta service is unavailable", %{conn: conn} do
      stub(NimbleZTA.Cloudflare, :authenticate, fn _name, _conn -> exit(:noproc) end)

      assert conn |> get(~p"/admin/tenants") |> response(503)
    end
  end

  defp using_basic_auth(conn, username, password) do
    header_content = "Basic " <> Base.encode64("#{username}:#{password}")
    put_req_header(conn, "authorization", header_content)
  end
end
