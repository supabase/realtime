defmodule Mix.Tasks.Forum.Muster.Chaos do
  @moduledoc """
  Chaos-tests `Forum.Muster` across a real multi-node cluster.

  Spins up N real `:peer` nodes running Muster, churns a configurable number
  of unique groups joining/leaving at random across those nodes, and
  simultaneously injects faults (node disconnects/reconnects, coordinator
  crashes, shard crashes) for a configured duration. Every join/leave/kill is
  driven and recorded by this task itself, so it always knows the exact
  expected final state ahead of the run: which node should route each group,
  which nodes should hold it, and which local pids each node should have
  registered. After the chaos window it heals every partition, waits for the
  cluster to converge, and diffs that expected state against the real ETS
  tables (the router-role occupancy table and each node's local membership
  table) -- not just the public API.

  ## Usage

      mix forum.muster.chaos [options]

  ## Options

    * `--nodes` (`-n`) - number of peer nodes to run the cluster across
      (default: 4).
    * `--groups` (`-g`) - number of unique groups to churn (default: 200).
    * `--duration` (`-d`) - how long to run the chaos window, in seconds
      (default: 60).
    * `--members-per-group` - `MIN-MAX` members seeded per group at start
      (default: "1-3").
    * `--churn-rate` - join/leave operations per second across the whole
      cluster (default: 10).
    * `--chaos-rate` - fault-injection events per second across the whole
      cluster (default: 1).
    * `--chaos-actions` - comma list of enabled fault types, any of
      `disconnect`, `reconnect`, `crash_scope`, `crash_shard`
      (default: all four).
    * `--seed` - integer RNG seed; printed at the start of every run so a
      failing run's *scheduling decisions* can be replayed (real wall-clock
      races are not deterministic, so a replay is not a byte-for-byte
      guarantee).
    * `--settle-timeout` - max seconds to wait for convergence after the
      chaos window ends, before failing (default: 30).
    * `--vacancy-cooldown-ms`, `--vacant-flush-interval-ms`,
      `--view-heartbeat-interval-ms` - forwarded to `Forum.Muster.start_link/2`
      on every node, defaulted low (200/100/300ms) so the run settles quickly;
      raise `--settle-timeout` if you raise these.
    * `--tombstone-window-ms` - forwarded to `Forum.Muster.start_link/2`
      (default: 500, vs. production's `rpc_timeout_ms * 5` = 25000). Governs
      both how long a vacated group's occupancy row is kept as a tombstone
      before the periodic sweep physically deletes it, and the sweep's own
      interval, so raising this also raises how long we wait post-settle for
      sunset groups' rows to be reaped (see `--sunset-fraction`).
    * `--partitions` - shards per node; omit to use each node's own
      `System.schedulers_online/0`.
    * `--scope` - Muster scope name (default: `muster_chaos`).
    * `--keep-nodes-on-failure` - leave the peer nodes running for post-mortem
      `Forum.Muster.dump/1` inspection if the final assertions fail (default:
      false).
    * `--crash-cooldown-ms` - minimum time between `crash_scope`/`crash_shard`
      hits on the *same* node (default: 2000). Crashing one node faster than
      it can restart exhausts Supervisor's default restart budget (3 restarts
      / 5s) and kills it permanently -- a real failure mode, but not what
      "crash and verify recovery" is asking for. Set to 0 to deliberately
      allow it; the run still completes (see `--dead-node-grace-ms`), just
      with that node excluded from the final expected state.
    * `--dead-node-grace-ms` - how long a node's dump must fail continuously
      before it is treated as permanently dead rather than mid-restart
      (default: 3000).
    * `--sunset-fraction` - fraction of groups (default: 0.1) that are
      drained to zero members right after seeding and then permanently
      excluded from further churn, so they are guaranteed to sit vacant for
      the rest of the run under whatever chaos is happening around them --
      exercising the full cooldown -> vacant_queued -> vacant flush ->
      tombstone path, not just groups that happen to hit zero by luck between
      random churn picks. Set to 0 to disable.

  ## Example

      mix forum.muster.chaos --nodes 6 --groups 500 --duration 120 \\
        --churn-rate 30 --chaos-rate 2
  """
  @shortdoc "Chaos-tests Forum.Muster across a real multi-node cluster"

  use Mix.Task

  @all_chaos_actions [:disconnect, :reconnect, :crash_scope, :crash_shard]

  @aux_mod (quote do
              defmodule MusterChaosPeerAux do
                @moduledoc false

                def start(scope, opts) do
                  owner =
                    spawn(fn ->
                      {:ok, _} = Forum.Muster.start_link(scope, opts)
                      Process.sleep(:infinity)
                    end)

                  Process.register(owner, :muster_chaos_owner)
                  :ok
                end

                def dump(scope) do
                  GenServer.call(Forum.Supervisor.name(scope), :dump, 15_000)
                catch
                  :exit, reason -> {:error, {:exit, reason}}
                end

                def router(scope, group) do
                  Forum.Muster.router(scope, group)
                catch
                  :exit, reason -> {:error, {:exit, reason}}
                end

                def spawn_member(scope, group) do
                  pid = spawn(fn -> member_loop() end)

                  case Forum.Muster.join(scope, group, pid) do
                    :ok ->
                      {:ok, pid}

                    other ->
                      Process.exit(pid, :kill)
                      other
                  end
                end

                defp member_loop do
                  receive do
                    :stop -> :ok
                  end
                end

                def leave_member(scope, group, pid) do
                  result = Forum.Muster.leave(scope, group, pid)
                  Process.exit(pid, :kill)
                  result
                end

                def kill_member(pid) do
                  Process.exit(pid, :kill)
                  :ok
                end

                def alive?(pid), do: Process.alive?(pid)

                def raw_occupancy(scope) do
                  :ets.tab2list(Forum.Muster.Scope.occupancy_table_name(scope))
                end

                def raw_entries(scope) do
                  scope
                  |> Forum.Supervisor.partitions()
                  |> Enum.flat_map(&:ets.tab2list(Forum.Supervisor.partition_entries_table(&1)))
                end

                def crash_scope(scope) do
                  case Process.whereis(Forum.Supervisor.name(scope)) do
                    nil ->
                      :noproc

                    pid ->
                      Process.exit(pid, :kill)
                      :ok
                  end
                end

                def crash_shard(scope, index) do
                  case Process.whereis(Forum.Supervisor.shard_name(scope, index)) do
                    nil ->
                      :noproc

                    pid ->
                      Process.exit(pid, :kill)
                      :ok
                  end
                end

                def shard_count(scope), do: length(Forum.Supervisor.shards(scope))

                def disconnect_from(others), do: Enum.each(others, &Node.disconnect/1)
                def connect_to(others), do: Enum.each(others, &Node.connect/1)
              end
            end)

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {:ok, _} = Application.ensure_all_started(:ex_hash_ring)

    opts = parse_opts!(args)

    seed = opts.seed
    :rand.seed(:exsss, {seed, seed, seed})
    IO.puts("== forum.muster.chaos ==")
    IO.puts("seed: #{seed} (scheduling decisions are reproducible with --seed #{seed})")
    print_opts(opts)

    cluster = boot_cluster(opts)

    try do
      run_experiment(cluster, opts)
    after
      unless opts.keep_nodes_on_failure do
        Enum.each(cluster.peers, fn {_node, peer} -> :peer.stop(peer) end)
      end
    end
  end

  ## Option parsing

  defp parse_opts!(args) do
    {parsed, _rest, invalid} =
      OptionParser.parse(args,
        strict: [
          nodes: :integer,
          groups: :integer,
          duration: :integer,
          members_per_group: :string,
          churn_rate: :float,
          chaos_rate: :float,
          chaos_actions: :string,
          seed: :integer,
          settle_timeout: :integer,
          vacancy_cooldown_ms: :integer,
          vacant_flush_interval_ms: :integer,
          view_heartbeat_interval_ms: :integer,
          tombstone_window_ms: :integer,
          partitions: :integer,
          scope: :string,
          keep_nodes_on_failure: :boolean,
          tick_ms: :integer,
          log_every: :integer,
          crash_cooldown_ms: :integer,
          dead_node_grace_ms: :integer,
          sunset_fraction: :float
        ],
        aliases: [n: :nodes, g: :groups, d: :duration]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    {min_members, max_members} = parse_range(parsed[:members_per_group] || "1-3")

    chaos_actions =
      (parsed[:chaos_actions] || "disconnect,reconnect,crash_scope,crash_shard")
      |> String.split(",", trim: true)
      |> Enum.map(&String.to_existing_atom/1)

    for a <- chaos_actions, a not in @all_chaos_actions do
      Mix.raise(
        "Unknown chaos action #{inspect(a)}, expected one of #{inspect(@all_chaos_actions)}"
      )
    end

    nodes = parsed[:nodes] || 4
    groups = parsed[:groups] || 200

    if nodes < 1, do: Mix.raise("--nodes must be >= 1")
    if groups < 1, do: Mix.raise("--groups must be >= 1")

    %{
      nodes: nodes,
      groups: groups,
      duration_ms: (parsed[:duration] || 60) * 1_000,
      min_members_per_group: min_members,
      max_members_per_group: max_members,
      churn_rate: parsed[:churn_rate] || 10.0,
      chaos_rate: parsed[:chaos_rate] || 1.0,
      chaos_actions: chaos_actions,
      seed: parsed[:seed] || System.system_time(:microsecond) |> abs() |> rem(1_000_000_000),
      settle_timeout_ms: (parsed[:settle_timeout] || 30) * 1_000,
      vacancy_cooldown_ms: parsed[:vacancy_cooldown_ms] || 200,
      vacant_flush_interval_ms: parsed[:vacant_flush_interval_ms] || 100,
      view_heartbeat_interval_ms: parsed[:view_heartbeat_interval_ms] || 300,
      tombstone_window_ms: parsed[:tombstone_window_ms] || 500,
      partitions: parsed[:partitions],
      scope: String.to_atom(parsed[:scope] || "muster_chaos"),
      keep_nodes_on_failure: parsed[:keep_nodes_on_failure] || false,
      tick_ms: parsed[:tick_ms] || 100,
      log_every_ms: (parsed[:log_every] || 2) * 1_000,
      crash_cooldown_ms: parsed[:crash_cooldown_ms] || 2_000,
      dead_node_grace_ms: parsed[:dead_node_grace_ms] || 3_000,
      sunset_fraction: parsed[:sunset_fraction] || 0.1
    }
  end

  defp parse_range(str) do
    case String.split(str, "-", parts: 2) do
      [a, b] -> {String.to_integer(a), String.to_integer(b)}
      [a] -> {String.to_integer(a), String.to_integer(a)}
    end
  end

  defp print_opts(opts) do
    IO.puts(
      "nodes=#{opts.nodes} groups=#{opts.groups} duration=#{div(opts.duration_ms, 1000)}s " <>
        "members_per_group=#{opts.min_members_per_group}-#{opts.max_members_per_group} " <>
        "churn_rate=#{opts.churn_rate}/s chaos_rate=#{opts.chaos_rate}/s " <>
        "chaos_actions=#{inspect(opts.chaos_actions)} settle_timeout=#{div(opts.settle_timeout_ms, 1000)}s"
    )
  end

  ## Cluster bootstrap

  defp boot_cluster(opts) do
    cookie = String.to_atom("muster_chaos_#{opts.seed}")

    nodes_and_peers =
      for i <- 1..opts.nodes do
        name = :"muster_chaos_#{i}_#{opts.seed}"
        {peer, node} = start_peer(name, cookie)
        {node, peer}
      end

    all_nodes = nodes_and_peers |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    peers = Map.new(nodes_and_peers)

    muster_opts = [
      vacancy_cooldown_ms: opts.vacancy_cooldown_ms,
      vacant_flush_interval_ms: opts.vacant_flush_interval_ms,
      view_heartbeat_interval_ms: opts.view_heartbeat_interval_ms,
      tombstone_window_ms: opts.tombstone_window_ms
    ]

    muster_opts =
      if opts.partitions,
        do: Keyword.put(muster_opts, :partitions, opts.partitions),
        else: muster_opts

    for {_node, peer} <- peers do
      :ok = :peer.call(peer, MusterChaosPeerAux, :start, [opts.scope, muster_opts])
    end

    # -connect_all false leaves each peer's mesh entirely to us: connect every
    # pair explicitly now, and later chaos disconnect/reconnect actions manage
    # the graph on their own without any node auto-healing a partition we made.
    for {node_a, peer_a} <- peers, node_b <- all_nodes, node_b != node_a do
      true = :peer.call(peer_a, Node, :connect, [node_b])
    end

    IO.puts("booted #{opts.nodes} nodes: #{inspect(all_nodes)}")

    %{peers: peers, all_nodes: all_nodes}
  end

  defp start_peer(name, cookie) do
    {:ok, peer, node} =
      :peer.start_link(%{
        name: name,
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        args: [~c"-connect_all", ~c"false"]
      })

    true = :peer.call(peer, :erlang, :set_cookie, [cookie])
    :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])

    for {app, _, _} <- Application.loaded_applications(),
        {key, value} <- Application.get_all_env(app) do
      :peer.call(peer, Application, :put_env, [app, key, value])
    end

    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:forum])
    {{:module, _, _, _}, []} = :peer.call(peer, Code, :eval_quoted, [@aux_mod])

    {peer, node}
  end

  ## Experiment orchestration

  defp run_experiment(cluster, opts) do
    await_initial_convergence(cluster, opts)

    groups = for i <- 1..opts.groups, do: :"g#{i}"

    state = %{
      opts: opts,
      cluster: cluster,
      groups: groups,
      active_groups: groups,
      sunset_groups: MapSet.new(),
      members: %{},
      node_status: Map.new(cluster.all_nodes, &{&1, :connected}),
      crash_cooldowns: %{},
      churn_events: 0,
      chaos_events: %{disconnect: 0, reconnect: 0, crash_scope: 0, crash_shard: 0}
    }

    state = seed_initial_members(state)

    IO.puts("seeded #{count_members(state)} initial members across #{length(groups)} groups")

    state = sunset_groups(state)

    IO.puts(
      "sunset #{MapSet.size(state.sunset_groups)} group(s) to permanent vacancy " <>
        "(drained now, excluded from further churn): #{inspect(Enum.take(MapSet.to_list(state.sunset_groups), 10))}#{if MapSet.size(state.sunset_groups) > 10, do: "...", else: ""}"
    )

    IO.puts("running chaos window for #{div(opts.duration_ms, 1000)}s...")

    deadline = System.monotonic_time(:millisecond) + opts.duration_ms
    state = chaos_loop(state, deadline, System.monotonic_time(:millisecond))

    IO.puts(
      "chaos window done: #{state.churn_events} churn ops, chaos events #{inspect(state.chaos_events)}"
    )

    state = heal_all_partitions(state)

    {settled?, live_nodes, dead_nodes} = await_settle(state)

    if dead_nodes != [] do
      IO.puts(
        "!! #{length(dead_nodes)} node(s) permanently died during chaos (exceeded their " <>
          "Supervisor restart budget -- consider raising --crash-cooldown-ms): #{inspect(dead_nodes)}"
      )
    end

    reaped? = await_tombstone_reap(state, settled?, live_nodes)

    {expected_router, expected_sources, expected_local, final_dumps} =
      build_oracle(state, live_nodes)

    report =
      assert_convergence(
        state,
        live_nodes,
        expected_router,
        expected_sources,
        expected_local,
        final_dumps
      )

    print_report(report, settled?, dead_nodes, reaped?)

    if not settled? or not reaped? or report.failures != [] do
      Mix.raise("forum.muster.chaos FAILED (see report above)")
    end
  end

  defp await_initial_convergence(cluster, opts) do
    wait_until(opts.settle_timeout_ms, fn ->
      Enum.all?(cluster.peers, fn {_node, peer} ->
        case :peer.call(peer, MusterChaosPeerAux, :dump, [opts.scope]) do
          %{status: :ready, ring_nodes: ring_nodes} ->
            Enum.sort(ring_nodes) == cluster.all_nodes

          _ ->
            false
        end
      end)
    end) || Mix.raise("cluster did not reach initial convergence within --settle-timeout")

    IO.puts("initial cluster converged")
  end

  defp seed_initial_members(state) do
    Enum.reduce(state.groups, state, fn group, state ->
      count = Enum.random(state.opts.min_members_per_group..state.opts.max_members_per_group)

      Enum.reduce(1..count, state, fn _, state ->
        node = random_connected_node(state)
        do_join(state, group, node)
      end)
    end)
  end

  # Deterministically exercises the vacant-batch path: picks a fixed fraction
  # of groups, immediately removes every member they currently have (a real
  # leave, same code path as churn), and excludes them from `active_groups`
  # so ordinary churn never rejoins them. Left alone, a group's local member
  # count naturally reflects at zero after any random churn leave (the next
  # random pick of that same group forces a rejoin -- see `churn_action/1`),
  # so without this, whether any group survives long enough vacant to clear
  # cooldown + flush and get tombstoned is down to luck. This makes it
  # certain, and keeps it vacant under the full remaining chaos window
  # (crashes, partitions) rather than just a quiet moment.
  defp sunset_groups(state) do
    count = round(length(state.groups) * state.opts.sunset_fraction)
    sunset = state.groups |> Enum.take_random(count) |> MapSet.new()

    state =
      Enum.reduce(sunset, state, fn group, state ->
        Enum.reduce(members_for_group(state, group), state, fn {node, pid}, state ->
          do_leave(state, group, node, pid)
        end)
      end)

    %{state | sunset_groups: sunset, active_groups: Enum.reject(state.groups, &(&1 in sunset))}
  end

  ## Chaos loop

  defp chaos_loop(state, deadline, last_log_at) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      state
    else
      state = tick(state)
      Process.sleep(state.opts.tick_ms)

      last_log_at =
        if now - last_log_at >= state.opts.log_every_ms do
          IO.puts(
            "  t+#{div(now - (deadline - state.opts.duration_ms), 1000)}s: " <>
              "members=#{count_members(state)} churn=#{state.churn_events} " <>
              "isolated=#{inspect(isolated_nodes(state))}"
          )

          now
        else
          last_log_at
        end

      chaos_loop(state, deadline, last_log_at)
    end
  end

  defp tick(state) do
    tick_fraction = state.opts.tick_ms / 1_000

    state =
      apply_n_times(state, poisson_count(state.opts.churn_rate * tick_fraction), &churn_action/1)

    apply_n_times(state, poisson_count(state.opts.chaos_rate * tick_fraction), &chaos_action/1)
  end

  defp apply_n_times(state, 0, _fun), do: state
  defp apply_n_times(state, n, fun), do: apply_n_times(fun.(state), n - 1, fun)

  # Randomly rounds a fractional expected event count up or down so the
  # long-run average across many ticks matches `rate`, without needing a full
  # Poisson sampler.
  defp poisson_count(rate) do
    whole = trunc(rate)
    frac = rate - whole
    if :rand.uniform() < frac, do: whole + 1, else: whole
  end

  defp churn_action(state) do
    case {random_connected_node(state), state.active_groups} do
      {nil, _} ->
        state

      {_, []} ->
        state

      _ ->
        group = Enum.random(state.active_groups)
        members_here = members_for_group(state, group)

        if members_here == [] or :rand.uniform() < 0.5 do
          node = random_connected_node(state)
          do_join(state, group, node)
        else
          {node, pid} = Enum.random(members_here)
          do_leave(state, group, node, pid)
        end
    end
  end

  defp do_join(state, group, node) do
    peer = state.cluster.peers[node]

    case :peer.call(peer, MusterChaosPeerAux, :spawn_member, [state.opts.scope, group]) do
      {:ok, pid} ->
        state
        |> put_in_members(group, node, pid)
        |> Map.update!(:churn_events, &(&1 + 1))

      _error ->
        state
    end
  end

  defp do_leave(state, group, node, pid) do
    peer = state.cluster.peers[node]

    graceful? = :rand.uniform() < 0.5

    if graceful? do
      :peer.call(peer, MusterChaosPeerAux, :leave_member, [state.opts.scope, group, pid])
    else
      :peer.call(peer, MusterChaosPeerAux, :kill_member, [pid])
    end

    state
    |> delete_from_members(group, node, pid)
    |> Map.update!(:churn_events, &(&1 + 1))
  end

  defp chaos_action(state) do
    case Enum.random(state.opts.chaos_actions) do
      :disconnect -> chaos_disconnect(state)
      :reconnect -> chaos_reconnect(state)
      :crash_scope -> chaos_crash_scope(state)
      :crash_shard -> chaos_crash_shard(state)
    end
  end

  defp chaos_disconnect(state) do
    case connected_nodes(state) do
      # Keep at least one node connected so churn always has somewhere to land.
      [_] ->
        state

      [] ->
        state

      connected ->
        node = Enum.random(connected)
        others = state.cluster.all_nodes -- [node]
        peer = state.cluster.peers[node]
        :peer.call(peer, MusterChaosPeerAux, :disconnect_from, [others])

        state
        |> put_in([:node_status, node], :isolated)
        |> bump_chaos(:disconnect)
    end
  end

  defp chaos_reconnect(state) do
    case isolated_nodes(state) do
      [] ->
        state

      isolated ->
        node = Enum.random(isolated)
        targets = connected_nodes(state) -- [node]
        peer = state.cluster.peers[node]
        :peer.call(peer, MusterChaosPeerAux, :connect_to, [targets])

        state
        |> put_in([Access.key!(:node_status), node], :connected)
        |> bump_chaos(:reconnect)
    end
  end

  # A node whose scope/shard supervisors get crashed faster than they can
  # finish restarting will exhaust Supervisor's default restart intensity (3
  # restarts / 5s) and die permanently -- its Forum.Supervisor is linked to a
  # plain, non-supervising owner process, so nothing brings it back. That's a
  # real operational failure mode, but it isn't what "crash scope/shard and
  # verify recovery" is asking for, so we cool down per-node crash targeting
  # to stay comfortably under that budget. `assert_convergence` still handles
  # a node that dies anyway (e.g. --crash-cooldown-ms 0) by excluding it from
  # the live-node oracle rather than hanging or crashing the whole run.
  defp chaos_crash_scope(state) do
    case eligible_crash_nodes(state) do
      [] ->
        state

      eligible ->
        node = Enum.random(eligible)
        peer = state.cluster.peers[node]
        :peer.call(peer, MusterChaosPeerAux, :crash_scope, [state.opts.scope])

        state
        |> mark_crashed(node)
        |> bump_chaos(:crash_scope)
    end
  end

  defp chaos_crash_shard(state) do
    case eligible_crash_nodes(state) do
      [] ->
        state

      eligible ->
        node = Enum.random(eligible)
        peer = state.cluster.peers[node]

        case :peer.call(peer, MusterChaosPeerAux, :shard_count, [state.opts.scope]) do
          count when is_integer(count) and count > 0 ->
            index = :rand.uniform(count) - 1
            :peer.call(peer, MusterChaosPeerAux, :crash_shard, [state.opts.scope, index])

            state
            |> mark_crashed(node)
            |> bump_chaos(:crash_shard)

          _ ->
            state
        end
    end
  end

  defp eligible_crash_nodes(state) do
    now = System.monotonic_time(:millisecond)
    cooldown = state.opts.crash_cooldown_ms

    Enum.filter(state.cluster.all_nodes, fn node ->
      case Map.get(state.crash_cooldowns, node) do
        nil -> true
        crashed_at -> now - crashed_at >= cooldown
      end
    end)
  end

  defp mark_crashed(state, node) do
    now = System.monotonic_time(:millisecond)
    put_in(state, [:crash_cooldowns, node], now)
  end

  defp bump_chaos(state, kind), do: update_in(state.chaos_events[kind], &(&1 + 1))

  ## Membership bookkeeping (the oracle)

  defp put_in_members(state, group, node, pid) do
    update_in(state.members, fn members ->
      Map.update(members, {group, node}, MapSet.new([pid]), &MapSet.put(&1, pid))
    end)
  end

  defp delete_from_members(state, group, node, pid) do
    update_in(state.members, fn members ->
      case Map.fetch(members, {group, node}) do
        {:ok, set} -> Map.put(members, {group, node}, MapSet.delete(set, pid))
        :error -> members
      end
    end)
  end

  defp members_for_group(state, group) do
    for {{^group, node}, set} <- state.members, pid <- MapSet.to_list(set), do: {node, pid}
  end

  defp count_members(state) do
    state.members |> Map.values() |> Enum.map(&MapSet.size/1) |> Enum.sum()
  end

  defp connected_nodes(state) do
    for {node, :connected} <- state.node_status, do: node
  end

  defp isolated_nodes(state) do
    for {node, :isolated} <- state.node_status, do: node
  end

  defp random_connected_node(state) do
    case connected_nodes(state) do
      [] -> nil
      connected -> Enum.random(connected)
    end
  end

  ## Settle & convergence

  defp heal_all_partitions(state) do
    Enum.reduce(isolated_nodes(state), state, fn node, state ->
      targets = state.cluster.all_nodes -- [node]
      peer = state.cluster.peers[node]
      :peer.call(peer, MusterChaosPeerAux, :connect_to, [targets])
      put_in(state.node_status[node], :connected)
    end)
  end

  # Returns {settled?, live_nodes, dead_nodes}. A node counts as permanently
  # dead once its dump has errored continuously for >= dead_node_grace_ms
  # (comfortably longer than a normal crash-recovery blip at our fast
  # cooldown/heartbeat defaults): its whole Forum.Supervisor tree is gone and
  # nothing will restart it, so it is excluded from the convergence check and
  # from the oracle rather than making this loop wait out the full
  # --settle-timeout for something that can never happen.
  defp await_settle(state) do
    deadline = System.monotonic_time(:millisecond) + state.opts.settle_timeout_ms

    IO.puts(
      "healed all partitions, waiting for convergence (up to #{div(state.opts.settle_timeout_ms, 1000)}s)..."
    )

    do_await_settle(state, deadline, nil, %{})
  end

  defp do_await_settle(state, deadline, prev_fingerprint, down_since) do
    now = System.monotonic_time(:millisecond)
    dumps = fetch_dumps(state)

    down_since =
      Enum.reduce(dumps, down_since, fn {node, d}, acc ->
        if is_map(d), do: Map.delete(acc, node), else: Map.put_new(acc, node, now)
      end)

    dead_nodes =
      for {node, since} <- down_since, now - since >= state.opts.dead_node_grace_ms, do: node

    live_nodes = Enum.sort(state.cluster.all_nodes -- dead_nodes)
    live_dumps = for {node, d} <- dumps, node in live_nodes, do: {node, d}

    ready? =
      live_nodes != [] and
        Enum.all?(live_dumps, fn {_node, d} -> match?(%{status: :ready}, d) end)

    views_agree? =
      live_dumps
      |> Enum.map(fn {_node, d} -> Enum.sort(dump_get(d, :ring_nodes, [])) end)
      |> Enum.all?(&(&1 == live_nodes))

    fingerprint =
      :erlang.phash2(Enum.map(live_dumps, fn {n, d} -> {n, dump_get(d, :occupancy, %{})} end))

    stable? = fingerprint == prev_fingerprint

    cond do
      ready? and views_agree? and stable? ->
        {true, live_nodes, Enum.sort(dead_nodes)}

      now >= deadline ->
        IO.puts("!! did not settle within --settle-timeout; last dumps:")
        Enum.each(dumps, fn {node, d} -> IO.puts("  #{inspect(node)}: #{inspect(d)}") end)
        {false, live_nodes, Enum.sort(dead_nodes)}

      true ->
        Process.sleep(200)
        do_await_settle(state, deadline, fingerprint, down_since)
    end
  end

  defp fetch_dumps(state) do
    for {node, peer} <- state.cluster.peers, into: %{} do
      {node, :peer.call(peer, MusterChaosPeerAux, :dump, [state.opts.scope])}
    end
  end

  # `await_settle/1` only confirms the occupancy MAP (:present rows, as folded
  # by :dump) stopped changing -- a vacated group already reads as absent from
  # that view as soon as it's tombstoned, well before `reap_tombstones/1`
  # physically deletes the row on its own separate `:sweep_tombstones` timer
  # (period == tombstone_window_ms, so worst case is ~2x that before a given
  # row is actually gone). This is a dedicated second wait, specifically for
  # sunset groups (`--sunset-fraction`), so a leak -- a tombstone that lingers
  # in the ETS table forever instead of being reaped -- shows up as an
  # explicit timeout here rather than silently passing because `--present`
  # checks alone can't see it.
  defp await_tombstone_reap(_state, false, _live_nodes), do: true
  defp await_tombstone_reap(_state, _settled?, []), do: true

  defp await_tombstone_reap(state, true, live_nodes) do
    if MapSet.size(state.sunset_groups) == 0 do
      true
    else
      timeout_ms = max(5_000, 3 * state.opts.tombstone_window_ms)

      IO.puts(
        "waiting up to #{Float.round(timeout_ms / 1000, 1)}s for the tombstone sweep to reap " <>
          "sunset groups' occupancy rows..."
      )

      deadline = System.monotonic_time(:millisecond) + timeout_ms
      do_await_tombstone_reap(state, live_nodes, deadline)
    end
  end

  defp do_await_tombstone_reap(state, live_nodes, deadline) do
    leftover = count_sunset_rows(state, live_nodes)

    cond do
      leftover == 0 ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        IO.puts(
          "!! #{leftover} occupancy row(s) for sunset groups were not reaped within the " <>
            "tombstone window -- consider raising --tombstone-window-ms if this is expected " <>
            "at the configured value, otherwise this looks like a leak"
        )

        false

      true ->
        Process.sleep(250)
        do_await_tombstone_reap(state, live_nodes, deadline)
    end
  end

  defp count_sunset_rows(state, live_nodes) do
    Enum.reduce(live_nodes, 0, fn node, acc ->
      peer = state.cluster.peers[node]
      rows = :peer.call(peer, MusterChaosPeerAux, :raw_occupancy, [state.opts.scope])

      acc +
        Enum.count(rows, fn {{group, _src}, _seq, _meta, _writer} ->
          group in state.sunset_groups
        end)
    end)
  end

  ## Oracle & assertions

  # `live_nodes` are the nodes whose Forum instance is still up per
  # `await_settle/1`. A node that died permanently (Supervisor restart budget
  # exhausted -- see the comment above `chaos_crash_scope/1`) has no live
  # Muster state left anywhere: its previously-tracked members are dropped
  # from the oracle entirely rather than expected to still be routed, exactly
  # as the surviving cluster itself would treat that departure.
  defp build_oracle(_state, []), do: {%{}, %{}, %{}, %{}}

  defp build_oracle(state, live_nodes) do
    alive_members =
      for {{group, node}, set} <- state.members,
          node in live_nodes,
          pid <- MapSet.to_list(set),
          alive_now?(state, node, pid),
          reduce: %{} do
        acc -> Map.update(acc, {group, node}, MapSet.new([pid]), &MapSet.put(&1, pid))
      end

    ring_name = :"oracle_ring_#{state.opts.seed}"
    {:ok, _} = ExHashRing.Ring.start_link(name: ring_name, replicas: 128, depth: 2)
    ExHashRing.Ring.set_nodes(ring_name, live_nodes)

    expected_router =
      Map.new(state.groups, fn group ->
        {:ok, node} = ExHashRing.Ring.find_node(ring_name, group)
        {group, node}
      end)

    expected_sources =
      Map.new(state.groups, fn group ->
        sources =
          for node <- live_nodes,
              MapSet.size(Map.get(alive_members, {group, node}, MapSet.new())) > 0,
              do: node

        {group, MapSet.new(sources)}
      end)

    expected_local =
      for {{group, node}, set} <- alive_members, into: %{}, do: {{group, node}, set}

    final_dumps =
      for node <- live_nodes, into: %{} do
        peer = state.cluster.peers[node]
        {node, :peer.call(peer, MusterChaosPeerAux, :dump, [state.opts.scope])}
      end

    {expected_router, expected_sources, expected_local, final_dumps}
  end

  defp alive_now?(state, node, pid) do
    peer = state.cluster.peers[node]
    :peer.call(peer, MusterChaosPeerAux, :alive?, [pid]) == true
  end

  # `dump` is normally the map returned by MusterChaosPeerAux.dump/1, but can
  # transiently be `{:error, {:exit, ...}}` if the coordinator was mid-restart
  # (e.g. right after a crash_scope) when we polled it.
  defp dump_get(dump, key, default) when is_map(dump), do: Map.get(dump, key, default)
  defp dump_get(_dump, _key, default), do: default

  defp assert_convergence(
         state,
         [],
         _expected_router,
         _expected_sources,
         _expected_local,
         _final_dumps
       ) do
    %{
      groups_checked: length(state.groups),
      failures: [{:no_live_nodes, nil, %{}}],
      per_node: [],
      sunset_total: MapSet.size(state.sunset_groups),
      sunset_verified: 0
    }
  end

  defp assert_convergence(
         state,
         live_nodes,
         expected_router,
         expected_sources,
         expected_local,
         final_dumps
       ) do
    scope = state.opts.scope

    raw_occupancy =
      for node <- live_nodes, into: %{} do
        peer = state.cluster.peers[node]
        {node, :peer.call(peer, MusterChaosPeerAux, :raw_occupancy, [scope])}
      end

    raw_entries =
      for node <- live_nodes, into: %{} do
        peer = state.cluster.peers[node]
        {node, :peer.call(peer, MusterChaosPeerAux, :raw_entries, [scope])}
      end

    query_node = List.first(live_nodes)
    query_peer = state.cluster.peers[query_node]

    failures =
      Enum.flat_map(state.groups, fn group ->
        expected_r = expected_router[group]
        expected_s = expected_sources[group]

        router_failure =
          case :peer.call(query_peer, MusterChaosPeerAux, :router, [scope, group]) do
            {:ok, ^expected_r} ->
              nil

            other ->
              {:router_mismatch, group,
               %{expected: expected_r, actual: other, queried_on: query_node}}
          end

        actual_sources =
          final_dumps
          |> Map.get(expected_r)
          |> dump_get(:occupancy, %{})
          |> Map.get(group, [])
          |> MapSet.new()

        occupancy_failure =
          if actual_sources == expected_s do
            nil
          else
            {:occupancy_mismatch, group,
             %{
               expected: MapSet.to_list(expected_s),
               actual: MapSet.to_list(actual_sources),
               router_node: expected_r
             }}
          end

        raw_present_sources =
          raw_occupancy[expected_r]
          |> Enum.filter(fn {{g, _src}, _seq, meta, _writer} ->
            g == group and meta == :present
          end)
          |> Enum.map(fn {{_g, src}, _seq, _meta, _writer} -> src end)
          |> MapSet.new()

        raw_occupancy_failure =
          if raw_present_sources == expected_s do
            nil
          else
            {:raw_occupancy_mismatch, group,
             %{
               expected: MapSet.to_list(expected_s),
               actual: MapSet.to_list(raw_present_sources),
               router_node: expected_r
             }}
          end

        entries_failures =
          for node <- live_nodes,
              expected_pids = Map.get(expected_local, {group, node}, MapSet.new()),
              actual_pids =
                raw_entries[node]
                |> Enum.filter(fn {{g, _pid}} -> g == group end)
                |> Enum.map(fn {{_g, pid}} -> pid end)
                |> MapSet.new(),
              expected_pids != actual_pids do
            {:local_entries_mismatch, group,
             %{
               node: node,
               expected: MapSet.to_list(expected_pids),
               actual: MapSet.to_list(actual_pids)
             }}
          end

        ([router_failure, occupancy_failure, raw_occupancy_failure] ++ entries_failures)
        |> Enum.reject(&is_nil/1)
      end)

    per_node =
      per_node_summary(state, live_nodes, expected_router, expected_local, raw_entries, failures)

    failed_groups = MapSet.new(failures, fn {_kind, group, _detail} -> group end)
    sunset_total = MapSet.size(state.sunset_groups)
    sunset_failed = MapSet.size(MapSet.intersection(state.sunset_groups, failed_groups))

    %{
      groups_checked: length(state.groups),
      failures: failures,
      per_node: per_node,
      sunset_total: sunset_total,
      sunset_verified: sunset_total - sunset_failed
    }
  end

  # One row per live node: how many local members and router-assignments it
  # was expected to end up with vs. what its own ETS tables actually show,
  # plus how many of the failures above landed on that specific node -- so a
  # glance at the table shows whether convergence genuinely happened
  # everywhere, not just in aggregate.
  defp per_node_summary(state, live_nodes, expected_router, expected_local, raw_entries, failures) do
    for node <- live_nodes do
      expected_local_count =
        expected_local
        |> Enum.filter(fn {{_group, n}, _set} -> n == node end)
        |> Enum.map(fn {_key, set} -> MapSet.size(set) end)
        |> Enum.sum()

      actual_local_count = length(raw_entries[node])
      router_for_groups = Enum.count(state.groups, &(expected_router[&1] == node))

      node_failures =
        Enum.filter(failures, fn {_kind, _group, detail} ->
          detail[:node] == node or detail[:router_node] == node or detail[:expected] == node
        end)

      %{
        node: node,
        expected_local_members: expected_local_count,
        actual_local_members: actual_local_count,
        router_for_groups: router_for_groups,
        mismatches: length(node_failures)
      }
    end
  end

  defp print_report(report, settled?, dead_nodes, reaped?) do
    IO.puts("")
    IO.puts("== per-node summary ==")
    print_per_node_table(report.per_node)

    IO.puts("")
    IO.puts("== result ==")
    IO.puts("groups checked: #{report.groups_checked}")
    IO.puts("settled before assertions: #{settled?}")
    IO.puts("permanently dead nodes: #{length(dead_nodes)} #{inspect(dead_nodes)}")

    IO.puts(
      "sunset groups confirmed vacant (0 present occupancy rows, 0 local members): " <>
        "#{report.sunset_verified}/#{report.sunset_total}"
    )

    IO.puts(
      "sunset groups' tombstones fully reaped (0 ETS rows at all, present or not): #{reaped?}"
    )

    IO.puts("failures: #{length(report.failures)}")

    report.failures
    |> Enum.take(25)
    |> Enum.each(fn {kind, group, detail} ->
      IO.puts("  [#{kind}] #{inspect(group)}: #{inspect(detail)}")
    end)

    if length(report.failures) > 25 do
      IO.puts("  ... and #{length(report.failures) - 25} more")
    end

    if settled? and reaped? and report.failures == [] do
      IO.puts("PASS")
    else
      IO.puts("FAIL")
    end
  end

  defp print_per_node_table([]), do: IO.puts("  (no live nodes)")

  defp print_per_node_table(per_node) do
    header = ["node", "local members (expected/actual)", "router-for groups", "mismatches"]

    rows =
      Enum.map(per_node, fn row ->
        status = if row.mismatches == 0, do: "0", else: "#{row.mismatches} !!"

        [
          to_string(row.node),
          "#{row.expected_local_members}/#{row.actual_local_members}",
          to_string(row.router_for_groups),
          status
        ]
      end)

    widths =
      [header | rows]
      |> Enum.zip()
      |> Enum.map(fn col ->
        col |> Tuple.to_list() |> Enum.map(&String.length/1) |> Enum.max()
      end)

    format_row = fn cells ->
      cells
      |> Enum.zip(widths)
      |> Enum.map_join("  ", fn {cell, w} -> String.pad_trailing(cell, w) end)
    end

    IO.puts("  " <> format_row.(header))
    Enum.each(rows, fn row -> IO.puts("  " <> format_row.(row)) end)

    total_expected = Enum.sum(Enum.map(per_node, & &1.expected_local_members))
    total_actual = Enum.sum(Enum.map(per_node, & &1.actual_local_members))
    IO.puts("  total local members (expected/actual): #{total_expected}/#{total_actual}")
  end

  ## Small helpers

  defp wait_until(timeout_ms, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(deadline, fun)
  end

  defp do_wait_until(deadline, fun) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(100)
        do_wait_until(deadline, fun)
    end
  end
end

