defmodule Realtime.Tenants.ListenTest do
  # async: false due to the fact that it's doing Postgres NOTIFY and could interfere with other tests
  use Realtime.DataCase, async: false
  import Mock

  alias Realtime.GenCounter
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
        Process.exit(listen_conn, :normal)
        Process.exit(db_conn, :normal)
      end)

      {:ok, tenant: tenant, db_conn: db_conn}
    end

    test "on public notify, broadcasts to topic", %{tenant: tenant, db_conn: db_conn} do
      with_mocks [
        {Endpoint, [:passthrough], broadcast_from: fn _, _, _, _ -> :ok end},
        {GenCounter, [:passthrough], add: fn _ -> :ok end},
        {RateCounter, [:passthrough], get: fn _ -> {:ok, %{avg: 0}} end}
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
          |> Enum.take(10)

        Enum.each(messages, fn %{private: private, topic: topic, payload: payload, event: event} ->
          broadcast_test_message(db_conn, private, topic, event, payload)
        end)

        :timer.sleep(100)

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

    test "on bad format logs out error", %{tenant: tenant, db_conn: db_conn} do
      with_mocks [
        {Endpoint, [:passthrough], broadcast_from: fn _, _, _, _ -> :ok end},
        {GenCounter, [:passthrough], add: fn _ -> :ok end},
        {RateCounter, [:passthrough], get: fn _ -> {:ok, %{avg: 0}} end}
      ] do
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
    end

    test "on non json format logs out error", %{tenant: tenant, db_conn: db_conn} do
      with_mocks [
        {Endpoint, [:passthrough], broadcast_from: fn _, _, _, _ -> :ok end},
        {GenCounter, [:passthrough], add: fn _ -> :ok end},
        {RateCounter, [:passthrough], get: fn _ -> {:ok, %{avg: 0}} end}
      ] do
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
end
