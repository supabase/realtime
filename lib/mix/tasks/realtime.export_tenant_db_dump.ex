defmodule Mix.Tasks.Realtime.ExportTenantDbDump do
  @shortdoc "Regenerate priv/repo/tenant_db_dump_<pg_major>.sql"

  @moduledoc """
  Dumps the tenant database's `realtime` schema to `priv/repo/tenant_db_dump_<pg_major>.sql`,
  the `supabase_realtime_admin` role definition, and the `realtime.schema_migrations` rows.

  `mise run tenant-dumps` provisions the databases and calls this task for every major we ship a
  dump for, so prefer it over calling this task by hand:

      mise run tenant-dumps        # every major
      mise run tenant-dumps 17     # just pg17

  Called directly, the target tenant DB is expected to already have all tenant migrations applied,
  so make sure it is in a good state before generating it:

      mise run db-rm
      mise run db-start
      mix realtime.export_tenant_db_dump --container tenant-realtime-dev-tenant_db-1

  The target DB is read from `DB_HOST` / `DB_PORT` / `DB_NAME` / `DB_USER` / `DB_PASSWORD` env vars.
  Its major version names the file that comes out, so there is no way to write a dump under a major
  it was not taken from.

  `pg_dump` and `pg_dumpall` run with `docker exec` inside `--container`, the target's own database
  container, so they always match the target's major version and the host needs no Postgres client
  installed. Only `docker` and a container we can reach the database through.
  """
  use Mix.Task

  @realtime_admin_role "supabase_realtime_admin"

  # What the database listens on inside its own container.
  @container_port 5432

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:postgrex)

    {opts, _, _} = OptionParser.parse(args, strict: [container: :string])

    target = %{
      host: System.get_env("DB_HOST", "127.0.0.1"),
      port: Realtime.Env.get_integer("DB_PORT", 5433),
      database: System.get_env("DB_NAME", "postgres"),
      user: System.get_env("DB_USER", "supabase_admin"),
      password: System.get_env("DB_PASSWORD", "postgres"),
      container: container!(opts)
    }

    conn = connect!(target)
    pg_major = pg_major!(conn)
    path = dump_path(pg_major)

    Mix.shell().info("[export_tenant_db_dump] target: #{target.host}:#{target.port}/#{target.database} (pg#{pg_major})")

    Mix.shell().info("[export_tenant_db_dump] container: #{target.container}")

    lines = [
      banner(pg_major),
      realtime_admin_role_sql!(target),
      target |> pg_dump!() |> postprocess(),
      schema_migrations_sql!(conn)
    ]

    GenServer.stop(conn)

    File.write!(path, lines)

    Mix.shell().info("[export_tenant_db_dump] wrote #{path}")
  end

  defp dump_path(pg_major), do: Application.app_dir(:realtime, "priv/repo/tenant_db_dump_#{pg_major}.sql")

  defp container!(opts) do
    opts[:container] ||
      Mix.raise("""
      --container is required: pg_dump runs inside the target database's own container, e.g.
      --container tenant-realtime-dev-tenant_db-1. `mise run tenant-dumps` passes it for you.
      """)
  end

  @doc false
  def banner(pg_major) do
    """
    --
    -- Auto-generated. Do not edit.
    --
    -- Tenant `realtime` schema for Postgres #{pg_major}
    --
    -- Beyond priv/repo/tenant_schema it also:
    --   - creates the supabase_realtime_admin role
    --   - creates realtime.schema_migrations and records every applied version
    --   - sets ALTER DEFAULT PRIVILEGES and the dashboard_user/postgres grants
    --
    -- See Mix.Tasks.Realtime.ExportTenantDbDump
    --
    """
  end

  defp pg_dump!(target) do
    docker_exec!(target, "pg_dump", ["--dbname", target.database, "--schema-only", "--schema", "realtime"])
  end

  defp realtime_admin_role_sql!(target) do
    lines =
      target
      |> docker_exec!("pg_dumpall", ["--database", target.database, "--roles-only"])
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

  # Runs one of the container's own dump binaries against the database next to it, capturing the
  # SQL from stdout while diagnostics go straight to our own stderr. The connection is the
  # container's loopback, not ours. PGPASSWORD is handed over by name so it stays off the command
  # line.
  defp docker_exec!(target, binary, args) do
    docker = System.find_executable("docker") || Mix.raise("docker not found on $PATH")

    argv =
      [
        "exec",
        "--env",
        "PGPASSWORD",
        target.container,
        binary,
        "--host",
        "127.0.0.1",
        "--port",
        to_string(@container_port),
        "--username",
        target.user
      ] ++ args

    case System.cmd(docker, argv, env: [{"PGPASSWORD", target.password}]) do
      {output, 0} -> output
      {_output, code} -> Mix.raise("#{binary} in #{target.container} exited #{code} - see output above")
    end
  end

  defp connect!(target) do
    {:ok, conn} =
      Postgrex.start_link(
        hostname: target.host,
        port: target.port,
        database: target.database,
        username: target.user,
        password: target.password
      )

    conn
  end

  defp pg_major!(conn) do
    {:ok, %{rows: [[version_num]]}} = Postgrex.query(conn, "SELECT current_setting('server_version_num')", [])
    version_num |> String.to_integer() |> div(10_000)
  end

  defp schema_migrations_sql!(conn) do
    {:ok, %{rows: rows}} =
      Postgrex.query(conn, ~s(SELECT version FROM realtime."schema_migrations" ORDER BY version), [])

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
