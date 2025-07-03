defmodule RealtimeWeb.MetricsControllerTest do
  # Usage of Clustered
  # Also changing Application env
  use RealtimeWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  setup_all do
    {:ok, _} = Clustered.start(nil, extra_config: [{:realtime, :region, "ap-southeast-2"}])
    :ok
  end

  describe "GET /metrics" do
    setup %{conn: conn} do
      # The metrics pipeline requires authentication
      jwt_secret = Application.fetch_env!(:realtime, :metrics_jwt_secret)
      token = generate_jwt_token(jwt_secret, %{})
      authenticated_conn = put_req_header(conn, "authorization", "Bearer #{token}")

      {:ok, conn: authenticated_conn}
    end

    test "returns 200", %{conn: conn} do
      assert response =
               conn
               |> get(~p"/metrics")
               |> text_response(200)

      # Check prometheus like metrics
      assert response =~
               "# HELP beam_system_schedulers_online_info The number of scheduler threads that are online."

      assert response =~ "region=\"ap-southeast-2"
      assert response =~ "region=\"us-east-1"
    end

    test "returns 200 and log on timeout", %{conn: conn} do
      current_value = Application.get_env(:realtime, :metrics_rpc_timeout)
      on_exit(fn -> Application.put_env(:realtime, :metrics_rpc_timeout, current_value) end)
      Application.put_env(:realtime, :metrics_rpc_timeout, 0)

      log =
        capture_log(fn ->
          assert response =
                   conn
                   |> get(~p"/metrics")
                   |> text_response(200)

          # Check prometheus like metrics
          assert response =~
                   "# HELP beam_system_schedulers_online_info The number of scheduler threads that are online."

          refute response =~ "region=\"ap-southeast-2"
          assert response =~ "region=\"us-east-1"
        end)

      assert log =~ "Cannot fetch metrics from the node"
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
