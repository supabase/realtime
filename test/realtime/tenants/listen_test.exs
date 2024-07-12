defmodule Realtime.Tenants.ListenTest do
  # async: false due to the fact that it's doing Postgres NOTIFY and could interfere with other tests
  use Realtime.DataCase, async: false
  import Mock

  alias Realtime.RateCounter
  alias Realtime.Tenants.Listen

  alias RealtimeWeb.Endpoint
  import ExUnit.CaptureLog

  describe("start/1") do
    setup do
      start_supervised(RealtimeWeb.Joken.CurrentTime.Mock)
      start_supervised(Realtime.RateCounter.DynamicSupervisor)
      start_supervised(Realtime.GenCounter.DynamicSupervisor)

      tenant = tenant_fixture()

      RateCounter.new({:channel, :events, tenant.external_id})
      {:ok, listen_conn} = Listen.start(tenant)

      {:ok, db_conn} = connect(tenant)

      on_exit(fn ->
        Process.exit(listen_conn, :shutdown)
        Process.exit(db_conn, :shutdown)
      end)

      {:ok, tenant: tenant, db_conn: db_conn}
    end

    test "on public notify, broadcasts to topic", %{tenant: tenant, db_conn: db_conn} do
      with_mocks [
        {Endpoint, [:passthrough], broadcast_from: fn _, _, _, _ -> :ok end}
      ] do
        topic = random_string()

        messages =
          Stream.repeatedly(fn ->
            %{
              private: Enum.random([true, false]),
              topic: topic,
              payload: random_string(),
              event: random_string()
            }
          end)
          |> Enum.take(5)

        Enum.each(messages, fn %{private: private, topic: topic, payload: payload, event: event} ->
          broadcast_test_message(db_conn, private, topic, event, payload)
        end)

        :timer.sleep(1000)

        messages =
          Enum.map(messages, fn %{private: private, topic: topic, payload: payload, event: event} ->
            payload = %{
              "type" => "broadcast",
              "event" => event,
              "payload" => %{"payload" => payload}
            }

            private_prefix = if private, do: "-private:", else: ":"

            args = [
              "#{String.upcase(tenant.external_id)}#{private_prefix}#{topic}",
              "broadcast",
              payload
            ]

            %{mod: Endpoint, fun: :broadcast_from, args: args}
          end)

        calls = Endpoint |> call_history() |> Enum.map(&elem(&1, 1))

        Enum.each(messages, fn expected ->
          assert Enum.find(calls, fn {mod, function, args} ->
                   mod == expected.mod and function == expected.fun and
                     Enum.drop(args, 1) == expected.args
                 end)
        end)
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
