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
      external_id: tenant.external_id,
      name: tenant.name,
      max_concurrent_users: tenant.max_concurrent_users,
      max_channels_per_client: tenant.max_channels_per_client,
      max_events_per_second: tenant.max_events_per_second,
      max_joins_per_second: tenant.max_joins_per_second,
      inserted_at: tenant.inserted_at,
      extensions: tenant.extensions
    }
  end
end
