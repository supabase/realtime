defmodule RealtimeWeb.TenantController do
  alias RealtimeWeb.OpenApiSchemas.UnauthorizedResponse
  alias RealtimeWeb.OpenApiSchemas.ErrorResponse
  use RealtimeWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias Realtime.Api
  alias Realtime.Api.Tenant
  alias Realtime.Database
  alias Realtime.Helpers
  alias Realtime.PostgresCdc
  alias Realtime.Tenants
  alias Realtime.Tenants.Cache

  alias RealtimeWeb.Endpoint
  alias RealtimeWeb.UserSocket

  alias RealtimeWeb.OpenApiSchemas.{
    EmptyResponse,
    NotFoundResponse,
    TenantResponse,
    TenantResponseList,
    TenantParams,
    TenantHealthResponse
  }

  @stop_timeout 10_000

  action_fallback(RealtimeWeb.FallbackController)

  operation(:index,
    summary: "List tenants",
    parameters: [
      authorization: [
        in: :header,
        name: "Authorization",
        schema: %OpenApiSpex.Schema{type: :string},
        required: true,
        example:
          "Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpYXQiOjE2ODAxNjIxNTR9.U9orU6YYqXAtpF8uAiw6MS553tm4XxRzxOhz2IwDhpY"
      ]
    ],
    responses: %{
      200 => TenantResponseList.response(),
      403 => EmptyResponse.response()
    }
  )

  def index(conn, _params) do
    tenants = Api.list_tenants()
    render(conn, "index.json", tenants: tenants)
  end

  operation(:create,
    summary: "Create tenant",
    parameters: [
      token: [
        in: :header,
        name: "Authorization",
        schema: %OpenApiSpex.Schema{type: :string},
        required: true,
        example:
          "Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpYXQiOjE2ODAxNjIxNTR9.U9orU6YYqXAtpF8uAiw6MS553tm4XxRzxOhz2IwDhpY"
      ]
    ],
    request_body: TenantParams.params(),
    responses: %{
      200 => TenantResponse.response(),
      403 => EmptyResponse.response()
    }
  )

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
      Logger.metadata(external_id: tenant.external_id, project: tenant.external_id)

      conn
      |> put_status(:created)
      |> put_resp_header("location", Routes.tenant_path(conn, :show, tenant))
      |> render("show.json", tenant: tenant)
    end
  end

  operation(:show,
    summary: "Fetch tenant",
    parameters: [
      token: [
        in: :header,
        name: "Authorization",
        schema: %OpenApiSpex.Schema{type: :string},
        required: true,
        example:
          "Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpYXQiOjE2ODAxNjIxNTR9.U9orU6YYqXAtpF8uAiw6MS553tm4XxRzxOhz2IwDhpY"
      ],
      tenant_id: [in: :path, description: "Tenant ID", type: :string]
    ],
    responses: %{
      200 => TenantResponse.response(),
      403 => EmptyResponse.response(),
      404 => NotFoundResponse.response()
    }
  )

  def show(conn, %{"tenant_id" => id}) do
    Logger.metadata(external_id: id, project: id)

    id
    |> Api.get_tenant_by_external_id()
    |> case do
      %Tenant{} = tenant ->
        render(conn, "show.json", tenant: tenant)

      nil ->
        conn
        |> put_status(404)
        |> render("not_found.json", tenant: nil)
    end
  end

  operation(:update,
    summary: "Create or update tenant",
    parameters: [
      token: [
        in: :header,
        name: "Authorization",
        schema: %OpenApiSpex.Schema{type: :string},
        required: true,
        example:
          "Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpYXQiOjE2ODAxNjIxNTR9.U9orU6YYqXAtpF8uAiw6MS553tm4XxRzxOhz2IwDhpY"
      ],
      tenant_id: [in: :path, description: "Tenant ID", type: :string]
    ],
    request_body: TenantParams.params(),
    responses: %{
      200 => TenantResponse.response(),
      403 => EmptyResponse.response()
    }
  )

  def update(conn, %{"tenant_id" => id, "tenant" => tenant_params}) do
    Logger.metadata(external_id: id, project: id)

    case Api.get_tenant_by_external_id(id) do
      nil ->
        create(conn, %{"tenant" => Map.put(tenant_params, "external_id", id)})

      tenant ->
        with {:ok, %Tenant{} = tenant} <- Api.update_tenant(tenant, tenant_params) do
          render(conn, "show.json", tenant: tenant)
        end
    end
  end

  operation(:delete,
    summary: "Delete tenant",
    parameters: [
      token: [
        in: :header,
        name: "Authorization",
        schema: %OpenApiSpex.Schema{type: :string},
        required: true,
        example:
          "Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpYXQiOjE2ODAxNjIxNTR9.U9orU6YYqXAtpF8uAiw6MS553tm4XxRzxOhz2IwDhpY"
      ],
      tenant_id: [in: :path, description: "Tenant ID", type: :string]
    ],
    responses: %{
      204 => EmptyResponse.response(),
      403 => UnauthorizedResponse.response(),
      500 => ErrorResponse.response()
    }
  )

  def delete(conn, %{"tenant_id" => tenant_id}) do
    Logger.metadata(external_id: tenant_id, project: tenant_id)

    stop_all_timeout = Enum.count(PostgresCdc.available_drivers()) * 1_000

    subs_id = UserSocket.subscribers_id(tenant_id)

    with %Tenant{} = tenant <- Api.get_tenant_by_external_id(tenant_id, :primary),
         true <- Api.delete_tenant_by_external_id(tenant_id),
         :ok <- Cache.distributed_invalidate_tenant_cache(tenant_id),
         :ok <- PostgresCdc.stop_all(tenant, stop_all_timeout),
         :ok <- Endpoint.broadcast(subs_id, "disconnect", %{}),
         :ok <- Database.replication_slot_teardown(tenant) do
      send_resp(conn, 204, "")
    else
      nil ->
        Helpers.log_error("TenantNotFound", "Tenant not found")
        send_resp(conn, 204, "")

      err ->
        Helpers.log_error("UnableToDeleteTenant", err)
        conn |> put_status(500) |> json(err) |> halt()
    end
  end

  operation(:reload,
    summary: "Reload tenant",
    parameters: [
      token: [
        in: :header,
        name: "Authorization",
        schema: %OpenApiSpex.Schema{type: :string},
        required: true,
        example:
          "Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpYXQiOjE2ODAxNjIxNTR9.U9orU6YYqXAtpF8uAiw6MS553tm4XxRzxOhz2IwDhpY"
      ],
      tenant_id: [in: :path, description: "Tenant ID", type: :string]
    ],
    responses: %{
      204 => EmptyResponse.response(),
      403 => EmptyResponse.response(),
      404 => NotFoundResponse.response()
    }
  )

  def reload(conn, %{"tenant_id" => tenant_id}) do
    Logger.metadata(external_id: tenant_id, project: tenant_id)

    case Tenants.get_tenant_by_external_id(tenant_id) do
      nil ->
        Helpers.log_error("TenantNotFound", "Tenant not found")

        conn
        |> put_status(404)
        |> render("not_found.json", tenant: nil)

      tenant ->
        PostgresCdc.stop_all(tenant, @stop_timeout)
        send_resp(conn, 204, "")
    end
  end

  operation(:health,
    summary: "Tenant health",
    parameters: [
      token: [
        in: :header,
        name: "Authorization",
        schema: %OpenApiSpex.Schema{type: :string},
        required: true,
        example:
          "Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpYXQiOjE2ODAxNjIxNTR9.U9orU6YYqXAtpF8uAiw6MS553tm4XxRzxOhz2IwDhpY"
      ],
      tenant_id: [in: :path, description: "Tenant ID", type: :string]
    ],
    responses: %{
      200 => TenantHealthResponse.response(),
      403 => EmptyResponse.response(),
      404 => NotFoundResponse.response()
    }
  )

  def health(conn, %{"tenant_id" => tenant_id}) do
    Logger.metadata(external_id: tenant_id, project: tenant_id)

    case Tenants.health_check(tenant_id) do
      {:ok, response} ->
        json(conn, %{data: response})

      {:error, %{healthy: false} = response} ->
        json(conn, %{data: response})

      {:error, :tenant_not_found} ->
        Helpers.log_error("TenantNotFound", "Tenant not found")

        conn
        |> put_status(404)
        |> render("not_found.json", tenant: nil)
    end
  end
end
