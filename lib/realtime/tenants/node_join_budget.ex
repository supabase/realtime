defmodule Realtime.Tenants.NodeJoinBudget do
  @moduledoc """
  Limits how many channel joins per second a tenant gets on this node.

  ## Budget

  The budget is `max(NODE_JOIN_BUDGET_FLOOR, CLIENT_JOINS_PER_SECOND * clients)` joins per second. A client is one
  WebSocket connection, and `clients` is the number of the tenant's clients on this node. With the defaults (a floor
  of 10 and 1 join per second for each client):

    * 5 clients get 10 joins per second (the floor)
    * 50 clients get 50 joins per second
    * 1,000 clients get 1,000 joins per second

  `Realtime.UsersCounter` counts a client from its first successful join until it disconnects. Clients that stay
  connected raise the budget. Clients that connect, join and disconnect again and again add almost nothing, so they
  mostly get the floor.

  ## Burst

  Each tenant has a bucket of joins on this node. Each join takes one join from the bucket. The bucket refills at the
  budget rate and holds `NODE_JOIN_BUDGET_BURST_SECONDS` (default 60) seconds of budget.

  A tenant with no clients on this node can make 600 joins at once (10 * 60). After that, it gets 10 joins per second.

  A tenant that keeps rejoining empties the bucket. For example, a tenant with few clients makes 20 joins per second
  against a budget of 10. The bucket loses 10 joins each second, so it is empty after 60 seconds. From then on, 10 of
  its 20 joins each second are over budget.

  The burst sets how long a tenant can join faster than its budget. The budget sets how fast it can join after that.
  Nothing is counted across the cluster, because each node keeps its own buckets.

  ## How the bucket works

  The bucket uses GCRA (generic cell rate algorithm), a token bucket kept as one timestamp. It does not keep a count
  of the joins left.

  Each join costs one interval of time. The interval is `1 / budget` seconds, so 100 ms at a budget of 10. The bucket
  keeps one timestamp, `full_at`. If no more joins come, the bucket is full again at `full_at`. Each join moves
  `full_at` one interval later, and the time that passes refills the bucket. If a join moves `full_at` more than the
  burst past now, the join is over budget.

  For example, at a budget of 10 and a burst of 60 seconds:

    1. A new bucket is full, so its `full_at` is now.
    2. 600 joins at once move `full_at` to now + 60 seconds.
    3. Join 601 moves `full_at` past now + 60 seconds, so it is over budget.
    4. One second later, `full_at` is only 59 seconds ahead, so 10 more joins fit.

  While `full_at` is ahead of now, the joins left are `(burst_seconds - (full_at - now)) / interval`.

  The buckets are in a public ETS table, so channel processes take joins with one atomic update and do not call this
  process.

  ## Budget changes

  The bucket size is a number of seconds, not a number of joins. Each take reads the current budget, so the interval
  follows the client count. When the budget changes, the used seconds (`full_at - now`) stay the same. Each free
  second then holds a different number of joins.

  For example, a half-full bucket at 10 joins per second has 30 seconds left, which is 300 joins. The clients of a
  reconnect storm raise the budget to 300 joins per second. The bucket still has 30 seconds left, which is now 9,000
  joins. So the rest of the storm gets more room.

  The reverse is also true. When clients leave and the budget falls, each free second holds fewer joins.

  ## Cleanup

  A full bucket acts the same as a missing one. Once a minute, this process deletes the full buckets, so the table
  holds only the tenants that joined recently.
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
    burst_seconds = Application.fetch_env!(:realtime, :node_join_budget_burst_seconds)

    take(tenant_id, interval, (budget * burst_seconds - 1) * interval, now)
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
