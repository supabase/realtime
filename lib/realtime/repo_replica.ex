defmodule Realtime.Repo.Replica do
  @moduledoc """
  Generates a read-only replica repo for the region specified in config/runtime.exs.
  """
  require Logger

  use Ecto.Repo,
    otp_app: :realtime,
    adapter: Ecto.Adapters.Postgres,
    read_only: true

  @replicas_fly %{
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

  @replicas_aws %{
    "ap-southeast-1" => Realtime.Repo.Replica.Singapore,
    "ap-southeast-2" => Realtime.Repo.Replica.Singapore,
    "eu-west-2" => Realtime.Repo.Replica.London,
    "us-east-1" => Realtime.Repo.Replica.NorthVirginia,
    "us-west-2" => Realtime.Repo.Replica.Oregon,
    "us-west-1" => Realtime.Repo.Replica.SanJose
  }

  @ast (quote do
          use Ecto.Repo,
            otp_app: :realtime,
            adapter: Ecto.Adapters.Postgres,
            read_only: true
        end)

  @doc """
  Returns the replica repo module for the region specified in config/runtime.exs.
  """
  @spec replica() :: module()
  def replica do
    region = Application.get_env(:realtime, :region)
    master_region = Application.get_env(:realtime, :master_region) || region
    replica = configured_replica_module(region)
    replica_conf = Application.get_env(:realtime, replica)

    # Do not create module if replica isn't set or configuration is not present
    cond do
      is_nil(replica) ->
        Realtime.Repo

      is_nil(replica_conf) ->
        Realtime.Repo

      region == master_region ->
        Realtime.Repo

      true ->
        # Check if module is present
        case Code.ensure_compiled(replica) do
          {:module, _} -> nil
          _ -> {:module, _, _, _} = Module.create(replica, @ast, Macro.Env.location(__ENV__))
        end

        replica
    end
  end

  defp configured_replica_module(region) do
    main_replica_config = Application.get_env(:realtime, __MODULE__)

    # If the main replica module is configured we don't bother with specific replica modules
    if main_replica_config do
      __MODULE__
    else
      replicas =
        case Application.get_env(:realtime, :platform) do
          :aws -> @replicas_aws
          :fly -> @replicas_fly
          _ -> %{}
        end

      Map.get(replicas, region)
    end
  end

  if Mix.env() == :test do
    def replicas_aws, do: @replicas_aws

    def replicas_fly, do: @replicas_fly
  end
end
