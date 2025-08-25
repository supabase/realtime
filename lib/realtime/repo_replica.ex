defmodule Realtime.Repo.Replica do
  @moduledoc """
  Generates a read-only replica repo for the region specified in config/runtime.exs.
  """
  require Logger

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
    targets = Application.get_env(:realtime, Realtime.ReplicaRepo, []) |> Keyword.get(:targets, %{})
    replica_module = Map.get(targets, region)
    replica_configuration = Application.get_env(:realtime, replica_module)

    with replica_configuration when not is_nil(replica_configuration) <- replica_configuration,
         loaded? when loaded? == false <- Code.loaded?(replica_module) do
      Module.create(replica_module, @ast, Macro.Env.location(__ENV__))
      replica_module
    else
      true -> replica_module
      _ -> Realtime.Repo
    end
  end

  @doc """
  Returns a list of regions and their replica repositories. Made to work with System.get_env()
  """
  @spec replica_regions(map()) :: map()
  def replica_regions(env) do
    env
    |> Enum.filter(fn {k, _} -> String.starts_with?(k, "DB_HOST_REPLICA_TARGET_REGIONS_") end)
    |> Enum.flat_map(fn {k, v} ->
      region = String.replace_leading(k, "DB_HOST_REPLICA_TARGET_REGIONS_", "")
      module = to_module(region)
      v |> String.split(",") |> Enum.map(fn target -> {target, module} end)
    end)
    |> Map.new()
  end

  @doc """
  Returns a list of hosts and their replica repositories. Made to work with System.get_env()
  """
  @spec replica_hosts(map()) :: list()
  def replica_hosts(env) do
    env
    |> Enum.filter(fn {k, _} -> String.starts_with?(k, "DB_HOST_REPLICA_HOST_") end)
    |> Enum.map(fn {k, host} ->
      module = k |> String.replace_leading("DB_HOST_REPLICA_HOST_", "") |> to_module()
      {module, host}
    end)
  end

  defp to_module(value) do
    value
    |> String.replace("-", "_")
    |> Macro.camelize()
    |> then(fn module -> Module.concat(Realtime.Repo.Replica, module) end)
  end
end
