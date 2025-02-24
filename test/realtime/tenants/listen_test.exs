defmodule Realtime.Tenants.ListenTest do
  use Realtime.DataCase, async: true
  import ExUnit.CaptureLog

  alias Realtime.Tenants.Listen
  alias Realtime.Tenants.Migrations
  alias Realtime.Database

  describe("start/1") do
    setup do
      start_supervised(RealtimeWeb.Joken.CurrentTime.Mock)
      start_supervised(Realtime.RateCounter)
      start_supervised(Realtime.GenCounter)

      tenant = Containers.checkout_tenant(true)
      on_exit(fn -> Containers.checkin_tenant(tenant) end)

      {:ok, _} = Listen.start(tenant, self())
      {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)
      Migrations.run_migrations(tenant)

      {:ok, tenant: tenant, db_conn: db_conn}
    end

    test "on realtime.send error, notify will capture and log error", %{db_conn: db_conn} do
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

               Process.sleep(100)
             end) =~ "FailedSendFromDatabase"
    end
  end

  describe "whereis/1" do
    test "returns pid if exists" do
      tenant = Containers.checkout_tenant()
      Listen.start(tenant, self())
      assert Listen.whereis(tenant.external_id)
    end

    test "returns nil if not exists" do
      assert Listen.whereis(random_string()) == nil
    end
  end
end
