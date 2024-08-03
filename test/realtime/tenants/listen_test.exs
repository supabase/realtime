defmodule Realtime.Tenants.ListenTest do
  # async: false due to the fact that it's doing Postgres NOTIFY and could interfere with other tests
  use Realtime.DataCase, async: false
  import Mock
  import ExUnit.CaptureLog

  alias Realtime.Database
  alias Realtime.RateCounter
  alias Realtime.Tenants.Listen

  alias RealtimeWeb.Endpoint

  describe("start/1") do
    setup do
      start_supervised(RealtimeWeb.Joken.CurrentTime.Mock)
      start_supervised(Realtime.RateCounter.DynamicSupervisor)
      start_supervised(Realtime.GenCounter.DynamicSupervisor)

      tenant = tenant_fixture()

      RateCounter.new({:channel, :events, tenant.external_id})
      {:ok, _} = Listen.start(tenant)
      {:ok, db_conn} = Database.connect(tenant, "realtime_test", 1)
      {:ok, tenant: tenant, db_conn: db_conn}
    end

    test "on public notify, broadcasts to topic", %{tenant: tenant, db_conn: db_conn} do
      with_mocks [
        {Endpoint, [:passthrough], broadcast_from: fn _, _, _, _ -> :ok end}
      ] do
        topic = random_string()

        private_message = %{
          topic: topic,
          payload: random_string(),
          event: random_string()
        }

        broadcast_test_message(
          db_conn,
          true,
          private_message.topic,
          private_message.event,
          private_message.payload
        )

        public_message = %{
          topic: topic,
          payload: random_string(),
          event: random_string()
        }

        broadcast_test_message(
          db_conn,
          false,
          public_message.topic,
          public_message.event,
          public_message.payload
        )

        :timer.sleep(1000)

        private_topic =
          Realtime.Tenants.tenant_topic(tenant.external_id, private_message.topic, false)

        public_topic =
          Realtime.Tenants.tenant_topic(tenant.external_id, private_message.topic, true)

        assert_called(
          Endpoint.broadcast_from(:_, private_topic, "broadcast", %{
            "payload" => %{"payload" => private_message.payload},
            "event" => private_message.event,
            "type" => "broadcast"
          })
        )

        assert_called(
          Endpoint.broadcast_from(:_, public_topic, "broadcast", %{
            "payload" => %{"payload" => public_message.payload},
            "event" => public_message.event,
            "type" => "broadcast"
          })
        )
      end
    end

    test "on failure to connect, returns error" do
      tenant =
        tenant_fixture(%{
          extensions: [
            %{
              "type" => "postgres_cdc_rls",
              "settings" => %{
                "db_host" => "localhost",
                "db_name" => "postgres",
                "db_user" => "supabase_admin",
                "db_password" => "postgres",
                "db_port" => "5433",
                "poll_interval" => 100,
                "poll_max_changes" => 100,
                "poll_max_record_bytes" => 1_048_576,
                "region" => "us-east-1",
                "ssl_enforced" => true
              }
            }
          ]
        })

      assert {:error, %Postgrex.Error{message: "ssl not available"}} = Listen.start(tenant)
    end

    test "on bad format logs out error", %{db_conn: db_conn} do
      capture_log(fn ->
        query =
          """
          select pg_notify(
              'realtime:broadcast',
              json_build_object(
                  'private', $1::boolean,
                  'event', $2::text,
                  'payload', $3::jsonb
              )::text
          );
          """

        Postgrex.query!(db_conn, query, [false, random_string(), %{payload: random_string()}])
      end) =~ "UnableToProcessListenPayload"
    end

    test "on non json format logs out error", %{db_conn: db_conn} do
      capture_log(fn ->
        query =
          """
          select pg_notify(
              'realtime:broadcast',
              'potato'::text
          );
          """

        Postgrex.query!(db_conn, query, [])
      end) =~ "UnableToProcessListenPayload"
    end
  end
end
