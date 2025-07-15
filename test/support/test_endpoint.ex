defmodule TestEndpoint do
  use Phoenix.Endpoint, otp_app: :phoenix

  @session_config store: :cookie,
                  key: "_hello_key",
                  signing_salt: "change_me"

  socket("/socket", RealtimeWeb.UserSocket,
    websocket: [
      connect_info: [:peer_data, :uri, :x_headers],
      fullsweep_after: 20,
      max_frame_size: 8_000_000
    ]
  )

  plug(Plug.Session, @session_config)
  plug(:fetch_session)
  plug(Plug.CSRFProtection)
  plug(:put_session)

  defp put_session(conn, _) do
    conn
    |> put_session(:from_session, "123")
    |> send_resp(200, Plug.CSRFProtection.get_csrf_token())
  end
end
