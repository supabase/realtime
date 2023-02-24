defmodule Realtime.Extensions.Rls.Repo.Migrations.GrantRealtimeUsageToAuthenticatedRole do
  @moduledoc false

  use Ecto.Migration

  def change do
    execute("grant usage on schema realtime to authenticated;")
  end
end
