defmodule Realtime.PostgresCdc do
  @moduledoc false

  require Logger

  @timeout 10_000
  @extensions Application.compile_env(:realtime, :extensions)

  def connect(module, opts) do
    apply(module, :handle_connect, [opts])
  end

  def after_connect(module, connect_response, extension, params) do
    apply(module, :handle_after_connect, [connect_response, extension, params])
  end

  def subscribe(module, pg_change_params, tenant, metadata) do
    RealtimeWeb.Endpoint.subscribe("postgres_cdc:" <> tenant)
    apply(module, :handle_subscribe, [pg_change_params, tenant, metadata])
  end

  def stop(module, tenant, timeout \\ @timeout) do
    apply(module, :handle_stop, [tenant, timeout])
  end

  def stop_all(tenant, timeout \\ @timeout) do
    available_drivers()
    |> Enum.each(fn module ->
      stop(module, tenant, timeout)
    end)
  end

  @spec available_drivers :: list
  def available_drivers() do
    @extensions
    |> Enum.filter(fn {_, e} -> e.type == :postgres_cdc end)
    |> Enum.map(fn {_, e} -> e.driver end)
  end

  def filter_settings(key, extensions) do
    [cdc] =
      Enum.filter(extensions, fn e ->
        if e.type == key do
          true
        else
          false
        end
      end)

    cdc.settings
  end

  @doc """
  Gets the extension module for a tenant.
  """

  @spec driver(String.t()) :: {:ok, module()} | {:error, String.t()}
  def driver(tenant_key) do
    @extensions
    |> Enum.filter(fn {_, %{key: key}} -> tenant_key == key end)
    |> case do
      [{_, %{driver: driver}}] -> {:ok, driver}
      _ -> {:error, "No driver found for key #{tenant_key}"}
    end
  end

  @doc """
  Translates a region from a platform to the closest Supabase tenant region
  """
  @spec platform_region_translator(String.t()) :: nil | binary()
  def platform_region_translator(tenant_region) when is_binary(tenant_region) do
    platform = Application.get_env(:realtime, :platform)
    region_mapping(platform, tenant_region)
  end

  defp region_mapping(:aws, tenant_region) do
    case tenant_region do
      "us-west-1" -> "us-west-1"
      "us-west-2" -> "us-west-1"
      "us-east-1" -> "us-east-1"
      "sa-east-1" -> "us-east-1"
      "ca-central-1" -> "us-east-1"
      "ap-southeast-1" -> "ap-southeast-1"
      "ap-northeast-1" -> "ap-southeast-1"
      "ap-northeast-2" -> "ap-southeast-1"
      "ap-southeast-2" -> "ap-southeast-2"
      "ap-south-1" -> "ap-southeast-1"
      "eu-west-1" -> "eu-west-2"
      "eu-west-2" -> "eu-west-2"
      "eu-west-3" -> "eu-west-2"
      "eu-central-1" -> "eu-west-2"
      _ -> nil
    end
  end

  defp region_mapping(:fly, tenant_region) do
    case tenant_region do
      "us-east-1" -> "iad"
      "us-west-1" -> "sea"
      "sa-east-1" -> "iad"
      "ca-central-1" -> "iad"
      "ap-southeast-1" -> "syd"
      "ap-northeast-1" -> "syd"
      "ap-northeast-2" -> "syd"
      "ap-southeast-2" -> "syd"
      "ap-south-1" -> "syd"
      "eu-west-1" -> "lhr"
      "eu-west-2" -> "lhr"
      "eu-west-3" -> "lhr"
      "eu-central-1" -> "lhr"
      _ -> nil
    end
  end

  defp region_mapping(_, tenant_region), do: tenant_region

  @doc """
  Lists the nodes in a region. Sorts by node name in case the list order
  is unstable.
  """

  @spec region_nodes(String.t()) :: [atom()]
  def region_nodes(region) when is_binary(region) do
    :syn.members(RegionNodes, region)
    |> Enum.map(fn {_pid, [node: node]} -> node end)
    |> Enum.sort()
  end

  @doc """
  Picks the node to launch the Postgres connection on.

  If there are not two nodes in a region the connection is established from
  the `default` node given.
  """

  @spec launch_node(String.t(), String.t(), atom()) :: atom()
  def launch_node(tenant, fly_region, default) do
    case region_nodes(fly_region) do
      [node] ->
        Logger.warning(
          "Only one region node (#{inspect(node)}) for #{fly_region} using default #{inspect(default)}"
        )

        default

      [] ->
        Logger.warning("Zero region nodes for #{fly_region} using #{inspect(default)}")
        default

      regions_nodes ->
        member_count = Enum.count(regions_nodes)
        index = :erlang.phash2(tenant, member_count)

        Enum.at(regions_nodes, index)
    end
  end

  @callback handle_connect(any()) :: {:ok, any()} | nil
  @callback handle_after_connect(any(), any(), any()) :: {:ok, any()} | {:error, any()}
  @callback handle_subscribe(any(), any(), any()) :: :ok
  @callback handle_stop(any(), any()) :: any()
end
