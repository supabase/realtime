defmodule Realtime.Tenants.Migrations.RealtimeSubscriptionLogged do
  @moduledoc false
  use Ecto.Migration

  # Due to issues on PG Updates we can't use UNLOGGED tables due to the fact that Sequences on PG14 still need to be logged
  def change do
    execute("""
    ALTER TABLE realtime.subscription SET LOGGED;
    """)
  end
end
