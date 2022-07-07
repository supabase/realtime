defmodule RealtimeWeb.Router do
  use RealtimeWeb, :router
  import RealtimeWeb.ChannelsAuthorization, only: [authorize: 2]

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :check_auth, :api_jwt_secret
  end

  pipeline :metrics do
    plug :check_auth, :metrics_jwt_secret
  end

  scope "/", RealtimeWeb do
    pipe_through :browser

    get "/", PageController, :index
  end

  # get "/metrics/:id", RealtimeWeb.TenantMetricsController, :index

  scope "/metrics", RealtimeWeb do
    pipe_through :metrics

    get "/", MetricsController, :index
  end

  scope "/api", RealtimeWeb do
    pipe_through :api

    resources "/tenants", TenantController do
      post "/reload", TenantController, :reload, as: :reload
    end
  end

  scope "/api/swagger" do
    forward "/", PhoenixSwagger.Plug.SwaggerUI,
      otp_app: :realtime,
      swagger_file: "swagger.json"
  end

  defp check_auth(conn, secret_key) do
    secret = Application.fetch_env!(:realtime, secret_key)

    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, _claims} <- authorize(token, secret) do
      conn
    else
      _ ->
        conn
        |> send_resp(403, "")
        |> halt()
    end
  end

  def swagger_info do
    %{
      schemes: ["http", "https"],
      info: %{
        version: "1.0",
        title: "Realtime",
        description: "API Documentation for Realtime v1",
        termsOfService: "Open for public"
      },
      consumes: ["application/json"],
      produces: ["application/json"],
      tags: [
        %{name: "Tenants"}
      ]
    }
  end

  # Enables LiveDashboard only for development
  #
  # If you want to use the LiveDashboard in production, you should put
  # it behind authentication and allow only admins to access it.
  # If your application does not have an admins-only section yet,
  # you can use Plug.BasicAuth to set up some basic authentication
  # as long as you are also using SSL (which you should anyway).
  if Mix.env() in [:dev, :test] do
    import Phoenix.LiveDashboard.Router

    scope "/" do
      pipe_through :browser
      live_dashboard "/dashboard", metrics: RealtimeWeb.Telemetry
    end
  end
end
