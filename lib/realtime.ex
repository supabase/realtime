defmodule Realtime do
  def region_nodes(region) do
    :syn.members(RegionNodes, region)
  end
end
