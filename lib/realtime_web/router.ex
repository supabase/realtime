defmodule RealtimeWeb.Router do
  use RealtimeWeb, :router

  require Logger

  import RealtimeWeb.ChannelsAuthorization, only: [authorize: 2]

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, {RealtimeWeb.LayoutView, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :check_auth, :api_jwt_secret
  end

  pipeline :tenant_api do
    plug :accepts, ["json"]
    plug RealtimeWeb.Plugs.AssignTenant
    plug RealtimeWeb.Plugs.RateLimiter
  end

  pipeline :dashboard_admin do
    plug :dashboard_basic_auth
  end

  pipeline :metrics do
    plug :check_auth, :metrics_jwt_secret
  end

  pipeline :openapi do
    plug(OpenApiSpex.Plug.PutApiSpec, module: RealtimeWeb.ApiSpec)
  end

  scope "/", RealtimeWeb do
    pipe_through :browser

    live "/", PageLive.Index, :index
    live "/inspector", InspectorLive.Index, :index
    live "/inspector/new", InspectorLive.Index, :new
    live "/status", StatusLive.Index, :index
  end

  scope "/swaggerui" do
    pipe_through(:browser)
    get("/", OpenApiSpex.Plug.SwaggerUI, path: "/api/openapi")
  end

  scope "/admin", RealtimeWeb do
    pipe_through :browser

    unless Mix.env() in [:dev, :test] do
      pipe_through :dashboard_admin
    end

    live "/", AdminLive.Index, :index
    live "/tenants", TenantsLive.Index, :index
  end

  scope "/metrics", RealtimeWeb do
    pipe_through :metrics

    get "/", MetricsController, :index
  end

  scope "/api" do
    pipe_through :openapi

    get "/openapi", OpenApiSpex.Plug.RenderSpec, []
  end

  scope "/api", RealtimeWeb do
    pipe_through :api

    resources "/tenants", TenantController, param: "tenant_id", except: [:edit, :new]
    post "/tenants/:tenant_id/reload", TenantController, :reload
  end

  scope "/api", RealtimeWeb do
    pipe_through :tenant_api

    get "/ping", PingController, :ping
  end

  # Enables LiveDashboard only for development
  #
  # If you want to use the LiveDashboard in production, you should put
  # it behind authentication and allow only admins to access it.
  # If your application does not have an admins-only section yet,
  # you can use Plug.BasicAuth to set up some basic authentication
  # as long as you are also using SSL (which you should anyway).
  scope "/admin" do
    pipe_through :browser

    unless Mix.env() in [:dev, :test] do
      pipe_through :dashboard_admin
    end

    live_dashboard "/dashboard",
      ecto_repos: [
        Realtime.Repo,
        Realtime.Repo.Replica.FRA,
        Realtime.Repo.Replica.IAD,
        Realtime.Repo.Replica.SIN,
        Realtime.Repo.Replica.SJC
      ],
      ecto_psql_extras_options: [long_running_queries: [threshold: "200 milliseconds"]],
      metrics: RealtimeWeb.Telemetry
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

  defp dashboard_basic_auth(conn, _opts) do
    user = System.fetch_env!("DASHBOARD_USER")
    password = System.fetch_env!("DASHBOARD_PASSWORD")
    Plug.BasicAuth.basic_auth(conn, username: user, password: password)
  end
end
