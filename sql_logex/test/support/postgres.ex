defmodule SqlLogex.Test.Postgres do
  @moduledoc """
  Helpers for the tests that run SQL against Postgres. Postgres is the oracle of these tests: it
  gives the correct answer that the library must match. Those tests have the tag `:postgres`.

  They run only when `SQL_LOGEX_DATABASE_URL` names a database, for example
  `postgres://postgres:postgres@localhost:5417/sql_logex_test` for service `postgres17` of
  compose.yml. The user must be a superuser,
  because the tests create roles and change them in transactions that roll back.

  `prepare!/0` creates the database when it does not exist, and marks it with a comment. It
  refuses a database without that mark, because it drops and creates schemas in it.
  """

  alias SqlLogex.Test.RealtimeDatabase

  @marker "sql_logex test database"

  @table_query "select relrowsecurity, relforcerowsecurity from pg_class where oid = $1::text::regclass"

  @roles_query """
  select r.rolname, r.rolbypassrls,
         has_table_privilege(r.rolname, $1::text::regclass, 'SELECT'),
         has_table_privilege(r.rolname, $1::text::regclass, 'INSERT')
  from pg_roles r where r.rolname = any($2)
  """

  @policies_query """
  select polname, polcmd::text, polpermissive,
         array(select case when r = 0 then 'public' else r::regrole::text end from unnest(polroles) r),
         pg_get_expr(polqual, polrelid), pg_get_expr(polwithcheck, polrelid)
  from pg_policy where polrelid = $1::text::regclass order by polname
  """

  @functions_query """
  select n.nspname, p.proname, l.lanname, p.provolatile::text, p.prosecdef, p.proconfig,
         p.prorettype::regtype::text, p.prosrc
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  join pg_language l on l.oid = p.prolang
  where p.pronargs = 0 and n.nspname || '.' || p.proname = any($1)
  order by n.nspname, p.proname
  """

  @doc "The value of `SQL_LOGEX_DATABASE_URL`, or nil when it is not set."
  @spec url() :: String.t() | nil
  def url do
    case System.get_env("SQL_LOGEX_DATABASE_URL") do
      empty when empty in [nil, ""] -> nil
      url -> url
    end
  end

  @doc """
  Creates the test database when it does not exist, then creates the Realtime schema in it (see
  `SqlLogex.Test.RealtimeDatabase`). Returns the major version of the server.
  """
  @spec prepare!() :: pos_integer()
  def prepare! do
    {:ok, _apps} = Application.ensure_all_started(:postgrex)
    options = options!()
    ensure_database!(options)

    {:ok, conn} = Postgrex.start_link([sync_connect: true] ++ options)

    try do
      {:ok, :ok} =
        Postgrex.transaction(conn, fn conn ->
          Enum.each(RealtimeDatabase.setup_statements(), &Postgrex.query!(conn, &1, []))
        end)

      div(server_version_num(conn), 10_000)
    after
      GenServer.stop(conn)
    end
  end

  @doc "The fixture of a Postgres major version, see `test/postgres/fixtures_test.exs`."
  @spec fixture_path(pos_integer()) :: Path.t()
  def fixture_path(major), do: Path.expand("../fixtures/pg#{major}/catalog.exs", __DIR__)

  @doc "The child spec of a connection to the test database, for `start_supervised!/1`."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts \\ []), do: Postgrex.child_spec([sync_connect: true] ++ options!())

  @doc "Runs `fun` with the connection in a transaction that rolls back, and returns what `fun` returns."
  @spec rolled_back(DBConnection.conn(), (DBConnection.t() -> value)) :: value when value: term()
  def rolled_back(conn, fun) do
    {:error, {__MODULE__, value}} =
      Postgrex.transaction(conn, fn conn -> Postgrex.rollback(conn, {__MODULE__, fun.(conn)}) end, timeout: 60_000)

    value
  end

  @doc "`server_version_num` of the server, for example `170006`."
  @spec server_version_num(DBConnection.conn()) :: pos_integer()
  def server_version_num(conn) do
    %{rows: [[version_num]]} = Postgrex.query!(conn, "SELECT current_setting('server_version_num')::int", [])
    version_num
  end

  @doc "A Postgres error as `{:error, sqlstate, code, message}`."
  @spec error(Postgrex.Error.t()) :: {:error, String.t(), atom(), String.t()}
  def error(%Postgrex.Error{postgres: %{pg_code: sqlstate, code: code, message: message}}),
    do: {:error, sqlstate, code, message}

  @doc """
  Reads what `SqlLogex.Snapshot.new/2` takes for `table`: the row-level security flags of the
  table, the grants and `BYPASSRLS` of the roles of the profile, the policies, and the functions
  of the profile as the database defines them.

  Run it in a transaction. It sets `search_path` to `''` with `SET LOCAL`, so that names print
  schema-qualified, and sets it back after.
  """
  @spec read(DBConnection.t(), String.t(), SqlLogex.Profile.t()) :: map()
  def read(conn, table, profile) do
    with_empty_search_path(conn, fn ->
      %{rows: [[rls_enabled, rls_forced]]} = Postgrex.query!(conn, @table_query, [table])
      %{rows: roles} = Postgrex.query!(conn, @roles_query, [table, profile.roles])

      %{
        rls_enabled: rls_enabled,
        rls_forced: rls_forced,
        roles:
          Map.new(roles, fn [name, bypass_rls, select, insert] ->
            {name, %{bypass_rls: bypass_rls, select: select, insert: insert}}
          end),
        policies: read_policies(conn, table),
        functions: read_functions(conn, profile)
      }
    end)
  end

  @doc "The policies on `table`, as `read/3` returns them. Run it in a transaction, see `read/3`."
  @spec read_policies(DBConnection.t(), String.t()) :: [map()]
  def read_policies(conn, table) do
    with_empty_search_path(conn, fn ->
      %{rows: policies} = Postgrex.query!(conn, @policies_query, [table])

      for [name, cmd, permissive, roles, qual, with_check] <- policies do
        %{name: name, cmd: cmd, permissive: permissive, roles: roles, qual: qual, with_check: with_check}
      end
    end)
  end

  @doc """
  The database definitions of the functions of the profile, as `read/3` returns them. Run it in a
  transaction, see `read/3`.
  """
  @spec read_functions(DBConnection.t(), SqlLogex.Profile.t()) :: [map()]
  def read_functions(conn, profile) do
    names = profile.functions |> Enum.map(&"#{&1.schema}.#{&1.name}") |> Enum.uniq()

    with_empty_search_path(conn, fn ->
      %{rows: functions} = Postgrex.query!(conn, @functions_query, [names])

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

  ## The database

  defp ensure_database!(options) do
    database = Keyword.fetch!(options, :database)

    unless database =~ ~r/\A[a-z_][a-z0-9_]*\z/ do
      raise ArgumentError, "SQL_LOGEX_DATABASE_URL: use a database name of a-z, 0-9 and _, got #{inspect(database)}"
    end

    {:ok, admin} = Postgrex.start_link([sync_connect: true] ++ Keyword.put(options, :database, "postgres"))

    try do
      query = "SELECT shobj_description(oid, 'pg_database') FROM pg_database WHERE datname = $1"

      case Postgrex.query!(admin, query, [database]).rows do
        [] ->
          # template0, so the database starts empty. It takes the locale of the server.
          Postgrex.query!(admin, ~s(CREATE DATABASE "#{database}" TEMPLATE template0 ENCODING 'UTF8'), [])
          Postgrex.query!(admin, ~s(COMMENT ON DATABASE "#{database}" IS '#{@marker}'), [])

        [[@marker]] ->
          :ok

        [[_other]] ->
          raise """
          SQL_LOGEX_DATABASE_URL names the database #{inspect(database)}, which the tests did not create.
          The tests drop and create schemas in their database. Use the name of a database that does not exist.
          """
      end
    after
      GenServer.stop(admin)
    end
  end

  defp options! do
    url = url() || raise "SQL_LOGEX_DATABASE_URL is not set. See \"Tests against Postgres\" in the README."
    uri = URI.parse(url)
    query = URI.decode_query(uri.query || "")
    {username, password} = userinfo(uri.userinfo)

    host =
      case {uri.host, query["host"]} do
        {_host, "/" <> _ = socket_dir} -> [socket_dir: socket_dir]
        {empty, _} when empty in [nil, ""] -> [hostname: "localhost"]
        {host, _} -> [hostname: host]
      end

    host ++
      [
        port: uri.port || 5432,
        username: username,
        password: password,
        database: (uri.path || "") |> String.trim_leading("/") |> URI.decode(),
        pool_size: 1,
        backoff_type: :stop,
        show_sensitive_data_on_connection_error: true
      ]
  end

  defp userinfo(nil), do: {"postgres", nil}

  defp userinfo(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [username] -> {URI.decode(username), nil}
      [username, password] -> {URI.decode(username), URI.decode(password)}
    end
  end
end
