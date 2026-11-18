defmodule Realtime.Presence.Comparison.Sweep do
  @moduledoc """
  One sweep of the comparison: compares the tenants of this node that are in the shadow mode.

  A sweep lists the scopes of the Rollcall instance and keeps the tenants in the shadow mode. It
  keeps the tenants of one sampling group. It runs `Realtime.Presence.Comparison.run/2` for each of
  them in its own task, and emits the events of each result with
  `Realtime.Presence.Comparison.emit/3`. A sweep keeps no state for the next sweep.
  """
  alias Realtime.FeatureFlags
  alias Realtime.Presence
  alias Realtime.Presence.Comparison

  @flag "presence_comparison"
  @event [:realtime, :presence, :compare]
  @default_timeout 30_000
  @default_groups 8
  @default_concurrency 32

  @doc """
  Runs sweep number `sweep_number` and returns `:ok` when every tenant task has ended.

  The sweep does nothing, and emits no event, when the global feature flag `presence_comparison` is
  off. The flag is off when it does not exist.

  The tenant is in the sampling group `sweep_number` when `:erlang.phash2(tenant, groups)` is
  equal to `rem(sweep_number, groups)`. `groups` consecutive sweeps cover every tenant once.

  A tenant task that crashes or exceeds `timeout` ends with no event. The other tenants are not
  affected. The sweep then emits `[:realtime, :presence, :compare, :sweep]` once, with the
  measurements `tenants_listed` (the scopes of the instance), `tenants_compared` (the tenant tasks
  that returned a result) and `duration` (native time units). The event has no metadata.

  Options:

    * `:rollcall` - the name of the Rollcall instance. The default is `Realtime.Presence.Rollcall`.
    * `:groups` - the number of sampling groups. The default is 8: a sweep covers one eighth of the
      tenants. Set 1 to cover every tenant in every sweep.
    * `:concurrency` - the number of tenant tasks that run at the same time. The default is 32.
      A tenant task sleeps between the rungs and holds its place, so a low number makes a long sweep.
    * `:timeout` - the time in milliseconds that a tenant task can run. The default is 30 000. It
      must exceed the last rung.
    * `:phoenix` and `:sleep` - passed to `Realtime.Presence.Comparison.run/2`.
  """
  @spec run(non_neg_integer(), Keyword.t()) :: :ok
  def run(sweep_number, opts \\ []) do
    if FeatureFlags.enabled?(@flag), do: compare_tenants(sweep_number, opts), else: :ok
  end

  defp compare_tenants(sweep_number, opts) do
    rollcall = Keyword.get(opts, :rollcall, Realtime.Presence.Rollcall)
    groups = Keyword.get(opts, :groups, @default_groups)
    concurrency = Keyword.get(opts, :concurrency, @default_concurrency)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    run_opts =
      opts
      |> Keyword.take([:phoenix, :sleep])
      |> Keyword.put(:rollcall, rollcall)

    started_at = System.monotonic_time()
    listed = Rollcall.scopes(rollcall)

    compared =
      listed
      |> Enum.filter(&(Presence.mode(&1) == :shadow and :erlang.phash2(&1, groups) == rem(sweep_number, groups)))
      |> compare_all(run_opts, concurrency, timeout)

    :telemetry.execute(
      @event ++ [:sweep],
      %{
        tenants_listed: length(listed),
        tenants_compared: compared,
        duration: System.monotonic_time() - started_at
      },
      %{}
    )
  end

  # Returns the number of tenant tasks that returned a result.
  defp compare_all(tenants, run_opts, concurrency, timeout) do
    Realtime.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(tenants, &compare(&1, run_opts),
      max_concurrency: concurrency,
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.count(&match?({:ok, _}, &1))
  end

  defp compare(tenant, run_opts) do
    {duration, result} = :timer.tc(fn -> Comparison.run(tenant, run_opts) end, :native)

    Comparison.emit(tenant, result, duration)
  end
end
