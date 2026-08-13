# Benchmarks the region-SET read on the GenRpcPubSub broadcast hot path — the one
# call `Realtime.GenRpcPubSub.RegionRings.all_node_regions/0` replaces:
#
#   * CURRENT: `:syn.group_names(scope)` — a full `:ets.select/2` scan of the
#     RegionNodes by-name table (one row per node) plus an `ordsets:from_list` usort
#     down to the distinct region names. O(nodes) per broadcast.
#   * CACHED : a single `:ets.lookup/2` of the pre-computed region list that
#     RegionRings maintains in its table (reserved `:__all_regions__` row, refreshed
#     on syn membership changes). O(1), independent of fleet size.
#
# This isolates ONLY the region-list read. It is NOT the full cross-region
# resolution — after this read the muster path (`cross_region_route`) does pure-ETS
# `RegionRings.expected_router/2` per region, so `group_names` is that path's
# dominant syn cost and this is where the cache pays off. For the full flood-path
# resolution (which also does `node_from_region/2` per region) see
# `bench/nodes_topology.exs`.
#
# Self-contained: boots only :syn (no DB / full app). Run with:
#   mix run --no-start bench/region_set_cache.exs
#
# Each scenario gets its own syn scope + cached row and is fed to Benchee as an
# input, so the two reads are measured across a matrix of cluster topologies.

{:ok, _} = Application.ensure_all_started(:syn)

scenarios =
  for regions_count <- [5, 7], nodes_per_region <- [4, 8, 12, 20, 30] do
    {regions_count, nodes_per_region}
  end

# Build one syn scope + cached ETS row per topology, then expose both as a Benchee
# input so each job reads from the matching scenario.
inputs =
  Map.new(scenarios, fn {regions_count, nodes_per_region} ->
    total_nodes = regions_count * nodes_per_region
    scope = :"RegionNodes_#{regions_count}x#{nodes_per_region}"
    :ok = :syn.add_node_to_scopes([scope])

    regions = for i <- 1..regions_count, do: "region-#{i}"

    # One long-lived process per (region, node), joined with `[node: node]` metadata,
    # matching how Realtime.Application registers nodes into RegionNodes.
    for region <- regions, n <- 1..nodes_per_region do
      node = :"node_#{region}_#{n}"

      {:ok, _pid} =
        Task.start_link(fn ->
          :syn.join(scope, region, self(), node: node)
          Process.sleep(:infinity)
        end)
    end

    # Give syn a moment to register everyone before snapshotting the cache row.
    Process.sleep(50)

    table = :ets.new(:"bench_region_set_#{scope}", [:set, :public, read_concurrency: true])
    region_set = :syn.group_names(scope)
    :ets.insert(table, {:__all_regions__, region_set})

    # Sanity: both strategies return the same region set for this scenario.
    true = Enum.sort(region_set) == Enum.sort(:syn.group_names(scope))

    label =
      "#{regions_count} regions x #{String.pad_leading(Integer.to_string(nodes_per_region), 2)} nodes " <>
        "= #{String.pad_leading(Integer.to_string(total_nodes), 3)} nodes"

    {label, %{scope: scope, table: table}}
  end)

IO.puts("Sanity check passed: both strategies resolve the same region set\n")

Benchee.run(
  %{
    "current (:syn.group_names full scan + usort)" => fn %{scope: scope} ->
      :syn.group_names(scope)
    end,
    "cached (single :ets.lookup)" => fn %{table: table} ->
      :ets.lookup(table, :__all_regions__) |> hd() |> elem(1)
    end
  },
  inputs: inputs,
  time: 3,
  memory_time: 1
)
