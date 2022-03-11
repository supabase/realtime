defmodule Realtime.Release do
  alias Realtime.RLS

  @app :realtime

  @spec migrate(String.t()) :: [Ecto.Repo.t()]
  def migrate(prefix \\ "realtime") do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true, prefix: prefix))
    end
  end

  @spec rollback(integer(), String.t()) :: {:ok, [integer()], [Application.app()]}
  def rollback(version, prefix \\ "realtime") do
    load_app()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(
        RLS.Repo,
        &Ecto.Migrator.run(&1, :down, to: version, prefix: prefix)
      )
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.load(@app)
  end
end
