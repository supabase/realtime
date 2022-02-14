defmodule MultiplayerWeb.TenantController do
  use MultiplayerWeb, :controller
  use PhoenixSwagger
  alias Multiplayer.Api
  alias Multiplayer.Api.Tenant

  action_fallback MultiplayerWeb.FallbackController

  swagger_path :index do
    PhoenixSwagger.Path.get("/api/tenants")
    tag("Tenants")
    response(200, "Success", :TenantsResponse)
  end

  def index(conn, _params) do
    tenants = Api.list_tenants()
    render(conn, "index.json", tenants: tenants)
  end

  swagger_path :create do
    PhoenixSwagger.Path.post("/api/tenants")
    tag("Tenants")

    parameters do
      tenant(:body, Schema.ref(:TenantReq), "", required: true)
    end

    response(200, "Success", :TenantResponse)
  end

  def create(conn, %{"tenant" => tenant_params}) do
    with {:ok, %Tenant{} = tenant} <- Api.create_tenant(tenant_params) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", Routes.tenant_path(conn, :show, tenant))
      |> render("show.json", tenant: tenant)
    end
  end

  swagger_path :show do
    PhoenixSwagger.Path.get("/api/tenants/{id}")
    tag("Tenants")

    parameter(:id, :path, :string, "",
      required: true,
      example: "72ac258c-8dcd-4f0d-992f-9b6bab5e6d19"
    )

    response(200, "Success", :TenantResponse)
  end

  def show(conn, %{"id" => id}) do
    tenant = Api.get_tenant!(id)
    render(conn, "show.json", tenant: tenant)
  end

  swagger_path :update do
    PhoenixSwagger.Path.put("/api/tenants/{id}")
    tag("Tenants")

    parameters do
      id(:path, :string, "", required: true, example: "72ac258c-8dcd-4f0d-992f-9b6bab5e6d19")
      tenant(:body, Schema.ref(:TenantReq), "", required: true)
    end

    response(200, "Success", :TenantResponse)
  end

  def update(conn, %{"id" => id, "tenant" => tenant_params}) do
    tenant = Api.get_tenant!(id)

    with {:ok, %Tenant{} = tenant} <- Api.update_tenant(tenant, tenant_params) do
      render(conn, "show.json", tenant: tenant)
    end
  end

  swagger_path :delete do
    PhoenixSwagger.Path.delete("/api/tenants/{id}")
    tag("Tenants")
    description("Delete a tenant by ID")

    parameter(:id, :path, :string, "Tenant ID",
      required: true,
      example: "123e4567-e89b-12d3-a456-426655440000"
    )

    response(200, "No Content - Deleted Successfully")
  end

  def delete(conn, %{"id" => id}) do
    tenant = Api.get_tenant!(id)

    with {:ok, %Tenant{}} <- Api.delete_tenant(tenant) do
      send_resp(conn, :no_content, "")
    end
  end

  def swagger_definitions do
    %{
      Tenant:
        swagger_schema do
          title("Tenant")

          properties do
            id(:string, "", required: false, example: "72ac258c-8dcd-4f0d-992f-9b6bab5e6d19")
            name(:string, "", required: false, example: "tenant1")
            jwt_secret(:string, "", required: false, example: "big_secret")
            external_id(:string, "", required: false, example: "okumviwlylkmpkoicbrc")
            active(:boolean, "", required: false, example: true)
          end
        end,
      TenantReq:
        swagger_schema do
          title("TenantReq")

          properties do
            name(:string, "", required: false, example: "tenant1")
            jwt_secret(:string, "", required: true, example: "big_secret")
            external_id(:string, "", required: true, example: "okumviwlylkmpkoicbrc")
            active(:boolean, "", required: false, example: true)
            db_host(:string, "", required: true, example: "db.awesome.supabase.net")
            db_port(:string, "", required: true, example: "6543")
            db_name(:string, "", required: true, example: "postgres")
            db_user(:string, "", required: true, example: "postgres")
            db_password(:string, "", required: true, example: "postgres")
          end
        end,
      Tenants:
        swagger_schema do
          title("Tenants")
          type(:array)
          items(Schema.ref(:Tenant))
        end,
      TenantsResponse:
        swagger_schema do
          title("TenantsResponse")
          property(:data, Schema.ref(:Tenants), "")
        end,
      TenantResponse:
        swagger_schema do
          title("TenantResponse")
          property(:data, Schema.ref(:Tenant), "")
        end
    }
  end
end
