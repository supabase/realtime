defmodule MultiplayerWeb.TenantView do
  use MultiplayerWeb, :view
  alias MultiplayerWeb.TenantView

  def render("index.json", %{tenants: tenants}) do
    %{data: render_many(tenants, TenantView, "tenant.json")}
  end

  def render("show.json", %{tenant: tenant}) do
    %{data: render_one(tenant, TenantView, "tenant.json")}
  end

  def render("tenant.json", %{tenant: tenant}) do
    %{
      id: tenant.id,
      name: tenant.name,
      external_id: tenant.external_id,
      jwt_secret: tenant.jwt_secret,
      db_host: tenant.db_host,
      db_port: tenant.db_port,
      db_name: tenant.db_name,
      db_user: tenant.db_user,
      db_password: tenant.db_password
    }
  end
end
