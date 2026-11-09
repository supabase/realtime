defmodule SqlLogex.Test.RealtimeDatabase do
  @moduledoc """
  The part of a Supabase Realtime tenant database that the policies of the tests use, as SQL for
  a plain Postgres. This is the database of the worked example, as `SqlLogex.Test.RealtimeProfile`
  is its profile.

  It is a copy. The roles are as in the supabase/postgres image, and the table and its grants are
  as in Realtime's tenant migrations. The function bodies are the ones of the image and of
  supabase/auth. One difference has no effect on the policies: the table has only a default
  partition.

  Realtime's `test/realtime/tenants/sql_logex_fixtures_test.exs` makes sure that a real tenant
  database prints the same policies and functions as this copy (`test/fixtures`).
  """

  @table "realtime.messages"

  # The bodies of the supabase/postgres image, as Postgres stores them (prosrc). The fixtures hold
  # them too, so a difference shows up there.
  @topic "\nselect nullif(current_setting('realtime.topic', true), '')::text;\n"
  @uid "\n  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;\n"
  @role "\n  select nullif(current_setting('request.jwt.claim.role', true), '')::text;\n"
  @email "\n  select nullif(current_setting('request.jwt.claim.email', true), '')::text;\n"
  @jwt """

    select coalesce(
        nullif(current_setting('request.jwt.claim', true), ''),
        nullif(current_setting('request.jwt.claims', true), '')
    )::jsonb
  """

  @doc "The table that the policies are on."
  @spec table() :: String.t()
  def table, do: @table

  @doc """
  The statements that create the schema, in the database that `SqlLogex.Test.Postgres.prepare!/0`
  owns. They drop the schemas `realtime` and `auth` first, so they can run again. Roles belong to
  the whole server, so they are only created when they do not exist.
  """
  @spec setup_statements() :: [String.t()]
  def setup_statements do
    roles =
      for {role, attributes} <- [{"anon", ""}, {"authenticated", ""}, {"service_role", " BYPASSRLS"}] do
        """
        DO $do$
        BEGIN
          CREATE ROLE #{role} NOLOGIN NOINHERIT#{attributes};
        EXCEPTION WHEN duplicate_object THEN
          NULL;
        END
        $do$
        """
      end

    roles ++
      [
        "DROP SCHEMA IF EXISTS realtime CASCADE",
        "DROP SCHEMA IF EXISTS auth CASCADE",
        "CREATE SCHEMA realtime",
        "CREATE SCHEMA auth",
        "GRANT USAGE ON SCHEMA realtime, auth TO anon, authenticated, service_role",
        """
        CREATE TABLE realtime.messages (
          topic text NOT NULL,
          extension text NOT NULL,
          payload jsonb,
          event text,
          private boolean DEFAULT false,
          updated_at timestamp without time zone DEFAULT timezone('utc'::text, clock_timestamp()) NOT NULL,
          inserted_at timestamp without time zone DEFAULT timezone('utc'::text, clock_timestamp()) NOT NULL,
          id uuid DEFAULT gen_random_uuid() NOT NULL,
          binary_payload bytea,
          skip_broadcast boolean DEFAULT false NOT NULL,
          expires_at timestamp without time zone,
          PRIMARY KEY (id, inserted_at)
        ) PARTITION BY RANGE (inserted_at)
        """,
        "CREATE TABLE realtime.messages_default PARTITION OF realtime.messages DEFAULT",
        "ALTER TABLE realtime.messages ENABLE ROW LEVEL SECURITY",
        "GRANT SELECT, INSERT, UPDATE ON realtime.messages TO anon, authenticated, service_role",
        function("realtime", "topic", "text", @topic),
        function("auth", "uid", "uuid", @uid),
        function("auth", "role", "text", @role),
        function("auth", "email", "text", @email),
        function("auth", "jwt", "jsonb", @jwt),
        # The broken_* generator policies call it, see SqlLogex.Test.RealtimePolicies
        """
        CREATE OR REPLACE FUNCTION public.test_log_error() RETURNS boolean AS $$
        BEGIN
        RAISE EXCEPTION 'test error';
        RETURN TRUE;
        END$$ LANGUAGE plpgsql
        """
      ]
  end

  @doc """
  Replaces `auth.uid()` and `auth.role()` with the bodies that supabase/auth has installed since its
  migration 20220224000811, which production projects run (github.com/supabase/auth). They read the
  claims when the `request.jwt.claim.sub` or `.role` setting is empty. The bodies of the
  supabase/postgres image only read the setting.

  Whitespace aside, these are the bodies that `SqlLogex.Test.RealtimeProfile` knows. Run it in a
  transaction that rolls back.
  """
  @spec supabase_auth_functions_statement() :: String.t()
  def supabase_auth_functions_statement do
    """
    DO $do$
    BEGIN
      CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $body$
        select
        coalesce(
          nullif(current_setting('request.jwt.claim.sub', true), ''),
          (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
        )::uuid
      $body$;

      CREATE OR REPLACE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $body$
        select
        coalesce(
          nullif(current_setting('request.jwt.claim.role', true), ''),
          (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
        )::text
      $body$;
    END
    $do$
    """
  end

  # Built by concatenation, so the source is stored exactly as given
  defp function(schema, name, return_type, source),
    do: "CREATE FUNCTION #{schema}.#{name}() RETURNS #{return_type} LANGUAGE sql STABLE AS $body$#{source}$body$"
end
