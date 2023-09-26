defmodule RealtimeWeb.TenantView do
  use RealtimeWeb, :view
  alias RealtimeWeb.TenantView

  def render("index.json", %{tenants: tenants}) do
    %{data: render_many(tenants, TenantView, "tenant.json")}
  end

  def render("show.json", %{tenant: tenant}) do
    %{data: render_one(tenant, TenantView, "tenant.json")}
  end

  def render("not_found.json", %{tenant: nil}) do
    %{error: "not found"}
  end

  def render("tenant.json", %{tenant: tenant}) do
    %{
      id: tenant.id,
      name: tenant.name,
      max_concurrent_users: tenant.max_concurrent_users,
      external_id: tenant.external_id,
      extensions: tenant.extensions,
      inserted_at: tenant.inserted_at
    }
  end

  def render("health.json", %{
        healthy: healthy,
        db_connected: db_connected,
        concurrent_users: conncurrent_users
      }) do
    %{
      db_connected: db_connected,
      healthy: healthy,
      conncurrent_users: conncurrent_users
    }
  end
end
