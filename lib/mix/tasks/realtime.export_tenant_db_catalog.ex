defmodule Mix.Tasks.Realtime.ExportTenantDbCatalog do
  @shortdoc "Regenerate priv/repo/tenant_db_catalog_<pg_major>.json"

  @moduledoc """
  Writes the catalog snapshot at `priv/repo/tenant_db_catalog_<pg_major>.json`
  used by `RealtimeWeb.Dashboard.TenantMigrations` to detect drifted DB state.

  The snapshot is named after the target server's major version (e.g.
  `tenant_db_catalog_14.json`, `tenant_db_catalog_15.json`,
  `tenant_db_catalog_17.json`). Some catalog objects only exist on newer
  Postgres (e.g. the `MAINTAIN` privilege), so a single snapshot cannot
  reconcile every supported version. Run this task once per Postgres major.

  Usage:

      mix realtime.export_tenant_db_catalog
      mix realtime.export_tenant_db_catalog --pgdelta-path /path/to/pgdelta

  The target tenant DB is expected to already have all tenant migrations applied,
  so make sure it is in a good state before generating it:

      mise task run db-rm
      mise task run db-start
      mix setup

  The target DB is read from `DB_HOST` / `DB_PORT` / `DB_NAME` / `DB_USER` / `DB_PASSWORD` env vars.

  Requires `pgdelta` on `$PATH` or pass `--pgdelta-path` to force a custom path.
  """
  use Mix.Task

  @catalog_filter ~s({"*/schema": "realtime"})

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [pgdelta_path: :string])
    {:ok, _} = Application.ensure_all_started(:postgrex)

    env = db_env()
    url = build_url(env)
    Mix.shell().info("[export_tenant_db_catalog] target: #{redact(url)}")

    pgdelta = pgdelta_bin!(opts[:pgdelta_path])
    Mix.shell().info("[export_tenant_db_catalog] pgdelta: #{pgdelta}")

    major = server_version_major!(env)
    catalog_path = "priv/repo/tenant_db_catalog_#{major}.json"
    output = Path.expand(catalog_path, File.cwd!())
    Mix.shell().info("[export_tenant_db_catalog] output: #{catalog_path} (PG#{major})")

    args = ["catalog-export", "--target", url, "--output", output, "--filter", @catalog_filter]

    case System.cmd(pgdelta, args, stderr_to_stdout: true) do
      {output_str, 0} ->
        validate_snapshot!(output)
        Mix.shell().info(output_str)

      {output_str, code} ->
        Mix.raise("pgdelta catalog-export exited #{code}:\n#{output_str}")
    end
  end

  defp pgdelta_bin!(nil), do: System.find_executable("pgdelta") || Mix.raise("pgdelta not found on $PATH")

  defp pgdelta_bin!(path) do
    path = Path.expand(path)
    System.find_executable(path) || Mix.raise("pgdelta not found or not executable at #{path}")
  end

  defp db_env do
    %{
      host: System.get_env("DB_HOST", "127.0.0.1"),
      port: System.get_env("DB_PORT", "5433"),
      name: System.get_env("DB_NAME", "postgres"),
      user: System.get_env("DB_USER", "supabase_admin"),
      password: System.get_env("DB_PASSWORD", "postgres")
    }
  end

  defp build_url(env) do
    "postgresql://#{URI.encode_www_form(env.user)}:#{URI.encode_www_form(env.password)}@#{env.host}:#{env.port}/#{env.name}"
  end

  defp server_version_major!(env) do
    {:ok, conn} =
      Postgrex.start_link(
        hostname: env.host,
        port: String.to_integer(env.port),
        database: env.name,
        username: env.user,
        password: env.password
      )

    %{rows: [[num]]} = Postgrex.query!(conn, "SHOW server_version_num", [])
    GenServer.stop(conn)
    div(String.to_integer(num), 10000)
  end

  defp validate_snapshot!(path) do
    with {:ok, content} <- File.read(path),
         {:ok, _} <- Jason.decode(content) do
      :ok
    else
      _ -> Mix.raise("catalog snapshot at #{path} is invalid")
    end
  end

  defp redact(url) do
    case URI.parse(url) do
      %URI{userinfo: nil} = u ->
        URI.to_string(u)

      %URI{userinfo: userinfo} = u ->
        user = userinfo |> String.split(":", parts: 2) |> hd()
        URI.to_string(%{u | userinfo: "#{user}:***"})
    end
  end
end
