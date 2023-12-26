defmodule RealtimeWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :realtime

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_realtime_key",
    signing_salt: "5OUq5X4H"
  ]

  socket "/realtime/v1", RealtimeWeb.UserSocket,
    websocket: [
      connect_info: [:peer_data, :uri, :x_headers],
      fullsweep_after: 20,
      max_frame_size: 8_000_000,
      serializer: [
        {Phoenix.Socket.V1.JSONSerializer, "~> 1.0.0"},
        {Phoenix.Socket.V2.JSONSerializer, "~> 2.0.0"}
      ]
    ],
    longpoll: true

  socket "/socket", RealtimeWeb.UserSocket,
    websocket: [
      connect_info: [:peer_data, :uri, :x_headers],
      fullsweep_after: 20,
      max_frame_size: 8_000_000,
      serializer: [
        {Phoenix.Socket.V1.JSONSerializer, "~> 1.0.0"},
        {Phoenix.Socket.V2.JSONSerializer, "~> 2.0.0"}
      ]
    ],
    longpoll: true

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  plug Plug.Static,
    at: "/",
    from: :realtime,
    gzip: false,
    only: RealtimeWeb.static_paths()

  # plug PromEx.Plug, path: "/metrics", prom_ex_module: Realtime.PromEx

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug RealtimeWeb.Router
end
