defmodule RealtimeWeb.MetricsControllerTest do
  use RealtimeWeb.ConnCase

  describe "GET /metrics" do
    setup %{conn: conn} do
      # The metrics pipeline requires authentication
      jwt_secret = Application.fetch_env!(:realtime, :metrics_jwt_secret)
      token = generate_jwt_token(jwt_secret, %{})
      authenticated_conn = put_req_header(conn, "authorization", "Bearer #{token}")

      {:ok, conn: authenticated_conn}
    end

    test "returns 200 and metrics when tenant exists", %{conn: conn} do
      assert response =
               conn
               |> get(~p"/metrics")
               |> text_response(200)

      # Check prometheus like metrics
      assert response =~
               "# HELP beam_system_schedulers_online_info The number of scheduler threads that are online."
    end

    test "returns 403 when authorization header is missing", %{conn: conn} do
      assert conn
             |> delete_req_header("authorization")
             |> get(~p"/metrics")
             |> response(403)
    end

    test "returns 403 when authorization header is wrong", %{conn: conn} do
      token = generate_jwt_token("bad_secret", %{})

      assert _ =
               conn
               |> put_req_header("authorization", "Bearer #{token}")
               |> get(~p"/metrics")
               |> response(403)
    end
  end
end
