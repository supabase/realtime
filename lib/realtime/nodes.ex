defmodule Realtime.Nodes do
  @moduledoc """
  Handles common needs for :syn module operations
  """
  require Logger
  alias Realtime.Api.Tenant
  alias Realtime.Tenants

  @doc """
  Gets the node to launch the Postgres connection on for a tenant.
  """
  @spec get_node_for_tenant(Tenant.t()) :: {:ok, node(), binary()} | {:error, term()}
  def get_node_for_tenant(nil), do: {:error, :tenant_not_found}

  def get_node_for_tenant(%Tenant{external_id: tenant_id} = tenant) do
    with region <- Tenants.region(tenant),
         tenant_region <- platform_region_translator(region),
         node <- launch_node(tenant_id, tenant_region, node()) do
      {:ok, node, tenant_region}
    end
  end

  @doc """
  Translates a region from a platform to the closest Supabase tenant region.

  Region mapping can be customized via the REGION_MAPPING environment variable.
  If not provided, uses the default hardcoded mapping.
  """
  @spec platform_region_translator(String.t() | nil) :: nil | binary()
  def platform_region_translator(nil), do: nil

  def platform_region_translator(tenant_region) when is_binary(tenant_region) do
    case Application.get_env(:realtime, :region_mapping) do
      nil -> default_region_mapping(tenant_region)
      mapping when is_map(mapping) -> Map.get(mapping, tenant_region)
    end
  end

  # Private function with hardcoded defaults
  defp default_region_mapping(tenant_region) do
    case tenant_region do
      "ap-east-1" -> "ap-southeast-1"
      "ap-northeast-1" -> "ap-southeast-1"
      "ap-northeast-2" -> "ap-southeast-1"
      "ap-south-1" -> "ap-southeast-1"
      "ap-southeast-1" -> "ap-southeast-1"
      "ap-southeast-2" -> "ap-southeast-2"
      "ca-central-1" -> "us-east-1"
      "eu-central-1" -> "eu-west-2"
      "eu-central-2" -> "eu-west-2"
      "eu-north-1" -> "eu-west-2"
      "eu-west-1" -> "eu-west-2"
      "eu-west-2" -> "eu-west-2"
      "eu-west-3" -> "eu-west-2"
      "sa-east-1" -> "us-east-1"
      "us-east-1" -> "us-east-1"
      "us-east-2" -> "us-east-1"
      "us-west-1" -> "us-west-1"
      "us-west-2" -> "us-west-1"
      _ -> nil
    end
  end

  @doc """
  Lists the nodes in a region. Sorts by node name in case the list order
  is unstable.
  """

  @spec region_nodes(String.t() | nil) :: [atom()]
  def region_nodes(region) when is_binary(region) do
    :syn.members(RegionNodes, region)
    |> Enum.map(fn {_pid, [node: node]} -> node end)
    |> Enum.sort()
  end

  def region_nodes(nil), do: []

  @doc """
  Picks a node from a region based on the provided key
  """
  @spec node_from_region(String.t(), term()) :: {:ok, node} | {:error, :not_available}
  def node_from_region(region, key) when is_binary(region) do
    nodes = region_nodes(region)

    case nodes do
      [] ->
        {:error, :not_available}

      _ ->
        member_count = Enum.count(nodes)
        index = :erlang.phash2(key, member_count)

        {:ok, Enum.fetch!(nodes, index)}
    end
  end

  def node_from_region(_, _), do: {:error, :not_available}

  @doc """
  Picks the node to launch the Postgres connection on.

  If there are not two nodes in a region the connection is established from
  the `default` node given.
  """
  @spec launch_node(String.t(), String.t() | nil, atom()) :: atom()
  def launch_node(tenant_id, region, default) do
    case region_nodes(region) do
      [] ->
        Logger.warning("Zero region nodes for #{region} using #{inspect(default)}")
        default

      regions_nodes ->
        member_count = Enum.count(regions_nodes)
        index = :erlang.phash2(tenant_id, member_count)

        Enum.fetch!(regions_nodes, index)
    end
  end

  @doc """
  Gets a short node name from a node name when a node name looks like `realtime-prod@fdaa:0:cc:a7b:b385:83c3:cfe3:2`

  ## Examples

      iex> node = Node.self()
      iex> Realtime.Helpers.short_node_id_from_name(node)
      "nohost"

      iex> node = :"realtime-prod@fdaa:0:cc:a7b:b385:83c3:cfe3:2"
      iex> Realtime.Helpers.short_node_id_from_name(node)
      "83c3cfe3"

      iex> node = :"pink@127.0.0.1"
      iex> Realtime.Helpers.short_node_id_from_name(node)
      "pink@127.0.0.1"

      iex> node = :"pink@10.0.1.1"
      iex> Realtime.Helpers.short_node_id_from_name(node)
      "10.0.1.1"

      iex> node = :"realtime@host.name.internal"
      iex> Realtime.Helpers.short_node_id_from_name(node)
      "host.name.internal"
  """

  @spec short_node_id_from_name(atom()) :: String.t()
  def short_node_id_from_name(name) when is_atom(name) do
    [_, host] = name |> Atom.to_string() |> String.split("@", parts: 2)

    case String.split(host, ":", parts: 8) do
      [_, _, _, _, _, one, two, _] ->
        one <> two

      ["127.0.0.1"] ->
        Atom.to_string(name)

      _other ->
        host
    end
  end

  @spec all_node_regions() :: [String.t()]
  @doc "List all the regions where nodes can be launched"
  def all_node_regions(), do: :syn.group_names(RegionNodes)
end
