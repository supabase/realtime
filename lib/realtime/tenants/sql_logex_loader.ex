defmodule Realtime.Tenants.SqlLogexLoader do
  @moduledoc """
  Reads a tenant's `realtime.messages` row-level security state out of Postgres and builds the
  `SqlLogex.Snapshot` sql_logex decides policies against.

  The queries and row-shaping here are the ones proven against real Postgres by
  `test/realtime/tenants/sql_logex_differential_test.exs`: this module is that test's loader, moved
  out of test code so production code (eventually the shadow-mode hook in
  `Realtime.Tenants.Authorization`) and the differential test both run the same logic instead of two
  copies drifting apart.
  """

  alias Realtime.Database
  alias SqlLogex.Snapshot

  @functions_query """
  select n.nspname, p.proname, l.lanname, p.provolatile::text, p.prosecdef, p.proconfig,
         p.prorettype::regtype::text, p.prosrc
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  join pg_language l on l.oid = p.prolang
  where p.pronargs = 0 and (n.nspname, p.proname) in (('auth', 'uid'), ('auth', 'jwt'), ('auth', 'role'), ('realtime', 'topic'))
  order by n.nspname, p.proname
  """

  @policies_query """
  select polname, polcmd::text, polpermissive,
         array(select case when r = 0 then 'public' else r::regrole::text end from unnest(polroles) r),
         pg_get_expr(polqual, polrelid), pg_get_expr(polwithcheck, polrelid)
  from pg_policy where polrelid = 'realtime.messages'::regclass order by polname
  """

  @table_query "select relrowsecurity, relforcerowsecurity from pg_class where oid = 'realtime.messages'::regclass"

  @roles_query """
  select r.rolname, r.rolbypassrls,
         has_table_privilege(r.rolname, 'realtime.messages', 'SELECT'),
         has_table_privilege(r.rolname, 'realtime.messages', 'INSERT')
  from pg_roles r where r.rolname in ('anon', 'authenticated')
  """

  @doc """
  Loads a tenant's snapshot: opens a transaction on `db_conn`, reads everything `SqlLogex.Snapshot.new/1`
  needs, and parses and resolves every policy expression once, outside the transaction.

  `db_conn` is whatever connection the caller already has for the tenant (the same one
  `Realtime.Tenants.Authorization` uses for the real check) — this module has no opinion on how it
  was obtained.
  """
  @spec load(DBConnection.conn(), String.t()) :: {:ok, Snapshot.t()} | {:error, term()}
  def load(db_conn, tenant_id) do
    telemetry = [:realtime, :tenants, :sql_logex_snapshot_load]

    case Database.transaction(db_conn, &read/1, telemetry: telemetry, tenant_id: tenant_id) do
      {:ok, input} -> {:ok, Snapshot.new(input)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Reads a tenant's RLS state from an already-open connection, inside a transaction, as the map
  `SqlLogex.Snapshot.new/1` expects.

  The deparsed policy text (`pg_get_expr`) and function source are qualified by the session's
  search_path, so it is pinned to `''` for the duration and restored after, the way
  `SqlLogex.Snapshot`'s moduledoc requires. Only has effect inside a transaction block, which is why
  this (and `read_functions/1`) must run inside one.
  """
  @spec read(DBConnection.t()) :: map()
  def read(conn) do
    with_empty_search_path(conn, fn ->
      %{rows: [[rls_enabled, rls_forced]]} = Postgrex.query!(conn, @table_query, [])
      %{rows: roles} = Postgrex.query!(conn, @roles_query, [])
      %{rows: policies} = Postgrex.query!(conn, @policies_query, [])

      %{
        rls_enabled: rls_enabled,
        rls_forced: rls_forced,
        roles:
          Map.new(roles, fn [name, bypass_rls, select, insert] ->
            {name, %{bypass_rls: bypass_rls, select: select, insert: insert}}
          end),
        policies:
          for [name, cmd, permissive, roles, qual, with_check] <- policies do
            %{name: name, cmd: cmd, permissive: permissive, roles: roles, qual: qual, with_check: with_check}
          end,
        functions: read_functions(conn)
      }
    end)
  end

  @doc """
  Reads the tenant's definitions of `auth.uid/jwt/role` and `realtime.topic`, the ones
  `SqlLogex.Catalog` knows how to recognise, from an already-open connection, inside a transaction.
  """
  @spec read_functions(DBConnection.t()) :: [map()]
  def read_functions(conn) do
    with_empty_search_path(conn, fn ->
      %{rows: functions} = Postgrex.query!(conn, @functions_query, [])

      for [schema, name, language, volatility, security_definer, config, return_type, source] <- functions do
        %{
          schema: schema,
          name: name,
          language: language,
          volatility: volatility,
          security_definer: security_definer,
          config: config,
          return_type: return_type,
          source: source
        }
      end
    end)
  end

  defp with_empty_search_path(conn, fun) do
    %{rows: [[search_path]]} = Postgrex.query!(conn, "SELECT current_setting('search_path')", [])
    Postgrex.query!(conn, "SET LOCAL search_path = ''", [])
    value = fun.()
    Postgrex.query!(conn, "SELECT set_config('search_path', $1, true)", [search_path])
    value
  end
end
