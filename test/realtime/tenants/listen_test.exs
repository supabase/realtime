defmodule Realtime.Tenants.ListenTest do
  use Realtime.DataCase, async: false
  import ExUnit.CaptureLog

  alias Realtime.Tenants.Listen
  alias Realtime.Database

  describe "start/1" do
    setup do
      tenant = Containers.checkout_tenant(run_migrations: true)

      %{tenant: tenant}
    end

    test "connection error" do
      port = Generators.port()

      extensions = [
        %{
          "type" => "postgres_cdc_rls",
          "settings" => %{
            "db_host" => "127.0.0.1",
            "db_name" => "postgres",
            "db_user" => "postgres",
            "db_password" => "postgres",
            "db_port" => "#{port}",
            "poll_interval" => 100,
            "poll_max_changes" => 100,
            "poll_max_record_bytes" => 1_048_576,
            "region" => "us-east-1",
            "ssl_enforced" => true
          }
        }
      ]

      tenant = tenant_fixture(%{extensions: extensions})

      {:error, {:error, %DBConnection.ConnectionError{}}} = Listen.start(tenant, self())
    end

    test "monitored pid stopping also stops Listen process", %{tenant: tenant} do
      monitored_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, listen} = Listen.start(tenant, monitored_pid)

      send(monitored_pid, :stop)

      ref = Process.monitor(listen)
      assert_receive {:DOWN, ^ref, :process, ^listen, _reason}, 100
      refute Process.alive?(listen)
    end

    test "process already exists", %{tenant: tenant} do
      {:ok, listen} = Listen.start(tenant, self())

      # Same listen process is returned
      {:ok, ^listen} = Listen.start(tenant, self())
    end

    test "on realtime.send error, notify will capture and log error", %{tenant: tenant} do
      {:ok, _listen} = Listen.start(tenant, self())
      {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)

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
