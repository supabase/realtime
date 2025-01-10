defmodule Realtime.Tenants.Migrations.RealtimeSubscriptionUnlogged do
  @moduledoc false
  use Ecto.Migration

  def change do
    execute("""
    ALTER TABLE realtime.subscription SET UNLOGGED;
    """)
  end
end
