defmodule Realtime.Repo do
  use Ecto.Repo,
    otp_app: :realtime,
    adapter: Ecto.Adapters.Postgres

  @name nil
  @pool_size 2

  @replicas %{
    "fra" => Realtime.Repo.Replica.FRA,
    "gru" => Realtime.Repo.Replica.IAD,
    "iad" => Realtime.Repo.Replica.IAD,
    "sin" => Realtime.Repo.Replica.SIN
  }

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

  if Mix.env() == :test do
    def replica, do: __MODULE__
  else
    def replica,
      do:
        Map.get(
          @replicas,
          Application.get_env(:realtime, :fly_region),
          Realtime.Repo
        )
  end

  for {_, repo} <- @replicas do
    defmodule repo do
      use Ecto.Repo,
        otp_app: :realtime,
        adapter: Ecto.Adapters.Postgres,
        read_only: true
    end
  end
end
