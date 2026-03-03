defmodule RealtimeWeb.ApiSpec do
  @moduledoc false

  alias OpenApiSpex.Components
  alias OpenApiSpex.Info
  alias OpenApiSpex.OpenApi
  alias OpenApiSpex.Paths
  alias OpenApiSpex.SecurityScheme
  alias OpenApiSpex.Server
  alias OpenApiSpex.ServerVariable

  alias RealtimeWeb.Router

  @behaviour OpenApi

  @api_url Application.compile_env(:realtime, :api_url, "https://{tenant}.supabase.co/realtime/v1")

  @impl OpenApi
  def spec do
    url = @api_url

    %OpenApi{
      servers: [
        %Server{
          url: url,
          variables: %{"tenant" => %ServerVariable{default: "tenant"}}
        }
      ],
      info: %Info{
        title: to_string(Application.spec(:realtime, :description)),
        version: to_string(Application.spec(:realtime, :vsn))
      },
      paths: Paths.from_router(Router),
      components: %Components{
        securitySchemes: %{"authorization" => %SecurityScheme{type: "http", scheme: "bearer"}}
      }
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
