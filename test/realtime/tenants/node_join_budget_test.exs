defmodule Realtime.Tenants.NodeJoinBudgetTest do
  use ExUnit.Case, async: true

  import Generators

  alias Realtime.Api.Tenant
  alias Realtime.Tenants.NodeJoinBudget
  alias Realtime.UsersCounter

  @second 1_000_000

  setup do
    # Far enough in the future that the periodic sweep never sees these buckets as full mid-test
    %{tenant: %Tenant{external_id: random_string()}, now: System.monotonic_time(:microsecond) + 3_600 * @second}
  end

  # config/test.exs makes the budget max(10, 2 * sockets) joins per second and the burst 2 seconds. A full bucket holds
  # the burst, so the joins it allows at once are twice the budget.
  describe "budget" do
    test "is the configured floor while the tenant has no sockets on this node", %{tenant: tenant, now: now} do
      assert joins_at_once(tenant, now) == 20
    end

    test "stays at the floor while the sockets' joins per second are below it", %{tenant: tenant, now: now} do
      add_sockets(tenant, 3)

      assert joins_at_once(tenant, now) == 20
    end

    test "grows by the configured joins per socket once above the floor", %{tenant: tenant, now: now} do
      add_sockets(tenant, 8)

      assert joins_at_once(tenant, now) == 32
    end
  end

  describe "take/2" do
    test "allows the whole burst at once and then refuses", %{tenant: tenant, now: now} do
      for _ <- 1..20, do: assert(NodeJoinBudget.take(tenant, now) == :ok)

      assert NodeJoinBudget.take(tenant, now) == :error
    end

    test "refills at the budget rate", %{tenant: tenant, now: now} do
      for _ <- 1..20, do: NodeJoinBudget.take(tenant, now)

      assert NodeJoinBudget.take(tenant, now + div(@second, 10) - 1) == :error
      assert NodeJoinBudget.take(tenant, now + div(@second, 10)) == :ok
      assert NodeJoinBudget.take(tenant, now + div(@second, 10)) == :error

      for _ <- 1..20, do: assert(NodeJoinBudget.take(tenant, now + 3 * @second) == :ok)
      assert NodeJoinBudget.take(tenant, now + 3 * @second) == :error
    end

    test "holds a tenant joining faster than its budget to the budget once the burst is used up", %{
      tenant: tenant,
      now: now
    } do
      # 20 joins per second against a budget of 10: every join fits until the 2 second burst runs dry just before 2
      # seconds in, and from then on only the budget does
      allowed_per_second =
        for second <- 0..5 do
          Enum.count(0..19, fn i ->
            NodeJoinBudget.take(tenant, now + second * @second + div(i * @second, 20)) == :ok
          end)
        end

      assert allowed_per_second == [20, 19, 10, 10, 10, 10]
    end

    test "refills faster once the tenant has more sockets on this node", %{tenant: tenant, now: now} do
      for _ <- 1..20, do: NodeJoinBudget.take(tenant, now)
      assert NodeJoinBudget.take(tenant, now + div(@second, 20)) == :error

      # 15 sockets at 2 joins per socket make the budget 30 per second
      add_sockets(tenant, 15)

      assert NodeJoinBudget.take(tenant, now + div(@second, 20)) == :ok
    end

    # A burst of a fixed number of joins would hold fewer seconds once the budget grows, so the sockets a reconnect
    # storm brings would shrink what is left of the burst instead of refilling it faster
    test "keeps the bucket as full when the budget grows", %{tenant: tenant, now: now} do
      for _ <- 1..20, do: NodeJoinBudget.take(tenant, now)

      # Half refilled one second later, and 20 sockets at 2 joins per socket make the budget 40 per second, so half of
      # the 80 joins the bucket now holds
      add_sockets(tenant, 20)

      assert joins_at_once(tenant, now + @second) == 40
    end

    test "keeps a separate budget per tenant", %{tenant: tenant, now: now} do
      other = %{tenant | external_id: random_string()}

      assert joins_at_once(tenant, now) == 20
      assert NodeJoinBudget.take(tenant, now) == :error
      assert NodeJoinBudget.take(other, now) == :ok
    end

    test "never hands out more than the budget to concurrent joins", %{tenant: tenant, now: now} do
      results =
        1..500
        |> Task.async_stream(fn _ -> NodeJoinBudget.take(tenant, now) end, max_concurrency: 100)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &(&1 == :ok)) == 20
    end
  end

  describe "sweep" do
    test "deletes buckets that have been full for a second and keeps the others", %{tenant: tenant, now: future} do
      refilling = tenant
      just_full = %{tenant | external_id: random_string()}
      full = %{tenant | external_id: random_string()}
      real_now = System.monotonic_time(:microsecond)
      interval = div(@second, 10)

      # A take leaves the bucket full again one interval later
      NodeJoinBudget.take(refilling, future)
      NodeJoinBudget.take(just_full, real_now - div(@second, 2) - interval)
      NodeJoinBudget.take(full, real_now - 10 * @second)

      sweep()

      assert :ets.member(NodeJoinBudget, refilling.external_id)
      assert :ets.member(NodeJoinBudget, just_full.external_id)
      refute :ets.member(NodeJoinBudget, full.external_id)

      # A deleted bucket is a full one
      assert joins_at_once(full, System.monotonic_time(:microsecond)) == 20
    end
  end

  defp joins_at_once(tenant, now) do
    Stream.repeatedly(fn -> NodeJoinBudget.take(tenant, now) end)
    |> Enum.take_while(&(&1 == :ok))
    |> length()
  end

  defp add_sockets(tenant, count) do
    for _ <- 1..count, do: UsersCounter.add(spawn_link(fn -> Process.sleep(:infinity) end), tenant.external_id)
  end

  defp sweep do
    send(NodeJoinBudget, :sweep)
    # The process handles messages in order, so the sweep is done once it answers this
    :sys.get_state(NodeJoinBudget)
  end
end
