defmodule Realtime.Tenants.ListenTest do
  # async: false due to the fact that it's doing Postgres NOTIFY and could interfere with other tests
  use Realtime.DataCase, async: false
  import ExUnit.CaptureLog

  import Mock

  alias Realtime.GenCounter
  alias Realtime.RateCounter
  alias Realtime.Tenants.Listen
  alias Realtime.Tenants.Migrations
  alias Realtime.Database
  alias RealtimeWeb.Endpoint

  describe("start/1") do
    setup do
      start_supervised(RealtimeWeb.Joken.CurrentTime.Mock)
      start_supervised(Realtime.RateCounter.DynamicSupervisor)
      start_supervised(Realtime.GenCounter.DynamicSupervisor)

      tenant = tenant_fixture()
      RateCounter.new({:channel, :events, tenant.external_id})

      {:ok, listen_conn} = Listen.start(tenant, self())
      {:ok, db_conn} = Database.connect(tenant, "realtime_test")
      Migrations.run_migrations(tenant)

      on_exit(fn ->
        Process.exit(listen_conn, :normal)
        Process.exit(db_conn, :normal)
      end)

      {:ok, tenant: tenant, db_conn: db_conn}
    end

    test "on realtime.send error, notify will capture and log error", %{db_conn: db_conn} do
      with_mocks [
        {Endpoint, [:passthrough], broadcast_from: fn _, _, _, _ -> :ok end},
        {GenCounter, [:passthrough], add: fn _ -> :ok end},
        {RateCounter, [:passthrough], get: fn _ -> {:ok, %{avg: 0}} end}
      ] do
        assert capture_log(fn ->
                 Postgrex.query!(
                   db_conn,
                   """
                   DO $$
                   BEGIN
                     INSERT INTO realtime.messages (payload, event, topic, private, extension, inserted_at) VALUES (null, 'event', 'topic', false, 'broadcast', NOW() - INTERVAL '10 days');
                   EXCEPTION
                   WHEN OTHERS THEN
                     PERFORM pg_notify(
                       'realtime:system',
                       jsonb_build_object('error', SQLERRM , 'function', 'realtime.send', 'event', 'event', 'topic', 'topic', 'private', false )::text
                     );
                   END
                   $$;
                   """,
                   []
                 )

                 :timer.sleep(100)
               end) =~ "FailedSendFromDatabase"
      end
    end
  end

  describe "whereis/1" do
    test "returns pid if exists" do
      tenant = tenant_fixture()
      Listen.start(tenant, self())
      assert Listen.whereis(tenant.external_id)
    end

    test "returns nil if not exists" do
      assert Listen.whereis(random_string()) == nil
    end
  end
end
