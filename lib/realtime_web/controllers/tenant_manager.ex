defmodule RealtimeWeb.TenantManagerController do
  use RealtimeWeb, :controller
  alias Extensions.Postgres

  def reload(conn, %{"tenant" => tenant}) do
    if Realtime.Api.get_tenant_by_external_id(tenant) do
      subscribers =
        Postgres.manager_pid(tenant)
        |> Postgres.SubscriptionManager.subscribers_list()

      Postgres.stop(tenant)
      tenant_obj = Realtime.Api.get_tenant_by_external_id(:cached, tenant)
      params = Postgres.Helpers.filter_postgres_settings(tenant_obj.extensions)
      Postgres.start_distributed(tenant, params)

      Enum.each(subscribers, fn pid -> send(pid, :postgres_subscribe) end)
      send_resp(conn, 200, "")
    else
      send_resp(conn, 404, "")
    end
  end
end
