defmodule Multiplayer.Repo.Migrations.AddDefaultTenant do
  use Ecto.Migration
  alias Multiplayer.Api

  def up do
    Api.create_tenant(%{
      external_id: "dev_tenant",
      active: true,
      name: "auto-created localhost dev_tenant",
      db_host: "127.0.0.1",
      db_name: "postgres",
      db_password: "postgres",
      db_port: "5432",
      region: "eu-central-1",
      db_user: "postgres",
      jwt_secret: "d3v_HtNXEpT+zfsyy1LE1WPGmNKLWRfw/rpjnVtCEEM2cSFV2s+kUh5OKX7TPYmG",
      rls_poll_interval: 100
    })
  end

  def down do
    Api.delete_tenant(%{external_id: "dev_tenant"})
  end
end
