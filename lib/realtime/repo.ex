defmodule Realtime.Repo do
  use Ecto.Repo,
    otp_app: :realtime,
    adapter: Ecto.Adapters.Postgres

  @name nil
  @pool_size 2

  def with_dynamic_repo(credentials, callback) do
    default_dynamic_repo = get_dynamic_repo()
    start_opts = [name: @name, pool_size: @pool_size] ++ credentials
    {:ok, repo} = Realtime.Repo.start_link(start_opts)

    try do
      Realtime.Repo.put_dynamic_repo(repo)
      callback.(repo)
    after
      Realtime.Repo.put_dynamic_repo(default_dynamic_repo)
      Supervisor.stop(repo)
    end
  end
end
