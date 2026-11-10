defmodule RealtimeWeb.PageControllerTest do
  use RealtimeWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  test "GET / renders the console page", %{conn: conn} do
    conn = get(conn, "/")
    assert html_response(conn, 200) =~ "Inspector - Supabase Realtime"
  end

  test "GET /inspector redirects to / preserving query params", %{conn: conn} do
    conn = get(conn, "/inspector?channel=room_a")
    assert redirected_to(conn) == "/?channel=room_a"
  end

  test "GET /inspector/new redirects to /", %{conn: conn} do
    conn = get(conn, "/inspector/new")
    assert redirected_to(conn) == "/"
  end

  test "GET /healthcheck returns ok status", %{conn: conn} do
    conn = get(conn, "/healthcheck")
    assert text_response(conn, 200) == "ok"
  end

  describe "GET /ready" do
    setup do
      original = Application.get_env(:realtime, :readiness_min_nodes_per_region)
      Realtime.Readiness.reset()

      on_exit(fn ->
        Application.put_env(:realtime, :readiness_min_nodes_per_region, original)
        Application.put_env(:realtime, :shutdown_in_progress, false)
        Realtime.Readiness.reset()
      end)
    end

    test "returns ok when no minimum is configured", %{conn: conn} do
      Application.put_env(:realtime, :readiness_min_nodes_per_region, [])
      conn = get(conn, "/ready")
      assert text_response(conn, 200) == "ok"
    end

    test "returns 503 while it waits for nodes, with the regions in the log only", %{conn: conn} do
      # A region no other test uses: fake nodes from other tests leave RegionNodes asynchronously.
      region = "test-region-#{System.unique_integer([:positive])}"
      Application.put_env(:realtime, :readiness_min_nodes_per_region, [{"us-east-1", 1}, {region, 1}])

      log =
        capture_log(fn ->
          conn = get(conn, "/ready")
          assert text_response(conn, 503) == "not ready"
        end)

      assert log =~ "Readiness: waiting for nodes: #{region} 0/1"
      refute log =~ "us-east-1 "
    end

    test "returns 503 while shutting down", %{conn: conn} do
      Application.put_env(:realtime, :readiness_min_nodes_per_region, [])
      Application.put_env(:realtime, :shutdown_in_progress, true)
      conn = get(conn, "/ready")
      assert text_response(conn, 503) == "shutting down"
    end

    test "is not logged when DISABLE_HEALTHCHECK_LOGGING is true", %{conn: conn} do
      original = Application.get_env(:realtime, :disable_healthcheck_logging, false)
      on_exit(fn -> Application.put_env(:realtime, :disable_healthcheck_logging, original) end)
      Application.put_env(:realtime, :disable_healthcheck_logging, true)
      Application.put_env(:realtime, :readiness_min_nodes_per_region, [])

      log = capture_log(fn -> assert text_response(get(conn, "/ready"), 200) == "ok" end)
      refute log =~ "GET /ready"
    end
  end

  describe "GET /healthcheck logging behavior" do
    setup do
      original_value = Application.get_env(:realtime, :disable_healthcheck_logging, false)
      on_exit(fn -> Application.put_env(:realtime, :disable_healthcheck_logging, original_value) end)
      :ok
    end

    test "logs request when DISABLE_HEALTHCHECK_LOGGING is false", %{conn: conn} do
      Application.put_env(:realtime, :disable_healthcheck_logging, false)

      log =
        capture_log(fn ->
          conn = get(conn, "/healthcheck")
          assert text_response(conn, 200) == "ok"
        end)

      assert log =~ "GET /healthcheck"
    end

    test "does not log request when DISABLE_HEALTHCHECK_LOGGING is true", %{conn: conn} do
      Application.put_env(:realtime, :disable_healthcheck_logging, true)

      log =
        capture_log(fn ->
          conn = get(conn, "/healthcheck")
          assert text_response(conn, 200) == "ok"
        end)

      refute log =~ "GET /healthcheck"
    end

    test "logs request when DISABLE_HEALTHCHECK_LOGGING is not set (default)", %{conn: conn} do
      Application.delete_env(:realtime, :disable_healthcheck_logging)

      log =
        capture_log(fn ->
          conn = get(conn, "/healthcheck")
          assert text_response(conn, 200) == "ok"
        end)

      assert log =~ "GET /healthcheck"
    end
  end
end
