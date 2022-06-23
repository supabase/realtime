defmodule Realtime.Repo.Migrations.GrantRealtimeUsageToAuthenticatedRole do
  use Ecto.Migration

  def change do
    execute "grant usage on schema realtime to authenticated;"
  end
end
