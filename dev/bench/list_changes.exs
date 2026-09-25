# Measures the Postgres Changes poll: realtime.list_changes decoding a batch from the
# replication slot and running it through apply_rls.
#
# Provisions its own throwaway database and migrates it, so it measures whatever the checked-out
# revision defines. Run it on two revisions against the same server to compare them.
#
#     mise task run db-start
#     mix run dev/bench/list_changes.exs
#
# Reads DB_HOST / DB_PORT / DB_NAME / DB_USER / DB_PASSWORD, defaulting to the tenant database
# that db-start brings up. The connecting role needs CREATEDB.

alias Extensions.PostgresCdcRls.Replications
alias Realtime.Repo
alias Realtime.Tenants.Migrations

{:ok, _} = Application.ensure_all_started(:ecto_sql)

conn_opts = [
  hostname: System.get_env("DB_HOST", "127.0.0.1"),
  port: System.get_env("DB_PORT", "5433") |> String.to_integer(),
  database: System.get_env("DB_NAME", "postgres"),
  username: System.get_env("DB_USER", "supabase_admin"),
  password: System.get_env("DB_PASSWORD", "postgres")
]

scratch = "realtime_bench_#{System.system_time(:second)}"
publication = "bench_publication"
slot = "bench_slot"

admin! = fn query ->
  {:ok, conn} = Postgrex.start_link(Keyword.put(conn_opts, :backoff_type, :stop))
  {:ok, _} = Postgrex.query(conn, query, [])
  GenServer.stop(conn)
end

admin!.(~s(CREATE DATABASE "#{scratch}"))

try do
  scratch_opts = Keyword.put(conn_opts, :database, scratch)

  Repo.with_dynamic_repo(Keyword.merge(scratch_opts, pool_size: 2, backoff_type: :stop), fn repo ->
    Repo.query!(~s(CREATE SCHEMA realtime AUTHORIZATION "supabase_admin"), [], dynamic_repo: repo)
    Repo.query!(~s(GRANT ALL ON SCHEMA realtime TO "supabase_realtime_admin"), [], dynamic_repo: repo)

    Ecto.Migrator.run(Repo, Migrations.migrations(), :up,
      all: true,
      prefix: "realtime",
      dynamic_repo: repo,
      timeout: 120_000
    )
  end)

  {:ok, conn} = Postgrex.start_link(Keyword.put(scratch_opts, :backoff_type, :stop))
  {:ok, writer} = Postgrex.start_link(Keyword.put(scratch_opts, :backoff_type, :stop))

  # A policy that reads the row is what makes apply_rls resolve against the table rather than
  # authorizing straight from the WAL record, which is the expensive path worth measuring.
  Postgrex.query!(conn, "CREATE TABLE public.bench (id serial primary key, details text)", [])
  Postgrex.query!(conn, "GRANT SELECT ON public.bench TO anon", [])
  Postgrex.query!(conn, "ALTER TABLE public.bench ENABLE ROW LEVEL SECURITY", [])

  Postgrex.query!(
    conn,
    """
    CREATE POLICY bench_read ON public.bench TO anon
    USING (details = current_setting('request.jwt.claims', true)::jsonb ->> 'audience')
    """,
    []
  )

  Postgrex.query!(conn, "CREATE PUBLICATION #{publication} FOR TABLE public.bench", [])

  Postgrex.query!(
    conn,
    """
    INSERT INTO realtime.subscription (subscription_id, entity, filters, claims)
    VALUES (gen_random_uuid(), 'public.bench'::regclass, '{}',
            '{"role":"anon","audience":"allowed","sub":"00000000-0000-0000-0000-000000000000"}'::jsonb)
    """,
    []
  )

  {:ok, _} = Replications.prepare_replication(conn, slot)

  # Drain whatever setup produced so the first measured poll starts from an empty slot.
  {:ok, _} =
    Replications.list_changes(conn,
      slot_name: slot,
      publication: publication,
      max_changes: 100_000,
      max_record_bytes: 1_048_576
    )

  fill = fn count ->
    Postgrex.query!(
      writer,
      "INSERT INTO public.bench (details) SELECT 'allowed' FROM generate_series(1, $1)",
      [count]
    )
  end

  drain = fn ->
    {:ok, %Postgrex.Result{rows: rows}} =
      Replications.list_changes(conn,
        slot_name: slot,
        publication: publication,
        max_changes: 100_000,
        max_record_bytes: 1_048_576
      )

    rows
  end

  Benchee.run(
    %{"list_changes" => fn _ -> drain.() end},
    inputs: %{
      "1 change" => 1,
      "100 changes" => 100,
      "1000 changes" => 1000,
      "10000 changes" => 10_000
    },
    # Each poll consumes the slot, so every run needs its own batch. Hook time is excluded
    # from the measurement.
    before_each: fn count ->
      fill.(count)
      count
    end,
    warmup: 2,
    time: 10,
    print: %{configuration: false}
  )

  # The slot is temporary, so it goes with the session that made it. The database cannot be
  # dropped while it is still held.
  GenServer.stop(conn)
  GenServer.stop(writer)
after
  admin!.(~s|DROP DATABASE IF EXISTS "#{scratch}" WITH (FORCE)|)
end
