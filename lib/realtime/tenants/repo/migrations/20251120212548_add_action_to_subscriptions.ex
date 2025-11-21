defmodule Realtime.Tenants.Migrations.AddActionToSubscriptions do
  @moduledoc false
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE realtime.subscription
    ADD COLUMN action_filter text DEFAULT '*' CHECK (action_filter IN ('*', 'INSERT', 'UPDATE', 'DELETE'));
    """)

    execute("""
    DROP INDEX IF EXISTS "realtime"."subscription_subscription_id_entity_filters_key";
    """)

    execute("""
    CREATE UNIQUE INDEX subscription_subscription_id_entity_filters_action_filter_key on realtime.subscription (subscription_id, entity, filters, action_filter);
    """)

    # FIXME create index
  end

  def down do
    execute("""
    ALTER TABLE realtime.subscription DROP COLUMN action_filter;
    """)
  end
end
