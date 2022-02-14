defmodule MultiplayerWeb.ScopeController do
  use MultiplayerWeb, :controller
  use PhoenixSwagger
  alias Multiplayer.Api
  alias Multiplayer.Api.Scope

  action_fallback(MultiplayerWeb.FallbackController)

  swagger_path :index do
    PhoenixSwagger.Path.get("/api/scopes")
    tag("Scopes")
    response(200, "Success", :ScopesResponse)
  end

  def index(conn, _params) do
    scopes = Api.list_scopes()
    render(conn, "index.json", scopes: scopes)
  end

  swagger_path :create do
    PhoenixSwagger.Path.post("/api/scopes")
    tag("Scopes")

    parameters do
      scope(:body, Schema.ref(:ScopeReq), "", required: true)
    end

    response(200, "Success", :ScopeResponse)
  end

  def create(conn, %{"scope" => scope_params}) do
    with {:ok, %Scope{} = scope} <- Api.create_scope(scope_params) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", Routes.scope_path(conn, :show, scope))
      |> render("show.json", scope: scope)
    end
  end

  swagger_path :show do
    PhoenixSwagger.Path.get("/api/scopes/{id}")
    tag("Scopes")

    parameter(:id, :path, :string, "",
      required: true,
      example: "0f4004c0-1ce8-454d-b88a-c8a9be93dc24"
    )

    response(200, "Success", :ScopeResponse)
  end

  def show(conn, %{"id" => id}) do
    scope = Api.get_scope!(id)
    render(conn, "show.json", scope: scope)
  end

  swagger_path :update do
    PhoenixSwagger.Path.put("/api/scopes/{id}")
    tag("Scopes")

    parameters do
      id(:path, :string, "", required: true, example: "0f4004c0-1ce8-454d-b88a-c8a9be93dc24")
      tenant(:body, Schema.ref(:ScopeReq), "", required: true)
    end

    response(200, "Success", :ScopeResponse)
  end

  def update(conn, %{"id" => id, "scope" => scope_params}) do
    scope = Api.get_scope!(id)

    with {:ok, %Scope{} = scope} <- Api.update_scope(scope, scope_params) do
      render(conn, "show.json", scope: scope)
    end
  end

  swagger_path :delete do
    PhoenixSwagger.Path.delete("/api/scopes/{id}")
    tag("Scopes")
    description("Delete a scope by ID")

    parameter(:id, :path, :string, "Scope ID",
      required: true,
      example: "0f4004c0-1ce8-454d-b88a-c8a9be93dc24"
    )

    response(200, "No Content - Deleted Successfully")
  end

  def delete(conn, %{"id" => id}) do
    scope = Api.get_scope!(id)

    with {:ok, %Scope{}} <- Api.delete_scope(scope) do
      send_resp(conn, :no_content, "")
    end
  end

  def swagger_definitions do
    %{
      Scope:
        swagger_schema do
          title("Scope")

          properties do
            id(:string, "", required: false, example: "0f4004c0-1ce8-454d-b88a-c8a9be93dc24")
            host(:string, "", required: false, example: "myawesomedomain.com")
            active(:boolean, "", required: false, example: true)

            tenant_id(:string, "",
              required: false,
              example: "72ac258c-8dcd-4f0d-992f-9b6bab5e6d19"
            )
          end
        end,
      ScopeReq:
        swagger_schema do
          title("ScopeReq")

          properties do
            host(:string, "", required: true, example: "myawesomedomain.com")
            active(:boolean, "", required: false, example: true)
            tenant_id(:string, "", required: true, example: "72ac258c-8dcd-4f0d-992f-9b6bab5e6d19")
          end
        end,
      Scopes:
        swagger_schema do
          title("Scopes")
          type(:array)
          items(Schema.ref(:Scope))
        end,
      ScopesResponse:
        swagger_schema do
          title("ScopesResponse")
          property(:data, Schema.ref(:Scopes), "")
        end,
      ScopeResponse:
        swagger_schema do
          title("ScopeResponse")
          property(:data, Schema.ref(:Scope), "")
        end
    }
  end
end
