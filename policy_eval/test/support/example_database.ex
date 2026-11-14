defmodule PolicyEval.Test.ExampleDatabase do
  @moduledoc """
  The database of the example, as SQL for a plain Postgres: the schema `app`, the table
  `app.docs` and its grants, the roles, and the functions that the policies of the tests call.
  `PolicyEval.Test.ExampleProfile` is the profile of the same example.

  The roles are `guest` and `member`, which the library decides for, and `admin`, which bypasses
  row-level security. The database has the simple bodies of `app.user_id()` and `app.user_role()`.
  `fallback_functions_statement/0` replaces them with the fallback bodies.
  """

  @table "app.docs"

  # The bodies as Postgres stores them (prosrc). They have the layout of a migration, and the
  # profile has them on one line, so the tests also cover how the library compares sources. The
  # fixtures hold them too, so a difference shows up there.
  @team "\n  select nullif(current_setting('app.team', true), '')::text;\n"
  @user_id "\n  select nullif(current_setting('app.user_id', true), '')::uuid;\n"
  @user_role "\n  select nullif(current_setting('app.user_role', true), '')::text;\n"
  @email "\n  select nullif(current_setting('app.email', true), '')::text;\n"
  @claims "\n  select nullif(current_setting('app.claims', true), '')::jsonb;\n"

  @doc "The table that the policies are on."
  @spec table() :: String.t()
  def table, do: @table

  @doc """
  The statements that create the schema, in the database that `PolicyEval.Test.Postgres.prepare!/0`
  owns. They drop the schema `app` first, so they can run again. Roles belong to the whole server,
  so they are only created when they do not exist.
  """
  @spec setup_statements() :: [String.t()]
  def setup_statements do
    roles =
      for {role, attributes} <- [{"guest", ""}, {"member", ""}, {"admin", " BYPASSRLS"}] do
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
        "DROP SCHEMA IF EXISTS app CASCADE",
        "CREATE SCHEMA app",
        "GRANT USAGE ON SCHEMA app TO guest, member, admin",
        """
        CREATE TABLE app.docs (
          id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
          team text NOT NULL,
          kind text NOT NULL,
          title text,
          body jsonb,
          private boolean DEFAULT false
        )
        """,
        "ALTER TABLE app.docs ENABLE ROW LEVEL SECURITY",
        "GRANT SELECT, INSERT, UPDATE ON app.docs TO guest, member, admin",
        function("app", "team", "text", @team),
        function("app", "user_id", "uuid", @user_id),
        function("app", "user_role", "text", @user_role),
        function("app", "email", "text", @email),
        function("app", "claims", "jsonb", @claims),
        # The broken_* typical policies call it, see PolicyEval.Test.ExamplePolicies
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
  Replaces `app.user_id()` and `app.user_role()` with their fallback bodies. These bodies read
  `sub` or `role` from the claims when the `app.user_id` or `app.user_role` setting is empty.

  Whitespace aside, these are the fallback bodies that `PolicyEval.Test.ExampleProfile` knows. Run it
  in a transaction that rolls back.
  """
  @spec fallback_functions_statement() :: String.t()
  def fallback_functions_statement do
    """
    DO $do$
    BEGIN
      CREATE OR REPLACE FUNCTION app.user_id() RETURNS uuid LANGUAGE sql STABLE AS $body$
        select
          coalesce(
            nullif(current_setting('app.user_id', true), ''),
            (nullif(current_setting('app.claims', true), '')::jsonb ->> 'sub')
          )::uuid
      $body$;

      CREATE OR REPLACE FUNCTION app.user_role() RETURNS text LANGUAGE sql STABLE AS $body$
        select
          coalesce(
            nullif(current_setting('app.user_role', true), ''),
            (nullif(current_setting('app.claims', true), '')::jsonb ->> 'role')
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
