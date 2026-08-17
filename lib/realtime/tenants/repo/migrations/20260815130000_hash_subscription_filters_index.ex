defmodule Realtime.Tenants.Migrations.HashSubscriptionFiltersIndex do
  @moduledoc false

  use Ecto.Migration

  def up do
    # Indexing `filters` by value caps a subscription's filter list at the btree
    # tuple limit (2704 bytes), which an `in` list reaches long before the 100
    # values the docs allow. Index a fixed-width digest of it instead: the
    # uniqueness the upsert relies on is unchanged, the size ceiling is gone.
    execute("""
    create or replace function realtime.filters_hash(filters realtime.user_defined_filter[])
        returns bytea
        language sql
        immutable
        strict
        parallel safe
    as $$
      select pg_catalog.sha256(pg_catalog.convert_to(filters::text, 'UTF8'))
    $$;
    """)

    execute("ALTER FUNCTION realtime.filters_hash(realtime.user_defined_filter[]) OWNER TO supabase_realtime_admin")

    execute("""
    grant execute on function realtime.filters_hash(realtime.user_defined_filter[])
    to postgres, anon, authenticated, service_role;
    """)

    execute("""
    DROP INDEX IF EXISTS
      realtime.subscription_subscription_id_entity_filters_action_filter_selected_columns_key;
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS
      subscription_subscription_id_entity_filters_hash_key
    ON realtime.subscription
      (subscription_id, entity, realtime.filters_hash(filters), action_filter, coalesce(selected_columns, '{}'));
    """)
  end

  def down do
    execute("""
    DROP INDEX IF EXISTS realtime.subscription_subscription_id_entity_filters_hash_key;
    """)

    # Rows whose filters exceed the btree limit cannot be represented by the
    # value index this restores; drop them rather than fail the migration.
    # Clients recreate their subscriptions on reconnect.
    execute("""
    DELETE FROM realtime.subscription
    WHERE pg_catalog.octet_length(filters::text) > 2704;
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS
      subscription_subscription_id_entity_filters_action_filter_selected_columns_key
    ON realtime.subscription
      (subscription_id, entity, filters, action_filter, coalesce(selected_columns, '{}'));
    """)

    execute("DROP FUNCTION IF EXISTS realtime.filters_hash(realtime.user_defined_filter[])")
  end
end
