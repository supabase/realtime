defmodule Realtime.Tenants.Migrations.HashSubscriptionFiltersIndex do
  @moduledoc false

  use Ecto.Migration

  def up do
    # Indexing `filters` by value caps a subscription's filter list at the btree
    # tuple limit (2704 bytes), which an `in` list reaches long before the 100
    # values the docs allow. Index a fixed-width digest of it instead: the
    # uniqueness the upsert relies on is unchanged, the size ceiling is gone.
    #
    # OrioleDB only accepts index expressions built from immutable C or SQL functions, checked
    # all the way down, so filters::text (array_out/record_out are stable) and convert_to are out,
    # and so is any aggregate in the body. hash_array_extended hashes the array field by field
    # with each type's own hash, which agrees with the array equality the old index enforced.
    # Two seeds give 128 bits.
    execute("""
    create or replace function realtime.filters_hash(filters realtime.user_defined_filter[])
        returns bytea
        language sql
        immutable
        strict
        parallel safe
    as $$
      select pg_catalog.int8send(pg_catalog.hash_array_extended(filters, 0))
          || pg_catalog.int8send(pg_catalog.hash_array_extended(filters, 1))
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
