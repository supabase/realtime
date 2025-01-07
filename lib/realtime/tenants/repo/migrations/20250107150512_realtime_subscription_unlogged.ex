defmodule Realtime.Tenants.Migrations.RealtimeSubscriptionUnlogged do
  @moduledoc false
  use Ecto.Migration

  # We missed the schema prefix of `realtime.` in the create table partition statement
  def change do
    execute("""
    ALTER TABLE realtime.subscription SET UNLOGGED;
    """)
  end
end
