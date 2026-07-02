defmodule Mix.Tasks.Realtime.ExportTenantDbDump do
  @shortdoc "Regenerate priv/repo/tenant_db_dump_<pg_major>.sql"

  @moduledoc """
  Dumps the tenant database's `realtime` schema `schema_migrations` to `priv/repo/tenant_db_dump_<pg_major>.sql`.

  Usage:

      mix realtime.export_tenant_db_dump --pg-major 17

  The target tenant DB is expected to already have all tenant migrations applied,
  so make sure it is in a good state before generating it:

      mise task run db-rm
      mise task run db-start
      mix setup

  The target DB is read from `DB_HOST` / `DB_PORT` / `DB_NAME` / `DB_USER` / `DB_PASSWORD` env vars.

  Requires `pg_dump` matching the target's major version on `$PATH`.
  """
  use Mix.Task

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

    pg_dump!(host, port, database, user, password, path)
    append_schema_migrations!(host, port, database, user, password, path)
    postprocess!(path)

    Mix.shell().info("[export_tenant_db_dump] wrote #{path}")
  end

  defp dump_path(pg_major), do: Application.app_dir(:realtime, "priv/repo/tenant_db_dump_#{pg_major}.sql")

  defp pg_dump!(host, port, database, user, password, path) do
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
      "realtime",
      "--file",
      path
    ]

    case System.cmd(pg_dump, args, env: [{"PGPASSWORD", password}], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> Mix.raise("pg_dump exited #{code}:\n#{output}")
    end
  end

  defp append_schema_migrations!(host, port, database, user, password, path) do
    {:ok, conn} =
      Postgrex.start_link(hostname: host, port: port, database: database, username: user, password: password)

    {:ok, %{rows: rows}} =
      Postgrex.query(conn, ~s(SELECT version FROM realtime."schema_migrations" ORDER BY version), [])

    GenServer.stop(conn)

    sql =
      Enum.map_join(rows, fn [version] ->
        "INSERT INTO realtime.\"schema_migrations\" (version) VALUES (#{version});\n"
      end)

    File.write!(path, sql, [:append])
  end

  defp postprocess!(path) do
    tmp_path = path <> ".tmp"

    path
    |> File.stream!()
    |> Stream.reject(&String.starts_with?(&1, ["\\restrict ", "\\unrestrict "]))
    |> Stream.map(fn
      "CREATE SCHEMA realtime;\n" -> "CREATE SCHEMA IF NOT EXISTS realtime;\n"
      line -> line
    end)
    |> Stream.into(File.stream!(tmp_path))
    |> Stream.run()

    File.rename!(tmp_path, path)
  end
end
