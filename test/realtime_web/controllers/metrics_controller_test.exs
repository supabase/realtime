defmodule RealtimeWeb.MetricsControllerTest do
  # Usage of Clustered
  # Also changing Application env
  use RealtimeWeb.ConnCase, async: false
  alias Realtime.GenRpc

  import ExUnit.CaptureLog
  use Mimic

  setup_all do
    metrics_tags = %{
      region: "ap-southeast-2",
      host: "anothernode@something.com",
      id: "someid"
    }

    {:ok, _} =
      Clustered.start(nil,
        extra_config: [{:realtime, :region, "ap-southeast-2"}, {:realtime, :metrics_tags, metrics_tags}]
      )

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

      assert response =~ "region=\"ap-southeast-2\""
      assert response =~ "region=\"us-east-1\""
    end

    test "returns 200 and log on timeout", %{conn: conn} do
      Mimic.stub(GenRpc, :call, fn node, mod, func, args, opts ->
        if node != node() do
          {:error, :rpc_error, :timeout}
        else
          call_original(GenRpc, :call, [node, mod, func, args, opts])
        end
      end)

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

  describe "GET /metrics/:region" do
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
               |> get(~p"/metrics/ap-southeast-2")
               |> text_response(200)

      # Check prometheus like metrics
      assert response =~
               "# HELP beam_system_schedulers_online_info The number of scheduler threads that are online."

      assert response =~ "region=\"ap-southeast-2\""
      refute response =~ "region=\"us-east-1\""
    end

    test "returns 200 and log on timeout", %{conn: conn} do
      Mimic.stub(GenRpc, :call, fn _node, _mod, _func, _args, _opts ->
        {:error, :rpc_error, :timeout}
      end)

      log =
        capture_log(fn ->
          assert response =
                   conn
                   |> get(~p"/metrics/ap-southeast-2")
                   |> text_response(200)

          assert response == ""
        end)

      assert log =~ "Cannot fetch metrics from the node"
    end

    test "returns 403 when authorization header is missing", %{conn: conn} do
      assert conn
             |> delete_req_header("authorization")
             |> get(~p"/metrics/ap-southeast-2")
             |> response(403)
    end

    test "returns 403 when authorization header is wrong", %{conn: conn} do
      token = generate_jwt_token("bad_secret", %{})

      assert _ =
               conn
               |> put_req_header("authorization", "Bearer #{token}")
               |> get(~p"/metrics/ap-southeast-2")
               |> response(403)
    end
  end
end
