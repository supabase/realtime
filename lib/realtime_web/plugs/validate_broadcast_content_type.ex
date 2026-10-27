defmodule RealtimeWeb.Plugs.ValidateBroadcastContentType do
  @moduledoc """
  Validates the request `Content-Type` for the broadcast-single endpoint.

  Allowed: `application/json` and `application/octet-stream` (optionally with
  parameters such as `; charset=utf-8`).

  A missing header or any other media type is rejected with a 415 response
  carrying a JSON body. Without the header `Plug.Parsers` never reads the body,
  so the payload would otherwise be silently dropped.
  """
  import Plug.Conn

  @allowed ["json", "octet-stream"]

  def init(opts), do: opts

  def call(conn, _opts) do
    with [content_type | _] <- get_req_header(conn, "content-type"),
         {:ok, "application", subtype, _params} when subtype in @allowed <-
           Plug.Conn.Utils.content_type(content_type) do
      conn
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          415,
          Jason.encode!(%{
            error: "Unsupported Media Type. Use application/json or application/octet-stream"
          })
        )
        |> halt()
    end
  end
end
