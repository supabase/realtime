defmodule Realtime.Tenants do
  @moduledoc """
  Everything to do with Tenants.
  """

  @doc """
  Gets a list of connected tenant `external_id` strings in the cluster or a node.
  """

  @spec list_connected_tenants :: [String.t()]
  def list_connected_tenants() do
    :syn.group_names(:users)
  end

  @spec list_connected_tenants(atom()) :: [String.t()]
  def list_connected_tenants(node) do
    :syn.group_names(:users, node)
  end
end
