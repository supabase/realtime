defmodule Extensions.PostgresCdcRls.SynchronousCommitDeliveryTest do
  # Postgres Changes delivers every committed change,
  # including one whose COMMIT waited for a synchronous standby.
  #
  # PostgreSQL writes the commit record to disk before that wait, so logical decoding returns the
  # INSERT while the writer is still in the proc array and no snapshot can see the row yet. A
  # policy that reads the row then matches nothing, so the change has to survive being decoded
  # early rather than being authorized for zero subscribers and consumed from the slot.
  #
  # Both tests need RLS: without a policy that reads the row, apply_rls authorizes straight from
  # the WAL record and never looks the row up, so neither exercises the window.
  #
  # These currently fail. A Multigres cluster runs `synchronous_standby_names = ANY 1 (...)`, so
  # the window is open on every commit there; plain PostgreSQL defaults to no synchronous standby
  # and the second test has to arrange one.
  use Realtime.DataCase, async: false

  alias Extensions.PostgresCdcRls.Replications
  alias Extensions.PostgresCdcRls.Subscriptions
  alias Realtime.Database

  @publication "supabase_realtime_test"
  @claims %{"role" => "anon", "audience" => "allowed"}

  setup do
    tenant = TestTenantDb.checkout_tenant(run_migrations: true)
    {:ok, conn} = Database.connect(tenant, "realtime_rls", :stop)
    Integrations.setup_postgres_changes(conn)

    # setup_postgres_changes leaves public.test without RLS, which is the one thing this repro
    # needs: a policy that has to read the row before the change can be authorized.
    Postgrex.query!(conn, "ALTER TABLE public.test ENABLE ROW LEVEL SECURITY", [])

    Postgrex.query!(
      conn,
      """
      CREATE POLICY audience_read ON public.test TO anon
      USING (details = current_setting('request.jwt.claims', true)::jsonb ->> 'audience')
      """,
      []
    )

    slot = "sync_commit_#{System.unique_integer([:positive])}"
    {:ok, _} = subscribe(conn)
    {:ok, _} = Replications.prepare_replication(conn, slot)

    %{conn: conn, tenant: tenant, slot: slot}
  end

  # Multigres already commits behind a synchronous standby, so nothing has to be arranged here.
  test "concurrent writes all reach the subscriber", %{conn: conn, tenant: tenant, slot: slot} do
    {:ok, writer} = Database.connect(tenant, "realtime_test", :stop)
    inserts = 200
    parent = self()

    spawn(fn ->
      for _ <- 1..inserts, do: Postgrex.query!(writer, "INSERT INTO public.test (details) VALUES ('allowed')", [])
      send(parent, :writes_done)
    end)

    delivered = collect(conn, slot, 0)

    assert delivered == inserts,
           "#{inserts - delivered} of #{inserts} INSERTs were consumed from the slot but never " <>
             "reached the subscriber"
  end

  # The same window on a database that has no synchronous standby of its own, to show the bug is
  # Realtime's rather than Multigres'. Needs the docker backend for ALTER SYSTEM.
  @tag :requires_docker_backend
  test "an INSERT committing behind a synchronous standby reaches the subscriber", %{
    conn: conn,
    tenant: tenant,
    slot: slot
  } do
    on_exit(fn ->
      {:ok, reset} = Database.connect(tenant, "realtime_test", :stop)
      Postgrex.query(reset, "ALTER SYSTEM RESET synchronous_standby_names", [])
      Postgrex.query(reset, "SELECT pg_reload_conf()", [])
    end)

    Postgrex.query!(conn, "ALTER SYSTEM SET synchronous_standby_names = 'FIRST 1 (absent_standby)'", [])
    Postgrex.query!(conn, "SELECT pg_reload_conf()", [])

    assert_eventually %{rows: [["FIRST 1 (absent_standby)"]]} =
                        Postgrex.query!(conn, "SHOW synchronous_standby_names", [])

    {:ok, writer} = Database.connect(tenant, "realtime_test", :stop)
    spawn(fn -> Postgrex.query(writer, "INSERT INTO public.test (details) VALUES ('allowed')", [], timeout: 30_000) end)

    assert_eventually %{num_rows: 1} = Postgrex.query!(conn, waiting_in_syncrep(), [])
    assert %{rows: [[0]]} = Postgrex.query!(conn, "SELECT count(*)::int FROM public.test", [])

    during_wait = authorized(conn, slot)

    # Release the wait so the row becomes visible, then take whatever is left in the slot.
    Postgrex.query!(conn, "SELECT pg_cancel_backend(pid) FROM (#{waiting_in_syncrep()}) w", [])
    assert_eventually %{rows: [[1]]} = Postgrex.query!(conn, "SELECT count(*)::int FROM public.test", [])

    assert during_wait + authorized(conn, slot) == 1,
           "the INSERT was consumed from the slot while its row was invisible, authorized for no " <>
             "subscribers, and never re-delivered once it became visible"
  end

  defp subscribe(conn) do
    {:ok, params} =
      Subscriptions.parse_subscription_params(%{"event" => "INSERT", "schema" => "public", "table" => "test"})

    Subscriptions.create(
      conn,
      @publication,
      [%{claims: @claims, id: UUID.uuid1(), subscription_params: params}],
      self(),
      self()
    )
  end

  defp waiting_in_syncrep do
    "SELECT pid FROM pg_stat_activity WHERE wait_event = 'SyncRep' AND backend_type = 'client backend'"
  end

  # A change authorized for nobody is not returned at all - only the sentinel's consumed count
  # moves - so counting the authorized rows is what shows the loss.
  defp authorized(conn, slot) do
    {:ok, %Postgrex.Result{rows: rows}} = Replications.list_changes(conn, slot, @publication, 1000, 1_048_576)

    Enum.count(rows, fn
      ["INSERT", "public", "test", _cols, _record, _old, _ts, subscription_ids, _errors, _count] ->
        subscription_ids != []

      _sentinel ->
        false
    end)
  end

  defp collect(conn, slot, delivered) do
    delivered = delivered + authorized(conn, slot)

    receive do
      :writes_done -> drain(conn, slot, delivered)
    after
      0 -> collect(conn, slot, delivered)
    end
  end

  # Stop only after several consecutive empty polls: one proves nothing while the writer's WAL
  # is still being decoded.
  defp drain(conn, slot, delivered, empty \\ 0)
  defp drain(_conn, _slot, delivered, 5), do: delivered

  defp drain(conn, slot, delivered, empty) do
    case authorized(conn, slot) do
      0 -> drain(conn, slot, delivered, empty + 1)
      n -> drain(conn, slot, delivered + n, 0)
    end
  end
end
