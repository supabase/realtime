defmodule Realtime.Repo do
  use Ecto.Repo,
    otp_app: :realtime,
    adapter: Ecto.Adapters.Postgres

  @replicas %{
    "sea" => Realtime.Repo.Replica.SJC,
    "sjc" => Realtime.Repo.Replica.SJC,
    "gru" => Realtime.Repo.Replica.IAD,
    "iad" => Realtime.Repo.Replica.IAD,
    "sin" => Realtime.Repo.Replica.SIN,
    "maa" => Realtime.Repo.Replica.SIN,
    "syd" => Realtime.Repo.Replica.SIN,
    "lhr" => Realtime.Repo.Replica.FRA,
    "fra" => Realtime.Repo.Replica.FRA
  }

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

  for replica_repo <- @replicas |> Map.values() |> Enum.uniq() do
    defmodule replica_repo do
      use Ecto.Repo,
        otp_app: :realtime,
        adapter: Ecto.Adapters.Postgres,
        read_only: true
    end
  end
end
