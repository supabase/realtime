defmodule Realtime.Tenants.NodeJoinBudget do
  @moduledoc """
  Limits how many channel joins per second a tenant gets on this node.

  The budget is `max(floor, per_socket * local_sockets)` joins per second, where `floor` is
  `NODE_JOIN_BUDGET_FLOOR`, `per_socket` is the joins per second each socket is allowed (`CLIENT_JOINS_PER_SECOND`)
  and `local_sockets` is the tenant's sockets on this node as counted by Census. Census only counts a socket after its first
  successful join, so sockets that stay connected raise the budget, while sockets that churn (connect,
  join, disconnect, repeat) barely show up and mostly run into the floor.

  Each tenant has a token bucket that refills at the budget and holds one second of it, so a tenant can
  make `floor` joins at once on each node. Nothing is counted across the cluster.

  A bucket is the time at which it is full again (the GCRA form of a token bucket), kept in a public ETS
  table so channel processes take tokens directly. Each take reads the current budget, so the refill rate
  follows the socket count. A full bucket behaves exactly like a missing one, so this process
  periodically deletes full buckets to keep the table to the tenants that are joining right now.
  """

  use GenServer

  alias Realtime.Api.Tenant
  alias Realtime.UsersCounter

  @table __MODULE__
  @microseconds_per_second 1_000_000
  @sweep_interval :timer.minutes(1)
  @sweep_grace @microseconds_per_second

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Takes a join from the tenant's budget on this node, or returns `:error` when it is used up."
  @spec take(Tenant.t(), integer()) :: :ok | :error
  def take(%Tenant{external_id: tenant_id}, now \\ now()) do
    budget = budget(tenant_id)
    interval = div(@microseconds_per_second, budget)

    take(tenant_id, interval, (budget - 1) * interval, now)
  end

  # Joins per second the tenant can make on this node right now
  defp budget(tenant_id) do
    floor = Application.fetch_env!(:realtime, :node_join_budget_floor)
    per_socket = Application.fetch_env!(:realtime, :client_join_rate_limit)[:per_second]

    max(floor, per_socket * UsersCounter.tenant_users(tenant_id, node()))
  end

  defp take(tenant_id, interval, tolerance, now) do
    case :ets.lookup(@table, tenant_id) do
      [{^tenant_id, full_at}] when full_at - now > tolerance ->
        :error

      _ ->
        # One atomic update to full_at = max(full_at, now) + interval, so concurrent takes never retry: the first
        # op raises full_at to now - 1 when it is below that, the second adds the interval and the 1 back.
        # A missing bucket starts at now, as it is full.
        [_, full_at] =
          :ets.update_counter(@table, tenant_id, [{2, -1, now - 1, now - 1}, {2, interval + 1}], {tenant_id, now})

        if full_at - interval - now <= tolerance do
          :ok
        else
          # Other takes emptied the bucket since the lookup, so give the token back
          :ets.update_counter(@table, tenant_id, {2, -interval}, {tenant_id, now})
          :error
        end
    end
  end

  defp now, do: System.monotonic_time(:microsecond)

  @impl true
  def init(nil) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true, write_concurrency: :auto])
    schedule_sweep()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    delete_full_buckets()
    schedule_sweep()
    {:noreply, state}
  end

  # Nothing is lost because a missing bucket is a full one, and a bucket a join takes from while this runs is no
  # longer full, so it is kept. Buckets that only just became full are kept too: a take that gives its token back
  # after this deleted the bucket recreates it, and waiting a second means that only happens if the take stalled
  # for over two seconds.
  defp delete_full_buckets do
    full_since = now() - @sweep_grace
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:"=<", :"$1", full_since}], [true]}])
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)
end
