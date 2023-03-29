defmodule RealtimeWeb.TenantController do
  use RealtimeWeb, :controller

  require Logger

  alias Realtime.Api
  alias Realtime.Repo
  alias Realtime.Api.Tenant
  alias Realtime.PostgresCdc
  alias RealtimeWeb.{UserSocket, Endpoint}

  @stop_timeout 10_000

  action_fallback(RealtimeWeb.FallbackController)

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
      Logger.metadata(external_id: tenant.external_id, project: tenant.external_id)

      conn
      |> put_status(:created)
      |> put_resp_header("location", Routes.tenant_path(conn, :show, tenant))
      |> render("show.json", tenant: tenant)
    end
  end

  def show(conn, %{"id" => id}) do
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

  def update(conn, %{"id" => id, "tenant" => tenant_params}) do
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

  def delete(conn, %{"id" => id}) do
    Logger.metadata(external_id: id, project: id)

    Repo.transaction(
      fn ->
        if Api.delete_tenant_by_external_id(id) do
          with :ok <- UserSocket.subscribers_id(id) |> Endpoint.broadcast("disconnect", %{}),
               :ok <- PostgresCdc.stop_all(id) do
            :ok
          else
            other -> Repo.rollback(other)
          end
        end
      end,
      timeout: @stop_timeout
    )
    |> case do
      {:error, reason} ->
        Logger.error("Can't remove tenant #{inspect(reason)}")
        send_resp(conn, 503, "")

      _ ->
        send_resp(conn, 204, "")
    end
  end

  def reload(conn, %{"tenant_id" => tenant_id}) do
    Logger.metadata(external_id: tenant_id, project: tenant_id)

    case Api.get_tenant_by_external_id(tenant_id) do
      %Tenant{} ->
        PostgresCdc.stop_all(tenant_id, @stop_timeout)
        send_resp(conn, 204, "")

      nil ->
        Logger.error("Atttempted to reload non-existant tenant #{tenant_id}")

        conn
        |> put_status(404)
        |> render("not_found.json", tenant: nil)
    end
  end
end
