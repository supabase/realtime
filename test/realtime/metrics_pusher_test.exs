defmodule Realtime.MetricsPusherTest do
  use Realtime.DataCase, async: true
  import ExUnit.CaptureLog

  alias Realtime.MetricsPusher
  alias Plug.Conn

  setup {Req.Test, :verify_on_exit!}

  defp start_and_allow_pusher(opts) do
    pid = start_supervised!({MetricsPusher, opts})
    Req.Test.allow(MetricsPusher, self(), pid)
    {:ok, pid}
  end

  describe "start_link/1" do
    test "does not start when URL is missing" do
      opts = [enabled: true]
      assert :ignore = MetricsPusher.start_link(opts)
    end

    test "sends request successfully" do
      opts = [
        url: "https://example.com:8428/api/v1/write",
        user: "realtime",
        auth: "secret",
        interval: 10,
        timeout: 5000
      ]

      parent = self()

      Req.Test.expect(MetricsPusher, fn conn ->
        body = Req.Test.raw_body(conn)
        assert conn.method == "POST"
        assert is_binary(body)
        assert byte_size(body) > 0
        assert conn.scheme == :https
        assert conn.host == "example.com"
        assert conn.port == 8428
        assert conn.request_path == "/api/v1/write"
        assert Conn.get_req_header(conn, "authorization") == ["Basic #{Base.encode64("realtime:secret")}"]
        assert Conn.get_req_header(conn, "content-encoding") == ["snappy"]
        assert Conn.get_req_header(conn, "content-type") == ["application/x-protobuf"]
        assert Conn.get_req_header(conn, "x-prometheus-remote-write-version") == ["0.1.0"]

        send(parent, :req_called)
        Req.Test.text(conn, "")
      end)

      {:ok, _pid} = start_and_allow_pusher(opts)
      assert_receive :req_called, 100
    end

    test "sends request successfully without auth header" do
      opts = [
        url: "http://localhost:8428/api/v1/write",
        interval: 10,
        timeout: 5000
      ]

      parent = self()

      Req.Test.expect(MetricsPusher, fn conn ->
        body = Req.Test.raw_body(conn)
        assert is_binary(body)
        assert byte_size(body) > 0
        assert Conn.get_req_header(conn, "authorization") == []
        assert Conn.get_req_header(conn, "content-type") == ["application/x-protobuf"]
        assert Conn.get_req_header(conn, "content-encoding") == ["snappy"]

        send(parent, :req_called)
        Req.Test.text(conn, "")
      end)

      {:ok, _pid} = start_and_allow_pusher(opts)
      assert_receive :req_called, 100
    end

    test "when request receives non 2XX response" do
      opts = [
        url: "https://example.com:8428/api/v1/write",
        user: "realtime",
        auth: "secret",
        interval: 10,
        timeout: 5000
      ]

      parent = self()

      log =
        capture_log(fn ->
          Req.Test.expect(MetricsPusher, fn conn ->
            send(parent, :req_called)
            Conn.send_resp(conn, 500, "")
          end)

          {:ok, pid} = start_and_allow_pusher(opts)
          assert_receive :req_called, 100
          assert Process.alive?(pid)
          Process.sleep(100)
        end)

      assert log =~ "MetricsPusher: Failed to push metrics to"
    end

    test "when an error is raised" do
      opts = [
        url: "https://example.com:8428/api/v1/write",
        interval: 10,
        timeout: 5000
      ]

      parent = self()

      log =
        capture_log(fn ->
          Req.Test.expect(MetricsPusher, fn _conn ->
            send(parent, :req_called)
            raise RuntimeError, "unexpected error"
          end)

          {:ok, pid} = start_and_allow_pusher(opts)
          assert_receive :req_called, 100
          assert Process.alive?(pid)
          Process.sleep(100)
        end)

      assert log =~ "MetricsPusher: Exception during push: %RuntimeError{message: \"unexpected error\"}"
    end
  end
end
