defmodule RealtimeWeb.TenantMetricsController do
  use RealtimeWeb, :controller

  def index(conn, %{"id" => tenant}) do
    Logger.metadata(external_id: tenant, project: tenant)

    if Realtime.Api.get_tenant_by_external_id(tenant) do
      metrics = [
        {"tenant_concurrent_users", Realtime.UsersCounter.tenant_users(tenant)}
      ]

      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, params_to_rows(metrics))
    else
      send_resp(conn, 404, "")
    end
  end

  def params_to_rows(metrics) do
    Enum.reduce(metrics, "", fn {key, value}, acc ->
      "#{acc} #{key} #{value} \n"
    end)
  end
end
