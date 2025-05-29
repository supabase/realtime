defmodule RealtimeWeb.Plugs.BaggageRequestIdTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias RealtimeWeb.Plugs.BaggageRequestId

  defp call(conn, opts) do
    BaggageRequestId.call(conn, BaggageRequestId.init(opts))
  end

  test "uses request id from baggage if valid" do
    conn =
      conn(:get, "/")
      |> put_req_header("baggage", "request-id=1234567890")
      |> call([])

    assert ["1234567890"] = get_resp_header(conn, "x-request-id")
    assert Logger.metadata()[:request_id] == "1234567890"
  end

  test "uses configured request id key from baggage" do
    conn =
      conn(:get, "/")
      |> put_req_header("baggage", "my-request-id=1234567890")
      |> call(baggage_key: "my-request-id")

    assert ["1234567890"] = get_resp_header(conn, "x-request-id")
    assert Logger.metadata()[:request_id] == "1234567890"
  end

  test "generates new request id if not valid from baggage: min size" do
    conn =
      conn(:get, "/")
      # too short
      |> put_req_header("baggage", "request-id=123")
      |> call([])

    [res_request_id] = get_resp_header(conn, "x-request-id")
    assert ^res_request_id = Logger.metadata()[:request_id]
    assert generated_request_id?(res_request_id)
    assert res_request_id != "123"
  end

  test "generates new request id if not valid from baggage: max size" do
    request_id = String.duplicate("0", 201)

    conn =
      conn(:get, "/")
      # too long
      |> put_req_header("baggage", "request-id=#{request_id}")
      |> call([])

    [res_request_id] = get_resp_header(conn, "x-request-id")
    assert ^res_request_id = Logger.metadata()[:request_id]
    assert generated_request_id?(res_request_id)
    assert res_request_id != request_id
  end

  test "generates new request id if there is no bahhage" do
    conn =
      conn(:get, "/")
      |> call([])

    [res_request_id] = get_resp_header(conn, "x-request-id")
    assert ^res_request_id = Logger.metadata()[:request_id]
    assert generated_request_id?(res_request_id)
  end

  test "generates new request id if not include inside baggage" do
    conn =
      conn(:get, "/")
      |> put_req_header("baggage", "something-else=123")
      |> call([])

    [res_request_id] = get_resp_header(conn, "x-request-id")
    assert ^res_request_id = Logger.metadata()[:request_id]
    assert generated_request_id?(res_request_id)
  end

  defp generated_request_id?(request_id) do
    Regex.match?(~r/\A[A-Za-z0-9-_]+\z/, request_id)
  end
end
