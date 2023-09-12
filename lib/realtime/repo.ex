defmodule Realtime.Repo do
  use Ecto.Repo,
    otp_app: :realtime,
    adapter: Ecto.Adapters.Postgres

  def with_dynamic_repo(config, callback) do
    default_dynamic_repo = get_dynamic_repo()
    {:ok, repo} = [name: nil, pool_size: 1] |> Keyword.merge(config) |> Realtime.Repo.start_link()

    try do
      Realtime.Repo.put_dynamic_repo(repo)
      callback.(repo)
    after
      Realtime.Repo.put_dynamic_repo(default_dynamic_repo)
      Supervisor.stop(repo)
    end
  end
end
