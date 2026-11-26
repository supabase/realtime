# Benchmark for the Phoenix and Rollcall presence backends. It measures the reductions, the CPU
# time and the memory of each backend on a local cluster of nodes, so you can see what a change
# to Rollcall does to its cost.
#
# Start the database, then run the script. It runs this file and renders the report:
#
#     mise run db-start
#     dev/scripts/presence-bench.sh --tenants 20 --entries 100 --changes-per-s 60
#
# The results go to _build/presence_bench/latest.json, or to the file of `--out`. The report goes
# next to the results, with the extension .html.
#
# What a run does
#
# Each backend runs alone on a fresh cluster, so neither adds its cost to the other. The run
# repeats this `--repeats` times and reports the middle result. It measures two windows:
#
#   join    Clients join and track their entries. The window ends when every node has all of them.
#   steady  Nothing joins. For 30 s, `--changes-per-s` changes happen each second. A change picks
#           an entry at random and either updates it, or removes it and adds it back. The number
#           of entries does not change.
#
# For each window it reports three numbers, added up over the nodes:
#
#   reductions per second   the work done. A reduction is the BEAM's count of work, about one
#                           function call. It does not count the time in a BIF, such as an ETS read,
#                           or the time in a garbage collection.
#   CPU seconds per second  the CPU time that the schedulers of the node used for each second of the
#                           window. It is the sum, over the schedulers, of the share of the window
#                           that the scheduler was busy. A node that uses 2 of its schedulers fully
#                           reports 2. The results file keeps the figure of each node.
#   memory                  the memory held, read after a garbage collection.
#
# The CPU seconds cover the whole node, so they include the clients and the rest of the app. A run
# with `--scoped-cpu` also reports the CPU seconds of the measured processes alone: the Phoenix
# shards or the Rollcall trackers. The VM traces when each of these processes starts and stops to
# run, and the run adds up the time that they ran. It includes their BIFs and their garbage
# collections, which reductions do not count. The tracing adds work to the node, so the CPU seconds
# of a run with the option are not comparable with the CPU seconds of a run without it. Compare
# the scoped figure only with the scoped figure of another run.
#
# Each node runs with its share of the cores of the machine and with scheduler spinning off, so the
# CPU seconds do not include time that the OS gave to another node or time that a scheduler spent
# waiting for work. A node gets the number of cores divided by `--nodes`, and at least 1. A run with
# another number of nodes, or on another machine, has another number of schedulers on each node.
# Compare only runs with the same number.
#
# The reductions and the memory cover only the Phoenix shards and the Rollcall trackers. The
# clients call the presence functions directly, with no WebSocket. The CPU seconds cover the whole
# node, so they include the clients and the rest of the app. That share is about the same for both
# backends.
#
# The tenants have skewed sizes: a tenth of them hold 80% of the entries. Every tenant is on all
# nodes, so a tenant has `--nodes` minus 1 peers. Rollcall otherwise replicates a tenant only to the
# nodes that hold it, so the benchmark has no setting to change that.
#
# Comparing with an earlier run
#
#     dev/scripts/presence-bench.sh --out _build/presence_bench/baseline.json
#     # change the code
#     dev/scripts/presence-bench.sh --backends rollcall --compare _build/presence_bench/baseline.json
#
# The report shows each number before and after, with the change in percent, and draws the earlier
# Rollcall figures next to the new ones. The repeats of one run differ from each other, and more so
# in the join window. The results file keeps the lowest and the highest result of each figure.
# Compare a change with that spread.
#
# Compare runs that have the same settings. When a setting differs, the run prints a warning and
# the report shows a note above the changes.
#
# Settings
#
#   --tenants         default 20
#   --entries         average entries for each tenant, default 100
#   --nodes           nodes in the cluster, default 3. Each node holds every tenant.
#   --changes-per-s   changes each second across the whole cluster in the steady window, default 60
#   --repeats         default 5
#   --backends        phoenix, rollcall, or both separated by a comma. Default: both.
#   --scoped-cpu      also measure the CPU seconds of the measured processes alone. See above.
#   --compare         path of an earlier results file
#   --out             path of the results file. The script sets it.
#
# Set PRESENCE_POOL_SIZE for the number of Phoenix shards on each node. 
#
# The script creates tenants named presencebench-N in the dev database and deletes them afterwards.
# It also adds the two presence feature flags, switched off, if the database lacks them. It leaves
# them there.

defmodule PresenceBench do
  @moduledoc false

  @dir Path.expand("presence", __DIR__)
  @flags ["presence_rollcall_primary", "presence_rollcall_shadow"]
  @tenant_prefix "presencebench"
  @gen_rpc_base 5470
  @window_s 30
  @settle_s 2
  # The settings that change what a figure means, as `{section of the results file, key}`. A
  # comparison between runs that differ in one of them mixes two effects.
  @compared [
    {"settings", "tenants"},
    {"settings", "entries"},
    {"settings", "nodes"},
    {"settings", "changes_per_s"},
    {"workload", "shards"},
    {"workload", "schedulers_per_node"}
  ]
  @per_partition 100
  @meta_bytes 32
  @backends [:phoenix, :rollcall]
  @phoenix_shards 150
  @windows ["join", "steady"]
  @metrics ["reductions_per_s", "cpu_s_per_s", "memory_bytes"]
  # Only a run with `--scoped-cpu` has this figure.
  @scoped_metrics ["cpu_scoped_s_per_s"]
  # What a window did. They show what the reductions per second are made of. An operation is an
  # entry that joins, in the join window, or a change, in the steady window.
  @activity ["seconds", "operations", "operations_per_s", "reductions_per_operation"]
  @switches [
    tenants: :integer,
    entries: :integer,
    nodes: :integer,
    changes_per_s: :integer,
    repeats: :integer,
    backends: :string,
    out: :string,
    compare: :string,
    scoped_cpu: :boolean
  ]
  @base_settings %{
    tenants: 20,
    entries: 100,
    nodes: 3,
    changes_per_s: 60,
    repeats: 5,
    backends: @backends,
    out: nil,
    compare: nil,
    scoped_cpu: false
  }

  ## Entry point

  def main(argv) do
    settings = parse_settings(argv)
    # The app config reads PRESENCE_POOL_SIZE, and its default is 10. The peers copy this config.
    unless System.get_env("PRESENCE_POOL_SIZE"),
      do: Application.put_env(:realtime, :presence_pool_size, @phoenix_shards)

    backends = settings.backends
    total_phases = settings.repeats * length(backends)
    workload = workload(settings)

    step("#{settings.nodes} nodes, #{settings.repeats} repeats of #{Enum.join(backends, " then ")}")
    step("Workload: #{describe(workload)}")
    step("Each backend runs on its own cluster. Do not run other heavy work on this machine.")
    step("Load average at the start: #{load_average()}")

    runs =
      for repeat <- 1..settings.repeats,
          {backend, index} <- Enum.with_index(order(backends, repeat)) do
        phase = (repeat - 1) * length(backends) + index + 1
        run_phase(settings, backend, repeat, phase, total_phases)
      end

    result =
      %{
        started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        workload: workload,
        settings: settings |> Map.drop([:out, :compare]) |> Map.merge(%{window_s: @window_s}),
        machine: machine(),
        runs: runs,
        summary: summarize(runs)
      }
      |> normalize()

    result = if settings.compare, do: Map.merge(result, compare(result, settings.compare)), else: result

    for difference <- result["different_settings"] || [] do
      step(
        "Warning: #{difference["setting"]} was #{difference["before"]} in the earlier run and is #{difference["now"]} now"
      )
    end

    path = write_results(result, settings)
    step("Results written to #{path}")
  end

  defp order(backends, repeat) when rem(repeat, 2) == 1, do: backends
  defp order(backends, _repeat), do: Enum.reverse(backends)

  # Reads switches such as `--tenants 20`. An unknown switch, a value of the wrong type and a stray
  # argument stop the run before it starts a cluster.
  defp parse_settings(argv) do
    {given, rest} = OptionParser.parse!(argv, strict: @switches)
    if rest != [], do: raise("unexpected argument #{Enum.join(rest, " ")}")

    settings = @base_settings |> Map.merge(Map.new(given)) |> Map.update!(:backends, &backends/1)

    for key <- [:tenants, :entries, :nodes, :changes_per_s, :repeats], settings[key] < 1 do
      raise "--#{String.replace(Atom.to_string(key), "_", "-")} is #{settings[key]}, it must be at least 1"
    end

    # The comparison runs after the last repeat. A wrong path must not cost a whole run.
    if settings.compare && !File.exists?(settings.compare), do: raise("--compare file not found: #{settings.compare}")

    settings
  end

  defp backends(list) when is_list(list), do: list
  defp backends(names), do: names |> String.split(",") |> Enum.map(&backend/1)

  defp backend("phoenix"), do: :phoenix
  defp backend("rollcall"), do: :rollcall
  defp backend(name), do: raise("unknown backend #{name}. The backends are phoenix and rollcall")

  ## One backend on one fresh cluster

  defp run_phase(settings, backend, repeat, phase, total_phases) do
    step("Phase #{phase} of #{total_phases}: #{backend}, repeat #{repeat} of #{settings.repeats}")
    cluster = start_cluster(settings.nodes)
    nodes = cluster.nodes

    try do
      tenants = prepare_tenants(nodes, backend, settings.tenants)

      ctx = %{
        settings: settings,
        nodes: nodes,
        tenants: tenants,
        backend: backend,
        window_ms: @window_s * 1000
      }

      step("Cluster ready")
      counts = entry_counts(tenants, settings.entries)

      windows = [
        window(ctx, "join", [expect: counts], fn -> load(ctx, counts) end),
        window(ctx, "steady", fn -> make_changes(ctx) end)
      ]

      check_entries_held(ctx, counts)
      %{repeat: repeat, backend: backend, windows: windows}
    after
      step("Deleting the tenants and stopping the nodes")
      delete_tenants(nodes)
      stop_cluster(cluster)
    end
  end

  ## Workload

  defp tenant_ids(count), do: for(i <- 1..count, do: "#{@tenant_prefix}-#{i}")

  # The entries of each tenant, as `{tenant, entries}`. A tenth of the tenants, at least one, hold
  # 80% of the entries and the rest share the other 20%.
  defp entry_counts(tenants, entries) do
    total = length(tenants) * entries
    large_n = min(max(div(length(tenants) * 10, 100), 1), length(tenants))
    {large, small} = Enum.split(tenants, large_n)
    large_total = if small == [], do: total, else: div(total * 80, 100)

    large_each = div(large_total, large_n)
    small_each = if small == [], do: 0, else: max(div(total - large_total, length(small)), 1)

    Enum.map(large, &{&1, large_each}) ++ Enum.map(small, &{&1, small_each})
  end

  # What a run does, for the results file: the layout of the tenants, and the changes.
  defp workload(settings) do
    counts = settings.tenants |> tenant_ids() |> entry_counts(settings.entries)
    entries = counts |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    changes_per_s = settings.changes_per_s

    groups =
      counts
      |> Enum.group_by(fn {_, entries} -> entries end)
      |> Enum.sort_by(fn {entries, _} -> -entries end)
      |> Enum.map(fn {each, tenants} -> %{tenants: length(tenants), entries: each, topics: length(topics(each))} end)

    %{
      nodes: settings.nodes,
      schedulers_per_node: schedulers_per_node(settings.nodes),
      shards: Application.fetch_env!(:realtime, :presence_pool_size),
      entries: entries,
      groups: groups,
      entries_per_topic: @per_partition,
      window_s: @window_s,
      changes_per_s: changes_per_s,
      changed_percent_per_s: if(entries == 0, do: 0, else: Float.round(changes_per_s / entries * 100, 1))
    }
  end

  defp describe(workload) do
    groups =
      Enum.map_join(workload.groups, " and ", &"#{&1.tenants} with #{&1.entries} entries on #{&1.topics} topic(s)")

    "#{workload.entries} entries. Tenants: #{groups}. #{workload.changes_per_s} changes per second."
  end

  # Starts the clients for `counts`, a list of `{tenant, entries}`. The entries of each topic spread
  # evenly over the nodes. Each node gets a listener for every tenant first. Returns the number of
  # entries that joined.
  defp load(ctx, counts) do
    step("Joining #{total_entries(counts)} entries of #{length(counts)} tenants")

    parallel(ctx.nodes, fn node -> rpc(node, PresenceBench.Node, :watch, [ctx.tenants]) end)

    ctx.nodes
    |> Enum.with_index()
    |> parallel(fn {node, index} ->
      specs =
        for {tenant, entries} <- counts,
            {topic, size} <- topics(entries),
            {from, amount} <- [split(size, length(ctx.nodes), index)],
            amount > 0 do
          {tenant, topic, from, amount}
        end

      rpc(node, PresenceBench.Node, :join, [specs, @meta_bytes])
    end)
    |> Enum.sum()
  end

  # Makes the changes of the `changes_per_s` setting for the length of the steady window. The nodes
  # share them evenly. Returns the number of changes sent to the clients.
  defp make_changes(ctx) do
    per_node = ctx.settings.changes_per_s / length(ctx.nodes)

    parallel(ctx.nodes, fn node -> rpc(node, PresenceBench.Node, :make_changes, [ctx.window_ms, per_node]) end)
    |> Enum.sum()
  end

  # The changes must not change the number of entries. A node that holds fewer or more entries than
  # it should means the figures of the steady window describe another workload. A few entries in
  # flight are normal, so the check allows 5%.
  defp check_entries_held(ctx, counts) do
    held = ctx |> on_nodes_with_node(PresenceBench.Node, :entries, [ctx.backend]) |> Map.new()
    wanted = total_entries(counts)

    for {node, entries} <- held, abs(entries - wanted) > wanted * 0.05 do
      raise "after the steady window #{node} holds #{entries} entries, not #{wanted}"
    end

    :ok
  end

  # Runs `fun` and returns the figures of every process between the start and the end of the window,
  # and the return value of `fun` as `output`. Pass `expect: counts`, the list that `load/2` took, to
  # wait until every node holds all the entries, and then to wait a few seconds more.
  defp window(ctx, label, opts \\ [], fun) do
    step("Window #{label}")
    start = snapshots(ctx, :start)
    started = System.monotonic_time(:millisecond)
    output = fun.()

    if counts = opts[:expect] do
      await_entries(ctx, counts)
      Process.sleep(@settle_s * 1000)
    end

    ended = System.monotonic_time(:millisecond)
    finish = snapshots(ctx, :end)

    %{
      label: label,
      duration_ms: ended - started,
      output: output,
      nodes: summarize_window(start, finish),
      cpu: cpu_busy(start, finish),
      scoped_cpu: scoped_cpu_busy(finish)
    }
  end

  # The CPU seconds that the measured processes of each node used for each second of the window.
  # The map is empty when the run does not have `--scoped-cpu`.
  defp scoped_cpu_busy(finish) do
    for {node, %{scoped_cpu: %{busy_ns: busy, wall_ns: wall}}} <- finish, into: %{}, do: {node, busy / wall}
  end

  defp topics(entries) do
    for j <- 0..div(entries - 1, @per_partition) do
      {"topic#{j}", min(@per_partition, entries - j * @per_partition)}
    end
  end

  # The first index and the number of entries of node `index` out of `count` nodes.
  defp split(size, count, index) do
    {base, extra} = {div(size, count), rem(size, count)}
    {index * base + min(index, extra), base + if(index < extra, do: 1, else: 0)}
  end

  defp await_entries(ctx, counts) do
    deadline = System.monotonic_time(:second) + 120
    await_entries(ctx, counts, deadline)
  end

  defp await_entries(ctx, counts, deadline) do
    held = ctx |> on_nodes_with_node(PresenceBench.Node, :entries, [ctx.backend]) |> Map.new()
    wanted = Map.new(ctx.nodes, &{&1, total_entries(counts)})

    cond do
      held == wanted ->
        :ok

      System.monotonic_time(:second) > deadline ->
        raise "after 120 s the nodes hold #{inspect(held)} entries, not #{inspect(wanted)}"

      true ->
        Process.sleep(500)
        await_entries(ctx, counts, deadline)
    end
  end

  defp total_entries(counts), do: counts |> Enum.map(&elem(&1, 1)) |> Enum.sum()

  defp snapshots(ctx, mode),
    do: Map.new(on_nodes_with_node(ctx, PresenceBench.Node, :snapshot, [mode, ctx.settings.scoped_cpu]))

  defp on_nodes_with_node(ctx, module, function, args) do
    parallel(ctx.nodes, fn node -> {node, rpc(node, module, function, args)} end)
  end

  # The CPU seconds that each node used for each second of the window. Each scheduler is busy for
  # a share of the window. The sum of the shares over the schedulers is the CPU seconds per second.
  defp cpu_busy(start, finish) do
    for {node, %{schedulers: now}} <- finish, into: %{} do
      before = Map.new(Map.fetch!(start, node).schedulers, fn {id, active, total} -> {id, {active, total}} end)

      busy =
        Enum.reduce(now, 0.0, fn {id, active, total}, sum ->
          {active_before, total_before} = Map.fetch!(before, id)
          sum + (active - active_before) / (total - total_before)
        end)

      {node, busy}
    end
  end

  defp summarize_window(start, finish) do
    for {node, %{processes: procs}} <- finish, into: %{} do
      before = Map.new(Map.fetch!(start, node).processes, &{&1.pid, &1.reductions})

      by_backend =
        procs
        |> Enum.group_by(& &1.backend)
        |> Map.new(fn {backend, list} ->
          {backend,
           %{
             processes: length(list),
             memory_bytes: list |> Enum.map(& &1.memory_bytes) |> Enum.sum(),
             # A process that did not exist at the start, such as a tracker that started in the
             # window, began at 0 reductions.
             reductions: list |> Enum.map(&(&1.reductions - Map.get(before, &1.pid, 0))) |> Enum.sum()
           }}
        end)

      {node, by_backend}
    end
  end

  ## Cluster

  defp start_cluster(node_count) do
    indexes = Enum.to_list(1..node_count)
    nodes = for i <- indexes, do: :"pbench#{i}@127.0.0.1"
    gen_rpc_ports = Map.new(Enum.zip(nodes, Enum.map(indexes, &(@gen_rpc_base + &1 - 1))))

    for port <- Map.values(gen_rpc_ports), do: await_port(port)

    step("Starting #{node_count} nodes")

    vm_args = vm_args(schedulers_per_node(node_count))
    peers = for node <- nodes, do: start_peer(node, gen_rpc_ports, vm_args)

    for a <- nodes, b <- nodes, a != b, do: true = :erpc.call(a, Node, :connect, [b])
    for node <- nodes, do: true = Node.connect(node)

    for node <- nodes do
      rpc(node, Code, :require_file, [Path.join(@dir, "node.exs")])
    end

    await_muster(nodes)
    %{nodes: nodes, peers: peers}
  end

  # The nodes share one machine. Each node gets its share of the cores, so the schedulers of the
  # nodes do not compete for a core and the CPU time is not the time of a thread that the OS paused.
  # A scheduler that has no work sleeps at once and does not spin, because the spin counts as busy
  # time in the scheduler wall time.
  defp schedulers_per_node(node_count), do: max(div(System.schedulers_online(), node_count), 1)

  defp vm_args(schedulers) do
    [
      ~c"+S",
      Integer.to_charlist(schedulers),
      ~c"+sbwt",
      ~c"none",
      ~c"+sbwtdcpu",
      ~c"none",
      ~c"+sbwtdio",
      ~c"none"
    ]
  end

  defp start_peer(node, gen_rpc_ports, vm_args) do
    [name, _host] = node |> Atom.to_string() |> String.split("@")

    {:ok, pid, ^node} =
      :peer.start_link(%{
        name: String.to_charlist(name),
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        args: vm_args
      })

    call = fn m, f, a -> :peer.call(pid, m, f, a, 120_000) end

    call.(:erlang, :set_cookie, [:cookie])
    call.(:code, :add_paths, [:code.get_path()])
    # The app env has defaults that a put_env before the load would lose, so load first.
    call.(Application, :ensure_loaded, [:gen_rpc])

    # The peers copy the app config of the coordinator. That is how the number of Phoenix shards
    # reaches them.
    for {app, _, _} <- Application.loaded_applications(), {key, value} <- Application.get_all_env(app) do
      call.(Application, :put_env, [app, key, value])
    end

    overrides = [
      {:gen_rpc, :tcp_server_port, Map.fetch!(gen_rpc_ports, node)},
      {:gen_rpc, :client_config_per_node, {:internal, gen_rpc_ports}},
      # The dev topology finds the other servers through the shared database. The peers connect to
      # each other below, and a running dev server must not join them.
      {:libcluster, :topologies, []}
    ]

    for {app, key, value} <- overrides, do: call.(Application, :put_env, [app, key, value])

    # The peers log at :info by default. The log lines would bury the progress lines. While the app
    # starts, the metric pollers log errors because the tables they read do not exist yet. Only
    # errors that stop the start matter, and `ensure_all_started` raises those.
    call.(Application, :put_env, [:logger, :level, :critical])
    {:ok, _} = call.(Application, :ensure_all_started, [:realtime])
    call.(Logger, :configure, [[level: :warning]])

    pid
  end

  defp stop_cluster(%{peers: peers, nodes: nodes}) do
    # A node that stops closes its gen_rpc channels, and the other nodes log an error for each one.
    for node <- nodes, do: rpc(node, Logger, :configure, [[level: :critical]])
    for pid <- peers, do: :peer.stop(pid)
    for node <- nodes, do: Node.disconnect(node)
    :ok
  end

  defp await_muster(nodes) do
    scope = rpc(hd(nodes), Application, :get_env, [:realtime, :muster_scope])
    deadline = System.monotonic_time(:second) + 60

    ready? = fn ->
      Enum.all?(nodes, &(rpc(&1, Forum.Muster, :status, [scope]) == :ready)) and
        nodes |> Enum.map(&rpc(&1, Forum.Muster, :view_hash, [scope])) |> Enum.uniq() |> length() == 1
    end

    until(deadline, ready?, "Muster is not ready on #{inspect(nodes)} after 60 s")
  end

  defp await_port(port) do
    deadline = System.monotonic_time(:second) + 15

    until(
      deadline,
      fn -> Realtime.Env.port_available?(port) end,
      "port #{port} is in use. Another run or a dev server holds it"
    )
  end

  defp until(deadline, fun, message) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:second) > deadline ->
        raise message

      true ->
        Process.sleep(250)
        until(deadline, fun, message)
    end
  end

  ## Tenants

  defp prepare_tenants(nodes, backend, count) do
    first = hd(nodes)
    # A run that stopped early leaves its tenants. Delete them first.
    delete_tenants(nodes)

    for name <- @flags do
      if rpc(first, Realtime.Api, :get_feature_flag, [name]) == nil do
        {:ok, _} = rpc(first, Realtime.Api, :upsert_feature_flag, [%{name: name, enabled: false}])
      end

      for node <- nodes, do: rpc(node, Realtime.FeatureFlags.Cache, :invalidate_cache, [name])
    end

    # A tenant override sets the presence mode, so no other server that uses this database sees a
    # change. Both flags get a value, so a flag that is on for every tenant cannot change the mode.
    overrides = %{"presence_rollcall_primary" => backend == :rollcall, "presence_rollcall_shadow" => false}

    step("Creating #{count} tenants")

    tenants =
      for i <- 1..count do
        id = "#{@tenant_prefix}-#{i}"

        {:ok, _} =
          rpc(first, Realtime.Api, :create_tenant, [
            %{"external_id" => id, "name" => id, "jwt_secret" => "bench", "feature_flags" => overrides}
          ])

        id
      end

    for node <- nodes do
      mode = rpc(node, Realtime.Presence, :mode, [List.first(tenants)])
      if mode != backend, do: raise("#{node} runs the mode #{mode}, not #{backend}")
    end

    tenants
  end

  defp delete_tenants(nodes) do
    first = hd(nodes)

    for tenant <- rpc(first, Realtime.Api, :list_tenants, []),
        String.starts_with?(tenant.external_id, @tenant_prefix <> "-") do
      rpc(first, Realtime.Api, :delete_tenant_by_external_id, [tenant.external_id])
    end

    :ok
  end

  ## Results

  # For each backend and window, the median, minimum and maximum over the repeats of each figure.
  defp summarize(runs) do
    for {backend, backend_runs} <- Enum.group_by(runs, & &1.backend), into: %{} do
      {backend,
       for label <- @windows, into: %{} do
         figures =
           for run <- backend_runs do
             figures(Enum.find(run.windows, &(&1.label == label)), backend)
           end

         # A figure that a run did not measure is nil, and the summary leaves it out.
         names =
           Enum.filter(@metrics ++ @scoped_metrics ++ @activity, fn name -> Enum.all?(figures, &(&1[name] != nil)) end)

         {label, Map.new(names, fn name -> {name, stats(Enum.map(figures, &Map.fetch!(&1, name)))} end)}
       end}
    end
  end

  # The figures of one window of one run, summed over the nodes.
  defp figures(window, backend) do
    nodes = window.nodes |> Map.values() |> Enum.map(&Map.get(&1, backend, %{}))
    sum = fn key -> nodes |> Enum.map(&Map.get(&1, key, 0)) |> Enum.sum() end
    seconds = window.duration_ms / 1000
    operations = window.output

    %{
      "reductions_per_s" => sum.(:reductions) / seconds,
      "cpu_s_per_s" => window.cpu |> Map.values() |> Enum.sum(),
      "cpu_scoped_s_per_s" => if(map_size(window.scoped_cpu) > 0, do: window.scoped_cpu |> Map.values() |> Enum.sum()),
      "memory_bytes" => sum.(:memory_bytes),
      "seconds" => seconds,
      "operations" => operations,
      "operations_per_s" => operations / seconds,
      "reductions_per_operation" => if(operations == 0, do: 0, else: sum.(:reductions) / operations)
    }
  end

  defp stats(values) do
    sorted = Enum.sort(values)
    mid = div(length(sorted), 2)

    median =
      if rem(length(sorted), 2) == 1,
        do: Enum.at(sorted, mid),
        else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2

    %{median: median, min: hd(sorted), max: List.last(sorted)}
  end

  defp normalize(result), do: result |> Jason.encode!() |> Jason.decode!()

  defp write_results(result, settings) do
    path =
      settings.out ||
        Path.join([File.cwd!(), "_build", "presence_bench", "presence-#{System.os_time(:second)}.json"])

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(result, pretty: true))
    path
  end

  # The change of each figure against an earlier results file. The results file keeps the earlier
  # figures and the changes, so the report draws them and does not work them out again.
  defp compare(result, path) do
    old = path |> File.read!() |> Jason.decode!()

    rows =
      for {backend, windows} <- Enum.sort(result["summary"]),
          label <- @windows,
          metric <- @metrics ++ @scoped_metrics,
          before = get_in(old, ["summary", backend, label, metric]),
          now = windows[label][metric] do
        %{
          "backend" => backend,
          "window" => label,
          "metric" => metric,
          "before" => before["median"],
          "now" => now["median"],
          "percent" =>
            if(before["median"] == 0,
              do: 0.0,
              else: Float.round((now["median"] - before["median"]) / before["median"] * 100, 1)
            )
        }
      end

    %{
      "baseline" => Map.take(old, ["settings", "summary"]) |> Map.put("file", path),
      "comparison" => rows,
      "different_settings" => different_settings(result, old)
    }
  end

  # The settings in `@compared` that differ between the runs. An earlier file that lacks a setting
  # differs, because the setting did not exist then.
  defp different_settings(result, old) do
    for {section, key} <- @compared,
        before = get_in(old, [section, key]) || "missing",
        now = get_in(result, [section, key]),
        before != now do
      %{"setting" => key, "before" => before, "now" => now}
    end
  end

  ## Machine and arguments

  defp machine do
    %{
      os: :erlang.system_info(:system_architecture) |> to_string(),
      otp: :erlang.system_info(:otp_release) |> to_string(),
      elixir: System.version(),
      schedulers: :erlang.system_info(:schedulers_online),
      cpu: cmd("sysctl", ["-n", "machdep.cpu.brand_string"]),
      memory_bytes: cmd("sysctl", ["-n", "hw.memsize"]),
      load_average_at_start: load_average()
    }
  end

  defp load_average do
    case cmd("uptime", []) do
      nil -> nil
      text -> text |> String.split("load average", parts: 2) |> List.last() |> String.trim_leading("s: ")
    end
  end

  defp cmd(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  ## Helpers

  defp rpc(node, module, function, args), do: :erpc.call(node, module, function, args, :infinity)

  defp parallel(items, fun) do
    items
    |> Task.async_stream(fun, timeout: :infinity, ordered: true, max_concurrency: max(length(items), 1))
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp step(message) do
    time = Time.utc_now() |> Time.truncate(:second) |> Time.to_string()
    IO.puts("[#{time}] #{message}")
  end
end

PresenceBench.main(System.argv())
