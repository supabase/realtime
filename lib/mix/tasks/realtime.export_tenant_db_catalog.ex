defmodule Mix.Tasks.Realtime.ExportTenantDbCatalog do
  @shortdoc "Regenerate priv/repo/tenant_db_catalog_17.json"

  @moduledoc """
  Writes the catalog snapshot at `priv/repo/tenant_db_catalog_17.json` used by
  `RealtimeWeb.Dashboard.TenantMigrations` to detect drifted DB state.

  pg-delta requires Postgres 15+, so the snapshot is generated against PG17 and
  the dashboard reconciles every tenant against it. The major version is kept in
  the filename so other versions can be added later if needed.

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

  @catalog_path "priv/repo/tenant_db_catalog_17.json"
  @catalog_filter ~s({"*/schema": "realtime"})

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [pgdelta_path: :string])

    url = build_url_from_env()
    Mix.shell().info("[export_tenant_db_catalog] target: #{redact(url)}")

    pgdelta = pgdelta_bin!(opts[:pgdelta_path])
    Mix.shell().info("[export_tenant_db_catalog] pgdelta: #{pgdelta}")

    output = Path.expand(@catalog_path, File.cwd!())
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

  defp build_url_from_env do
    host = System.get_env("DB_HOST", "127.0.0.1")
    port = System.get_env("DB_PORT", "5433")
    name = System.get_env("DB_NAME", "postgres")
    user = System.get_env("DB_USER", "supabase_admin")
    password = System.get_env("DB_PASSWORD", "postgres")

    "postgresql://#{URI.encode_www_form(user)}:#{URI.encode_www_form(password)}@#{host}:#{port}/#{name}"
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
