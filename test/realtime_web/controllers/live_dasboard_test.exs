defmodule RealtimeWeb.LiveDashboardTest do
  use RealtimeWeb.ConnCase
  import Generators

  describe "live_dashboard" do
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

    test "with credetentials renders view", %{
      conn: conn,
      user: user,
      password: password
    } do
      path =
        conn
        |> using_basic_auth(user, password)
        |> get("/admin/dashboard")
        |> redirected_to(302)

      conn = conn |> recycle() |> using_basic_auth(user, password) |> get(path)

      assert html_response(conn, 200) =~ "Dashboard"
    end

    test "without credetentials returns 401", %{conn: conn} do
      assert conn |> get("/admin/dashboard") |> response(401)
    end
  end

  defp using_basic_auth(conn, username, password) do
    header_content = "Basic " <> Base.encode64("#{username}:#{password}")
    put_req_header(conn, "authorization", header_content)
  end
end
