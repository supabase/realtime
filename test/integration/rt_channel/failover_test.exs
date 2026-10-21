defmodule Realtime.Integration.RtChannel.FailoverTest do
  @moduledoc """
  What a client sees when the database primary changes under a running tenant.

  Needs a dedicated three-cell Multigres cluster (a failover would break whatever else shared the
  database), reached through FAILOVER_TENANT_DB_PORT, with the gateway failover buffer on. See
  `.github/workflows/failover_tests.yml` for how CI starts one, or:

      export COMPOSE_PROJECT_NAME=tenant-db-failover TENANT_DB_PORT=5440 MULTIGRES_NUM_CELLS=3 \\
        MT_BUFFER_ENABLED=true MT_BUFFER_MIN_TIME_BETWEEN_FAILOVERS=1s
      docker compose -f compose.tenant-db.yml up -d --wait
      docker compose -f compose.tenant-db.yml run --rm tenant_db_bootstrap
      FAILOVER_TENANT_DB_PORT=5440 USE_EXTERNAL_TENANT_DB=true EXTERNAL_TENANT_DB_PORTS=5440 \\
        mix test test/integration/rt_channel/failover_test.exs --only failover:planned

  An unplanned failover leaves the killed cell down, so each scenario needs a fresh cluster.

  A writer inserts a numbered row every 250 ms into a table watched by Postgres Changes and into one whose
  trigger broadcasts the change (Broadcast from Database). The tests do not require every event to arrive: with
  temporary replication slots, events written around the failover can be lost. What must hold is that both
  streams recover within a bound, deliver no duplicates and catch up to the latest writes. After a planned
  switchover, a channel joining Postgres Changes during it must also subscribe.
  """

  use RealtimeWeb.ConnCase, async: false

  alias Phoenix.Socket.Message
  alias Realtime.Database
  alias Realtime.Integration.WebsocketClient
  alias Realtime.Tenants.Connect
  alias Realtime.Tenants.ReplicationConnection

  @moduletag :requires_failover_cluster
  @moduletag :capture_log
  @moduletag timeout: 300_000

  @serializer RealtimeWeb.Socket.V2Serializer
  @interval_ms 250
  @warmup_ms 6_000
  @after_ms 45_000
  # Realtime's reconnect backoff is a random 5 to 15s, on top of the failover itself.
  @max_gap_ms 40_000
  @late_join_after_ms 2_000
  @late_join_timeout_ms 30_000
  @min_events_before_trigger 10
  @tail 5
  @pg_changes [%{event: "INSERT", schema: "public", table: "test"}]

  setup do
    port = "FAILOVER_TENANT_DB_PORT" |> System.fetch_env!() |> String.to_integer()
    container = System.get_env("FAILOVER_TENANT_DB_CONTAINER", "tenant-db-failover-tenant_db-1")

    tenant = TestTenantDb.checkout_tenant_on(port, run_migrations: true)
    {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
    assert Connect.ready?(tenant.external_id)
    {:ok, _} = setup_postgres_changes(db_conn)

    %{tenant: tenant, port: port, container: container}
  end

  @tag failover: :planned
  test "a planned switchover", %{tenant: tenant, port: port, container: container} do
    before = primary!(container)

    result =
      run_failover(tenant, port, fn ->
        args = ~w(multigres cluster switch-primary --database=postgres --yes --admin-server localhost:15070)
        {out, status} = docker(container, args ++ ["--reason=failover test"])
        assert status == 0, "switch-primary failed: #{out}"
      end)

    assert_recovered(result, require_late_join: true)
    assert wait_until(fn -> primary!(container) != before end, 30_000), "the primary did not change"
  end

  @tag failover: :unplanned
  test "the primary's postgres and pooler being killed", %{tenant: tenant, port: port, container: container} do
    {name, grpc} = primary!(container)

    result =
      run_failover(tenant, port, fn ->
        # The cell's pgctld and postgres carry its pooler directory, the multipooler its gRPC port. The bracketed
        # first letter keeps pgrep from matching the shell running it.
        kill = ~s|kill -9 $(pgrep -f "[p]ooler_#{name}") $(pgrep -f "[m]ultipooler.*--grpc-port #{grpc}")|
        {out, status} = docker(container, ["sh", "-c", kill])
        assert status == 0, "kill failed: #{out}"
      end)

    # A join that lands before the gateway has noticed the failure can get a retryable error, which Realtime
    # treats as fatal (see `subscription_insert_failed`), so the late join is not required here.
    assert_recovered(result, require_late_join: false)
  end

  # -- scenario

  # Runs `trigger` while the writer and the collectors are going, and returns what each saw.
  defp run_failover(tenant, port, trigger) do
    parent = self()
    topic = "failover_" <> String.downcase(random_string())
    setup_broadcast_changes(tenant, topic)
    {:ok, writer_conn} = start_writer_connection(port)

    collector = Task.async(fn -> collect(parent, tenant, topic) end)
    assert_receive :pg_subscribed, 15_000
    assert wait_until(fn -> ReplicationConnection.ready?(tenant.external_id) end, 15_000)

    writer = Task.async(fn -> write_loop(writer_conn, 1, %{pg: [], bdb: [], errors: 0}) end)
    Process.sleep(@warmup_ms)

    late = Task.async(fn -> late_join(tenant) end)
    triggered_at = now()
    trigger.()
    Process.sleep(@after_ms)

    send(writer.pid, :stop)
    written = Task.await(writer, 30_000)
    # Lets the last events arrive.
    Process.sleep(3_000)
    send(collector.pid, :stop)
    seen = Task.await(collector, 10_000)
    late_result = Task.await(late, @late_join_timeout_ms + 10_000)

    %{written: written, seen: seen, late: late_result, triggered_at: triggered_at}
  end

  defp assert_recovered(%{written: written, seen: seen, late: late, triggered_at: triggered_at}, opts) do
    for {stream, label} <- [pg: "Postgres Changes", bdb: "Broadcast from Database"] do
      events = Enum.reverse(seen[stream])
      seqs = Enum.map(events, &elem(&1, 0))
      before_trigger = Enum.count(events, fn {_seq, at} -> at < triggered_at end)
      acked = Enum.reverse(written[stream])
      missing_tail = Enum.take(acked, -@tail) -- seqs

      assert before_trigger >= @min_events_before_trigger,
             "#{label}: only #{before_trigger} events arrived before the failover, the stream was not working"

      assert seqs == Enum.uniq(seqs), "#{label}: duplicate events"

      assert missing_tail == [],
             "#{label}: the last acknowledged writes #{inspect(missing_tail)} never arrived, so the stream did not recover"

      gap = max_gap(events)
      assert gap <= @max_gap_ms, "#{label}: silent for #{gap} ms, more than the #{@max_gap_ms} ms allowed"

      lost = length(acked -- seqs)
      IO.puts("[failover] #{label}: #{length(acked)} acknowledged, #{lost} lost, longest silence #{gap} ms")
    end

    IO.puts("[failover] write errors: #{written.errors}, late join: #{inspect(late)}")

    if opts[:require_late_join] do
      assert late == :subscribed,
             "a Postgres Changes channel joined during the failover did not subscribe: #{inspect(late)}"
    end
  end

  defp max_gap(events) do
    events
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> b - a end)
    |> Enum.max(fn -> 0 end)
  end

  # -- writer

  defp start_writer_connection(port) do
    Postgrex.start_link(
      hostname: "127.0.0.1",
      port: port,
      username: "supabase_admin",
      password: "postgres",
      database: "postgres",
      backoff_type: :rand_exp
    )
  end

  defp write_loop(conn, seq, acc) do
    receive do
      :stop ->
        acc
    after
      0 ->
        started = now()
        value = Integer.to_string(seq)

        acc =
          acc
          |> write(conn, :pg, "INSERT INTO public.test (details) VALUES ($1)", value, seq)
          |> write(conn, :bdb, "INSERT INTO public.failover_changes (details) VALUES ($1)", value, seq)

        Process.sleep(max(@interval_ms - (now() - started), 0))
        write_loop(conn, seq + 1, acc)
    end
  end

  defp write(acc, conn, stream, sql, value, seq) do
    case Postgrex.query(conn, sql, [value], timeout: 10_000) do
      {:ok, _} -> Map.update!(acc, stream, &[seq | &1])
      {:error, _} -> Map.update!(acc, :errors, &(&1 + 1))
    end
  catch
    :exit, _ -> Map.update!(acc, :errors, &(&1 + 1))
  end

  # -- clients

  defp collect(parent, tenant, topic) do
    {socket, _} = get_connection(tenant, @serializer, role: "authenticated")
    WebsocketClient.join(socket, "realtime:failover_pg", %{config: %{postgres_changes: @pg_changes}})
    WebsocketClient.join(socket, "realtime:" <> topic, %{config: %{private: true, broadcast: %{self: true}}})
    collect_loop(parent, %{pg: [], bdb: []})
  end

  defp collect_loop(parent, acc) do
    receive do
      :stop ->
        acc

      %Message{event: "postgres_changes", payload: %{"data" => %{"record" => %{"details" => details}}}} ->
        collect_loop(parent, add_event(acc, :pg, details))

      %Message{event: "broadcast", payload: %{"payload" => %{"record" => %{"details" => details}}}} ->
        collect_loop(parent, add_event(acc, :bdb, details))

      %Message{event: "system", payload: %{"extension" => "postgres_changes", "status" => "ok"}} ->
        send(parent, :pg_subscribed)
        collect_loop(parent, acc)

      _other ->
        collect_loop(parent, acc)
    end
  end

  defp add_event(acc, stream, details), do: Map.update!(acc, stream, &[{String.to_integer(details), now()} | &1])

  # A new Postgres Changes channel, joined while the failover is under way.
  defp late_join(tenant) do
    Process.sleep(@late_join_after_ms)
    {socket, _} = get_connection(tenant, @serializer)
    WebsocketClient.join(socket, "realtime:failover_late", %{config: %{postgres_changes: @pg_changes}})
    await_subscription(now() + @late_join_timeout_ms)
  end

  defp await_subscription(deadline) do
    receive do
      %Message{event: "system", payload: %{"extension" => "postgres_changes", "status" => "ok"}} ->
        :subscribed

      %Message{event: "system", payload: %{"extension" => "postgres_changes", "status" => "error"} = payload} ->
        {:error, payload["message"]}

      _other ->
        await_subscription(deadline)
    after
      max(deadline - now(), 0) -> :timeout
    end
  end

  # -- database

  defp setup_broadcast_changes(tenant, topic) do
    {:ok, conn} = Database.connect(tenant, "realtime_test", :stop)

    create_rls_policies(
      conn,
      [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence],
      %{topic: topic}
    )

    Postgrex.query!(conn, "CREATE TABLE public.failover_changes (id serial primary key, details text)", [])

    Postgrex.query!(
      conn,
      """
      CREATE OR REPLACE FUNCTION public.failover_changes_trigger ()
      RETURNS TRIGGER
      AS $$
      BEGIN
        PERFORM realtime.broadcast_changes ('#{topic}', TG_OP, TG_OP, TG_TABLE_NAME, TG_TABLE_SCHEMA, NEW, OLD, TG_LEVEL);
        RETURN NULL;
      END;
      $$
      LANGUAGE plpgsql;
      """,
      []
    )

    Postgrex.query!(
      conn,
      """
      CREATE TRIGGER failover_changes_broadcast
      AFTER INSERT OR UPDATE OR DELETE ON public.failover_changes
      FOR EACH ROW
      EXECUTE FUNCTION public.failover_changes_trigger ();
      """,
      []
    )

    GenServer.stop(conn)
  end

  # -- cluster

  defp docker(container, args), do: System.cmd("docker", ["exec", container | args], stderr_to_stdout: true)

  # multiadmin lists each pooler with its role.
  defp primary!(container) do
    {out, 0} = docker(container, ["curl", "-s", "localhost:15000/api/v1/poolers"])
    %{"poolers" => poolers} = Jason.decode!(out)
    %{"id" => %{"name" => name}, "portMap" => %{"grpc" => grpc}} = Enum.find(poolers, &(&1["type"] == "PRIMARY"))
    {name, grpc}
  end

  # -- helpers

  defp now, do: System.monotonic_time(:millisecond)

  defp wait_until(fun, timeout) do
    cond do
      fun.() -> true
      timeout <= 0 -> false
      true -> Process.sleep(250) && wait_until(fun, timeout - 250)
    end
  end
end
