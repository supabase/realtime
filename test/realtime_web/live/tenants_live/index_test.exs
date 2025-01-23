defmodule RealtimeWeb.TenantsLive.IndexTest do
  use RealtimeWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "TenantsLive Index" do
    setup do
      user = random_string()
      password = random_string()

      System.put_env("DASHBOARD_USER", user)
      System.put_env("DASHBOARD_PASSWORD", password)

      on_exit(fn ->
        System.delete_env("DASHBOARD_USER")
        System.delete_env("DASHBOARD_PASSWORD")
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
  end

  defp using_basic_auth(conn, username, password) do
    header_content = "Basic " <> Base.encode64("#{username}:#{password}")
    put_req_header(conn, "authorization", header_content)
  end
end
