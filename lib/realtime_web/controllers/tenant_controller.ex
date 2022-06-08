defmodule RealtimeWeb.TenantController do
  use RealtimeWeb, :controller
  use PhoenixSwagger
  alias Realtime.Api
  alias Realtime.Api.Tenant
  alias PhoenixSwagger.{Path, Schema}

  action_fallback(RealtimeWeb.FallbackController)

  swagger_path :index do
    Path.get("/api/tenants")
    tag("Tenants")
    response(200, "Success", :TenantsResponse)
  end

  def index(conn, _params) do
    tenants = Api.list_tenants()
    render(conn, "index.json", tenants: tenants)
  end

  def create(conn, %{"tenant" => tenant_params}) do
    extensions =
      Enum.reduce(tenant_params["extensions"], [], fn
        %{"type" => type, "settings" => settings}, acc ->
          [%{"type" => type, "settings" => settings} | acc]

        _e, acc ->
          acc
      end)

    with {:ok, %Tenant{} = tenant} <-
           Api.create_tenant(%{tenant_params | "extensions" => extensions}) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", Routes.tenant_path(conn, :show, tenant))
      |> render("show.json", tenant: tenant)
    end
  end

  swagger_path :show do
    Path.get("/api/tenants/{external_id}")
    tag("Tenants")

    parameter(:external_id, :path, :string, "",
      required: true,
      example: "72ac258c-8dcd-4f0d-992f-9b6bab5e6d19"
    )

    response(200, "Success", :TenantResponse)
  end

  def show(conn, %{"id" => id}) do
    id
    |> Api.get_tenant_by_external_id()
    |> case do
      %Tenant{} = tenant ->
        render(conn, "show.json", tenant: tenant)

      nil ->
        conn
        |> put_status(404)
        |> render("no_found.json", tenant: nil)
    end
  end

  swagger_path :update do
    Path.put("/api/tenants/{external_id}")
    tag("Tenants")

    parameters do
      external_id(:path, :string, "",
        required: true,
        maxLength: 255,
        example: "72ac258c-8dcd-4f0d-992f-9b6bab5e6d19"
      )

      tenant(:body, Schema.ref(:TenantReq), "", required: true)
    end

    response(200, "Success", :TenantResponse)
  end

  def update(conn, %{"id" => id, "tenant" => tenant_params}) do
    case Api.get_tenant_by_external_id(id) do
      nil ->
        Cachex.del(:tenants, id)
        create(conn, %{"tenant" => Map.put(tenant_params, "external_id", id)})

      tenant ->
        with {:ok, %Tenant{} = tenant} <- Api.update_tenant(tenant, tenant_params) do
          render(conn, "show.json", tenant: tenant)
        end
    end
  end

  swagger_path :delete do
    Path.delete("/api/tenants/{external_id}")
    tag("Tenants")
    description("Delete a tenant by ID")

    parameter(:id, :path, :string, "Tenant ID",
      required: true,
      example: "123e4567-e89b-12d3-a456-426655440000"
    )

    response(200, "No Content - Deleted Successfully")
  end

  def delete(conn, %{"id" => id}) do
    Api.delete_tenant_by_external_id(id)
    send_resp(conn, 204, "")
  end

  def swagger_definitions do
    %{
      Tenant:
        swagger_schema do
          title("Tenant")

          properties do
            id(:string, "", required: false, example: "72ac258c-8dcd-4f0d-992f-9b6bab5e6d19")
            name(:string, "", required: false, example: "tenant1")
            external_id(:string, "", required: false, example: "okumviwlylkmpkoicbrc")
            inserted_at(:string, "", required: false, example: "2022-02-16T20:41:47")
            max_concurrent_users(:integer, "", required: false, example: 10_000)
            extensions(:array, "", required: true, items: Schema.ref(:ExtensionPostgres))
          end
        end,
      ExtensionPostgres:
        swagger_schema do
          title("ExtensionPostgres")

          properties do
            type(:string, "", required: true, example: "postgres")
            inserted_at(:string, "", required: false, example: "2022-02-16T20:41:47")
            updated_at(:string, "", required: false, example: "2022-02-16T20:41:47")

            settings(:object, "",
              required: true,
              properties: %{
                db_host: %Schema{type: :string, example: "some encrypted value"},
                db_name: %Schema{type: :string, example: "some encrypted value"},
                db_password: %Schema{type: :string, example: "some encrypted value"},
                db_port: %Schema{type: :string, example: "some encrypted value"},
                db_user: %Schema{type: :string, example: "some encrypted value"},
                poll_interval_ms: %Schema{type: :integer, example: 100},
                poll_max_changes: %Schema{type: :integer, example: 100},
                poll_max_record_bytes: %Schema{type: :integer, example: 1_048_576},
                publication: %Schema{type: :string, example: "supabase_realtime"},
                region: %Schema{type: :string, example: "us-east-1"},
                slot_name: %Schema{
                  type: :string,
                  example: "supabase_realtime_replication_slot"
                }
              }
            )
          end
        end,
      TenantReq:
        swagger_schema do
          title("TenantReq")

          properties do
            name(:string, "", required: false, example: "tenant1", maxLength: 255)
            max_concurrent_users(:integer, "", required: false, example: 10_000, default: 10_000)
            extensions(:array, "", required: true, items: Schema.ref(:ExtensionPostgresReq))
          end
        end,
      ExtensionPostgresReq:
        swagger_schema do
          title("ExtensionPostgresReq")

          properties do
            type(:string, "", required: true, example: "postgres")

            settings(:object, "",
              required: true,
              properties: %{
                db_host: %Schema{type: :string, required: true, example: "127.0.0.1"},
                db_name: %Schema{type: :string, required: true, example: "postgres"},
                db_password: %Schema{
                  type: :string,
                  required: true,
                  example: "postgres"
                },
                db_user: %Schema{type: :string, required: true, example: "postgres"},
                db_port: %Schema{type: :string, required: true, example: "6432"},
                region: %Schema{type: :string, required: true, example: "us-east-1"},
                poll_interval_ms: %Schema{type: :integer, default: 100, example: 100},
                poll_max_changes: %Schema{type: :integer, default: 100, example: 100},
                poll_max_record_bytes: %Schema{
                  type: :integer,
                  default: 1_048_576,
                  example: 1_048_576
                },
                publication: %Schema{
                  type: :string,
                  default: "supabase_realtime",
                  example: "supabase_realtime"
                },
                slot_name: %Schema{
                  type: :string,
                  default: "supabase_realtime_replication_slot",
                  example: "supabase_realtime_replication_slot"
                }
              }
            )
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
