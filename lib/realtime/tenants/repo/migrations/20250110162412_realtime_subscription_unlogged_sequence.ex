defmodule Realtime.Tenants.Migrations.RealtimeSubscriptionUnloggedSequence do
  @moduledoc false
  use Ecto.Migration

  def change do
    execute("""
    ALTER SEQUENCE IF EXISTS realtime.subscription_id_seq SET UNLOGGED
    """)
  end
end
