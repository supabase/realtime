# The code that runs on each measured node. The coordinator in dev/bench/presence.exs loads this
# file on every node and calls it with RPC.

defmodule PresenceBench.Node do
  @moduledoc false

  alias Realtime.Presence

  @rollcall Realtime.Presence.Rollcall
  @clients PresenceBench.Node.Clients
  @cpu_meter PresenceBench.Node.CpuMeter

  # Registers a listener for each tenant, as a connected client does, then makes sure the Rollcall
  # tracker runs. Rollcall sends its heartbeats only to the nodes that joined the Muster group of
  # the tenant, so a node with no listener receives no peer entry. The channel makes the same two
  # calls when a client joins.
  def watch(tenants) do
    listener = spawn(fn -> Process.sleep(:infinity) end)
    scope = Application.get_env(:realtime, :muster_scope)

    for tenant <- tenants do
      :ok = Realtime.UsersCounter.add(listener, tenant)
      :ok = Forum.Muster.join(scope, tenant, listener)
      :ok = Presence.watch(tenant)
    end

    :ok
  end

  # Starts one process for each client and waits until every client has tracked its entry.
  # `specs` is a list of `{tenant, sub_topic, first_index, count}`. A client key is its index, so the
  # keys of one topic are unique across nodes when the index ranges do not overlap.
  def join(specs, meta_bytes) do
    {:ok, _} = Agent.start(fn -> [] end, name: @clients)

    parent = self()
    ref = make_ref()
    pad = :binary.copy("x", meta_bytes)

    pids =
      for {tenant, sub_topic, from, count} <- specs, i <- from..(from + count - 1)//1 do
        topic = Realtime.Tenants.tenant_topic(tenant, sub_topic)
        client = %{tenant: tenant, topic: topic, key: "k#{i}", meta: %{"pad" => pad}, updates: 0}
        spawn(fn -> start_client(parent, ref, client) end)
      end

    for _ <- pids do
      receive do
        {^ref, {:ok, _, _}} -> :ok
        {^ref, error} -> raise "track failed: #{inspect(error)}"
      after
        120_000 -> raise "a client did not track within 120 s"
      end
    end

    Agent.update(@clients, &(pids ++ &1))
    length(pids)
  end

  # Makes `per_s` changes each second for `duration_ms`. A change picks a client of this node at
  # random. The client either updates its entry, or removes the entry and adds it back at once. The
  # number of tracked entries stays the same. Returns the number of changes sent to the clients. A
  # client makes its change after it receives the message.
  def make_changes(duration_ms, per_s) do
    pids = @clients |> Agent.get(& &1) |> List.to_tuple()
    deadline = System.monotonic_time(:millisecond) + duration_ms
    tick_ms = 100

    change_loop(pids, deadline, tick_ms, per_s * tick_ms / 1000, 0.0, 0)
  end

  # The entries that this node holds for the backend, its own and its peers'. A cheap read with no
  # GC, for the coordinator to poll while it waits for the replication to finish.
  def entries(:phoenix) do
    [{:pool_size, size}] = :ets.lookup(RealtimeWeb.Presence, :pool_size)

    Enum.sum(
      for n <- 0..(size - 1),
          do: :ets.info(Phoenix.Tracker.Shard.name_for_number(RealtimeWeb.Presence, n), :size)
    )
  end

  def entries(:rollcall), do: Enum.sum(for p <- rollcall_procs(), do: :ets.info(hd(p.tables), :size))

  # One reading of the reductions and the memory of every process of both backends, and of the
  # scheduler wall time of the node. The memory is the process memory plus the ETS tables of the
  # process, read after a GC so the heap is not at a growth step. A GC costs reductions and CPU
  # time, so it must fall outside the window. At the start of a window, the GC runs before the
  # reductions and the scheduler time are read. At the end, they are read before the GC.
  #
  # The scheduler wall time covers the whole node, not only the measured processes. It includes the
  # clients of the benchmark.
  #
  # With `scoped_cpu?`, the window also measures the CPU time of the measured processes alone. See
  # `start_cpu_trace/1`.
  def snapshot(mode, scoped_cpu? \\ false)

  def snapshot(:start, scoped_cpu?) do
    hold_scheduler_wall_time()
    procs = phoenix_procs() ++ rollcall_procs()
    gc(procs)
    if scoped_cpu?, do: start_cpu_trace(procs)

    %{processes: read(procs), schedulers: schedulers()}
  end

  def snapshot(:end, scoped_cpu?) do
    procs = phoenix_procs() ++ rollcall_procs()
    scoped_cpu = if scoped_cpu?, do: stop_cpu_trace(procs)
    reductions = Map.new(procs, &{&1.pid, reductions(&1.pid)})
    schedulers = schedulers()
    gc(procs)

    %{
      processes: for(reading <- read(procs), do: %{reading | reductions: Map.fetch!(reductions, reading.pid)}),
      schedulers: schedulers,
      scoped_cpu: scoped_cpu
    }
  end

  # The CPU time of the measured processes alone, without the clients and the rest of the node.
  #
  # The VM traces when each process starts and stops to run. A tracer process adds up the time from
  # each "in" to the next "out". That time is the time that the process held a scheduler: its own
  # code, the BIFs that it called and its garbage collections. Each node runs one scheduler per
  # share of the cores, so the process does not wait for another process that runs on the scheduler
  # in that span.
  #
  # The tracing adds work to the node: one message for each time that a process starts or stops.
  # The tracer runs on the node, so the CPU seconds of the node include it. They are not comparable
  # with the CPU seconds of a run without the option.
  @cpu_tracer PresenceBench.Node.CpuTracer

  defp start_cpu_trace(procs) do
    if old = Process.whereis(@cpu_tracer), do: Process.exit(old, :kill)

    tracer = spawn(fn -> cpu_tracer(%{}, 0, nil) end)
    Process.register(tracer, @cpu_tracer)
    pids = Enum.map(procs, & &1.pid)
    started = System.monotonic_time()

    traced =
      for pid <- pids, traced?(pid, tracer) do
        pid
      end

    :persistent_term.put({__MODULE__, :cpu_trace}, {traced, started})
  end

  # A process can exit between the listing and the trace call.
  defp traced?(pid, tracer) do
    :erlang.trace(pid, true, [:running_procs, :monotonic_timestamp, {:tracer, tracer}])
    true
  rescue
    ArgumentError -> false
  end

  # The result is nil when a measured process started after the start of the window, because the
  # trace never saw it. This is the case for the Rollcall trackers in the join window, which starts
  # them.
  defp stop_cpu_trace(procs_at_end) do
    {pids, started} = :persistent_term.get({__MODULE__, :cpu_trace})
    ended = System.monotonic_time()
    complete? = MapSet.subset?(MapSet.new(procs_at_end, & &1.pid), MapSet.new(pids))

    for pid <- pids do
      try do
        :erlang.trace(pid, false, [:all])
      rescue
        ArgumentError -> :ok
      end
    end

    ref = make_ref()
    send(@cpu_tracer, {:stop, self(), ref})

    receive do
      {^ref, _busy} when not complete? ->
        nil

      {^ref, busy} ->
        %{
          busy_ns: System.convert_time_unit(busy, :native, :nanosecond),
          wall_ns: System.convert_time_unit(ended - started, :native, :nanosecond)
        }
    after
      30_000 -> raise "the CPU tracer did not answer"
    end
  end

  # `running` holds when each traced process started to run. `busy` is the total time that the
  # processes ran. After the stop, the tracer waits until the VM delivered every trace message.
  defp cpu_tracer(running, busy, waiting) do
    receive do
      {:trace_ts, pid, :in, _mfa, ts} ->
        cpu_tracer(Map.put(running, pid, ts), busy, waiting)

      {:trace_ts, pid, :out, _mfa, ts} ->
        case Map.pop(running, pid) do
          {nil, running} -> cpu_tracer(running, busy, waiting)
          {since, running} -> cpu_tracer(running, busy + ts - since, waiting)
        end

      {:stop, from, ref} ->
        cpu_tracer(running, busy, {from, ref, :erlang.trace_delivered(:all)})

      {:trace_delivered, _tracee, delivered} ->
        {from, ref, ^delivered} = waiting
        send(from, {ref, busy})

      _other ->
        cpu_tracer(running, busy, waiting)
    end
  end

  # The scheduler wall time flag belongs to the process that sets it. The flag clears when that
  # process exits. An RPC call runs in a process that exits at the end of the call, so a process
  # that lives on holds the flag. The agent starts once on each node and sets the flag in its init.
  defp hold_scheduler_wall_time do
    case Agent.start(fn -> :erlang.system_flag(:scheduler_wall_time, true) end, name: @cpu_meter) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  # The `{id, active_time, total_time}` of each scheduler. The times grow from the moment that the
  # flag is set.
  defp schedulers, do: :scheduler_wall_time |> :erlang.statistics() |> Enum.sort()

  defp gc(procs), do: Enum.each(procs, &:erlang.garbage_collect(&1.pid))

  defp read(procs) do
    word = :erlang.system_info(:wordsize)

    for %{backend: backend, pid: pid, tables: tables} <- procs do
      %{
        backend: backend,
        pid: pid,
        reductions: reductions(pid),
        memory_bytes: memory(pid) + Enum.sum(for t <- tables, do: :ets.info(t, :memory)) * word
      }
    end
  end

  defp start_client(parent, ref, client) do
    send(parent, {ref, track(client)})
    client_loop(client)
  end

  defp client_loop(client) do
    receive do
      :update -> client |> update() |> client_loop()
      :rejoin -> client |> rejoin() |> client_loop()
    end
  end

  defp track(c), do: Presence.track(self(), c.tenant, c.topic, c.key, c.meta)

  defp update(c) do
    c = %{c | updates: c.updates + 1, meta: Map.put(c.meta, "updates", c.updates + 1)}
    {:ok, _, _} = track(c)
    c
  end

  defp rejoin(c) do
    :ok = Presence.untrack(self(), c.tenant, c.topic, c.key)
    {:ok, _, _} = track(c)
    c
  end

  # `per_tick` can be a fraction. The loop carries the remainder to the next tick.
  defp change_loop({}, _deadline, _tick_ms, _per_tick, _carry, sent), do: sent

  defp change_loop(pids, deadline, tick_ms, per_tick, carry, sent) do
    if System.monotonic_time(:millisecond) < deadline do
      due = carry + per_tick
      count = trunc(due)

      for _ <- 1..count//1 do
        send(elem(pids, :rand.uniform(tuple_size(pids)) - 1), Enum.random([:update, :rejoin]))
      end

      Process.sleep(tick_ms)
      change_loop(pids, deadline, tick_ms, per_tick, due - count, sent + count)
    else
      sent
    end
  end

  # A Phoenix shard keeps its entries in a table named after the shard and its pids in a table named
  # `:pids` that has no registered name. Only the owner and the name find it.
  defp phoenix_procs do
    [{:pool_size, size}] = :ets.lookup(RealtimeWeb.Presence, :pool_size)
    all = :ets.all()

    for n <- 0..(size - 1) do
      name = Phoenix.Tracker.Shard.name_for_number(RealtimeWeb.Presence, n)
      pid = Process.whereis(name)
      pids = Enum.find(all, &(:ets.info(&1, :owner) == pid and :ets.info(&1, :name) == :pids))

      %{backend: :phoenix, name: name, pid: pid, tables: [name, pids]}
    end
  end

  # The Rollcall Registry holds the view table of each tracker as the value of its entry. The value
  # is `nil` until the tracker has made its view.
  defp rollcall_procs do
    for {scope, pid, view} <- Registry.select(@rollcall, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}]),
        view != nil,
        Process.alive?(pid) do
      %{backend: :rollcall, name: scope, pid: pid, tables: [view]}
    end
  end

  defp reductions(pid), do: pid |> Process.info(:reductions) |> elem(1)
  defp memory(pid), do: pid |> Process.info(:memory) |> elem(1)
end
