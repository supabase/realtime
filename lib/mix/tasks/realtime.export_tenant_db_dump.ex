defmodule Mix.Tasks.Realtime.ExportTenantDbDump do
  @shortdoc "Regenerate priv/repo/tenant_db_dump_<pg_major>.sql"

  @moduledoc """
  Dumps the tenant database's `realtime` schema to `priv/repo/tenant_db_dump_<pg_major>.sql`,
  the `supabase_realtime_admin` role definition, and the `realtime.schema_migrations` rows.

  Usage:

      mix realtime.export_tenant_db_dump --pg-major 17

  The target tenant DB is expected to already have all tenant migrations applied,
  so make sure it is in a good state before generating it:

      mise task run db-rm
      mise task run db-start
      mix setup

  The target DB is read from `DB_HOST` / `DB_PORT` / `DB_NAME` / `DB_USER` / `DB_PASSWORD` env vars.

  Requires `pg_dump` and `pg_dumpall` matching the target's major version on `$PATH`.
  """
  use Mix.Task

  @realtime_admin_role "supabase_realtime_admin"

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:postgrex)

    {opts, _, _} = OptionParser.parse(args, strict: [pg_major: :integer])
    pg_major = opts[:pg_major] || Mix.raise("--pg-major is required, e.g. --pg-major 17")

    host = System.get_env("DB_HOST", "127.0.0.1")
    port = Realtime.Env.get_integer("DB_PORT", 5433)
    database = System.get_env("DB_NAME", "postgres")
    user = System.get_env("DB_USER", "supabase_admin")
    password = System.get_env("DB_PASSWORD", "postgres")
    path = dump_path(pg_major)

    Mix.shell().info("[export_tenant_db_dump] target: #{host}:#{port}/#{database} (pg#{pg_major})")

    lines = [
      realtime_admin_role_sql!(host, port, database, user, password),
      pg_dump!(host, port, database, user, password) |> postprocess(),
      schema_migrations_sql!(host, port, database, user, password)
    ]

    File.write!(path, lines)

    Mix.shell().info("[export_tenant_db_dump] wrote #{path}")
  end

  defp dump_path(pg_major), do: Application.app_dir(:realtime, "priv/repo/tenant_db_dump_#{pg_major}.sql")

  defp pg_dump!(host, port, database, user, password) do
    pg_dump = System.find_executable("pg_dump") || Mix.raise("pg_dump not found on $PATH")

    args = [
      "--host",
      host,
      "--port",
      to_string(port),
      "--username",
      user,
      "--dbname",
      database,
      "--schema-only",
      "--schema",
      "realtime"
    ]

    case System.cmd(pg_dump, args, env: [{"PGPASSWORD", password}]) do
      {output, 0} -> output
      {_output, code} -> Mix.raise("pg_dump exited #{code} - see output above")
    end
  end

  defp realtime_admin_role_sql!(host, port, database, user, password) do
    pg_dumpall = System.find_executable("pg_dumpall") || Mix.raise("pg_dumpall not found on $PATH")

    args = [
      "--host",
      host,
      "--port",
      to_string(port),
      "--username",
      user,
      "--database",
      database,
      "--roles-only"
    ]

    output =
      case System.cmd(pg_dumpall, args, env: [{"PGPASSWORD", password}], stderr_to_stdout: true) do
        {output, 0} -> output
        {output, code} -> Mix.raise("pg_dumpall exited #{code}:\n#{output}")
      end

    lines =
      output
      |> String.split("\n")
      |> Enum.filter(&realtime_admin_role_line?/1)
      |> Enum.uniq()

    if lines == [] do
      Mix.raise(
        "[export_tenant_db_dump] found no #{@realtime_admin_role} role statements in pg_dumpall --roles-only output"
      )
    end

    """
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '#{@realtime_admin_role}') THEN
        #{Enum.join(lines, "\n    ")}
      END IF;
    END $$;

    """
  end

  # include only role bootstrap queries
  defp realtime_admin_role_line?(line) do
    String.starts_with?(line, "CREATE ROLE #{@realtime_admin_role}") or
      String.starts_with?(line, "ALTER ROLE #{@realtime_admin_role}") or
      Regex.match?(~r/^GRANT .*TO #{@realtime_admin_role}/, line)
  end

  defp schema_migrations_sql!(host, port, database, user, password) do
    {:ok, conn} =
      Postgrex.start_link(hostname: host, port: port, database: database, username: user, password: password)

    {:ok, %{rows: rows}} =
      Postgrex.query(conn, ~s(SELECT version FROM realtime."schema_migrations" ORDER BY version), [])

    GenServer.stop(conn)

    inserts =
      Enum.map_join(rows, fn [version] ->
        "INSERT INTO realtime.\"schema_migrations\" (version) VALUES (#{version});\n"
      end)

    "ALTER TABLE realtime.schema_migrations ALTER COLUMN inserted_at SET DEFAULT now();\n" <> inserts
  end

  defp postprocess(content) do
    content
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(&1, ["\\restrict ", "\\unrestrict "]))
    |> Enum.map(fn
      "CREATE SCHEMA realtime;" -> "CREATE SCHEMA IF NOT EXISTS realtime;"
      line -> line
    end)
    |> Enum.intersperse("\n")
  end
end
