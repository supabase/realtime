# Measures realtime.apply_rls, the step of a Postgres Changes poll that decides which subscriptions
# may see a change, as the number of subscriptions to the changed table grows.
#
#     mise task run db-start
#     mix run dev/bench/apply_rls.exs
#
# Reads DB_HOST / DB_PORT / DB_NAME / DB_USER / DB_PASSWORD, defaulting to the tenant database
# that db-start brings up. The connecting role needs CREATEDB.

alias Realtime.Repo
alias Realtime.Tenants.Migrations

{:ok, _} = Application.ensure_all_started(:ecto_sql)

# Migration DDL is logged at :info and buries the results.
Logger.configure(level: :warning)

conn_opts = [
  hostname: System.get_env("DB_HOST", "127.0.0.1"),
  port: System.get_env("DB_PORT", "5433") |> String.to_integer(),
  database: System.get_env("DB_NAME", "postgres"),
  username: System.get_env("DB_USER", "supabase_admin"),
  password: System.get_env("DB_PASSWORD", "postgres")
]

scratch = "realtime_bench_#{System.system_time(:second)}"

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

  # One table per job, each holding the row the change is about.
  for table <- ["bench_rls", "bench_no_rls"] do
    Postgrex.query!(conn, "CREATE TABLE public.#{table} (id int primary key, details text)", [])
    Postgrex.query!(conn, "GRANT SELECT ON public.#{table} TO anon", [])
    Postgrex.query!(conn, "INSERT INTO public.#{table} VALUES (1, 'allowed')", [])
  end

  Postgrex.query!(conn, "ALTER TABLE public.bench_rls ENABLE ROW LEVEL SECURITY", [])

  Postgrex.query!(
    conn,
    """
    CREATE POLICY bench_read ON public.bench_rls TO anon
    USING (details = current_setting('request.jwt.claims', true)::jsonb ->> 'audience')
    """,
    []
  )

  # An insert of that row, in the wal2json format-version 2 shape list_changes hands apply_rls.
  wal = fn table ->
    %{
      "action" => "I",
      "schema" => "public",
      "table" => table,
      "timestamp" => "2026-10-28 10:00:00.000000+00",
      "pk" => [%{"name" => "id", "type" => "integer", "typeoid" => 23}],
      "columns" => [
        %{"name" => "id", "type" => "integer", "typeoid" => 23, "value" => 1},
        %{"name" => "details", "type" => "text", "typeoid" => 25, "value" => "allowed"}
      ]
    }
  end

  # How many subscriptions were found visible, summed over the selected_columns groups returned.
  apply_rls = fn wal ->
    %Postgrex.Result{rows: rows} =
      Postgrex.query!(conn, "SELECT cardinality(subscription_ids) FROM realtime.apply_rls($1)", [wal])

    rows |> List.flatten() |> Enum.sum()
  end

  # Every subscriber is a distinct user who passes both the filters and the policy.
  subscribe = fn table, count ->
    Postgrex.query!(conn, "TRUNCATE realtime.subscription", [])

    Postgrex.query!(
      conn,
      """
      INSERT INTO realtime.subscription (subscription_id, entity, filters, claims)
      SELECT gen_random_uuid(), $1::text::regclass, '{}',
             jsonb_build_object('role', 'anon', 'audience', 'allowed', 'sub', gen_random_uuid())
      FROM generate_series(1, $2)
      """,
      ["public.#{table}", count]
    )
  end

  job = fn table ->
    wal = wal.(table)

    {fn _count -> apply_rls.(wal) end,
     before_scenario: fn count ->
       subscribe.(table, count)
       ^count = apply_rls.(wal)
       count
     end}
  end

  Benchee.run(
    %{
      "RLS enabled" => job.("bench_rls"),
      "RLS disabled" => job.("bench_no_rls")
    },
    inputs: %{
      "100 subscriptions" => 100,
      "1000 subscriptions" => 1000,
      "10000 subscriptions" => 10_000
    },
    warmup: 5,
    time: 10,
    print: %{configuration: false}
  )

  GenServer.stop(conn)
after
  admin!.(~s|DROP DATABASE IF EXISTS "#{scratch}" WITH (FORCE)|)
end
