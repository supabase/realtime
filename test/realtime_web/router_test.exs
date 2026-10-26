defmodule RealtimeWeb.RouterTest do
  use RealtimeWeb.ConnCase, async: true

  describe "CORS preflight for the broadcast API" do
    for path <- ["/api/broadcast", "/api/broadcast/my-topic/events/my-event"] do
      test "OPTIONS #{path} allows the headers realtime-js sends", %{conn: conn} do
        conn =
          conn
          |> put_req_header("origin", "https://example.com")
          |> put_req_header("access-control-request-method", "POST")
          |> put_req_header("access-control-request-headers", "apikey,authorization,content-type,x-client-info")
          |> options(unquote(path))

        assert conn.status == 200
        assert get_resp_header(conn, "access-control-allow-origin") == ["*"]

        assert get_resp_header(conn, "access-control-allow-headers") == [
                 "apikey,authorization,content-type,x-client-info"
               ]
      end
    end
  end
end
