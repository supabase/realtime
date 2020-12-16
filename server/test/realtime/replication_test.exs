defmodule Realtime.ReplicationTest do
  use ExUnit.Case

  import Mock

  alias Realtime.Replication.State

  doctest Realtime.Replication, import: true

  @test_config [
    epgsql: %{
      database: "test",
      host: "localhost",
      password: "postgres",
      port: 5432,
      ssl: true,
      username: "postgres"
    },
    slot: :temporary,
    wal_position: {"0", "0"},
    publications: ["pub_test"],
    conn_retry_initial_delay: 300,
    conn_retry_maximum_delay: 180_000,
    conn_retry_jitter: 0.2
  ]

  @test_state %State{
    config: @test_config,
    connection: nil,
    conn_retry_delays: [],
    subscribers: [],
    transaction: nil,
    relations: %{},
    types: %{}
  }

  test "Realtime.Replication.init/1 returns correct state" do
    assert {:ok, @test_state, {:continue, :init_db_conn}} =
             Realtime.Replication.init(
               epgsql: %{
                 database: "test",
                 host: "localhost",
                 password: "postgres",
                 port: 5432,
                 ssl: true,
                 username: "postgres"
               },
               slot: :temporary,
               wal_position: {"0", "0"},
               publications: ["pub_test"],
               conn_retry_initial_delay: "300",
               conn_retry_maximum_delay: "180000",
               conn_retry_jitter: "20"
             )
  end

  test "Realtime.Replication.handle_continue/2 :: :init_db_conn when adapter conn successful" do
    with_mock Realtime.Adapters.Postgres.EpgsqlImplementation,
      init: fn _ ->
        {:ok, "epgsqpl_pid"}
      end do
      assert {:noreply,
              %State{
                config: @test_config,
                connection: "epgsqpl_pid",
                conn_retry_delays: [],
                subscribers: [],
                transaction: nil,
                relations: %{},
                types: %{}
              }} = Realtime.Replication.handle_continue(:init_db_conn, @test_state)
    end
  end

  test "Realtime.Replication.handle_continue/2 :: :init_db_conn when adapter conn fails" do
    with_mock Realtime.Adapters.Postgres.EpgsqlImplementation,
      init: fn _ ->
        {:error, {:error, :econnrefused}}
      end do
      assert {:stop, {:error, :econnrefused}} =
               Realtime.Replication.handle_continue(:init_db_conn, @test_state)
    end
  end

  test "Integration Test: 0.2.0" do
    assert Realtime.Replication.handle_info(
             {:epgsql, 0,
              {:x_log_data, 0, 0,
               <<82, 0, 0, 64, 2, 112, 117, 98, 108, 105, 99, 0, 117, 115, 101, 114, 115, 0, 100,
                 0, 6, 1, 105, 100, 0, 0, 0, 0, 20, 255, 255, 255, 255, 0, 102, 105, 114, 115,
                 116, 95, 110, 97, 109, 101, 0, 0, 0, 0, 25, 255, 255, 255, 255, 0, 108, 97, 115,
                 116, 95, 110, 97, 109, 101, 0, 0, 0, 0, 25, 255, 255, 255, 255, 0, 105, 110, 102,
                 111, 0, 0, 0, 14, 218, 255, 255, 255, 255, 0, 105, 110, 115, 101, 114, 116, 101,
                 100, 95, 97, 116, 0, 0, 0, 4, 90, 255, 255, 255, 255, 0, 117, 112, 100, 97, 116,
                 101, 100, 95, 97, 116, 0, 0, 0, 4, 90, 255, 255, 255, 255>>}},
             %Realtime.Replication.State{}
           ) ==
             {:noreply,
              %Realtime.Replication.State{
                config: [],
                connection: nil,
                relations: %{
                  16386 => %Realtime.Decoder.Messages.Relation{
                    columns: [
                      %Realtime.Decoder.Messages.Relation.Column{
                        flags: [:key],
                        name: "id",
                        type: "int8",
                        type_modifier: 4_294_967_295
                      },
                      %Realtime.Decoder.Messages.Relation.Column{
                        flags: [],
                        name: "first_name",
                        type: "text",
                        type_modifier: 4_294_967_295
                      },
                      %Realtime.Decoder.Messages.Relation.Column{
                        flags: [],
                        name: "last_name",
                        type: "text",
                        type_modifier: 4_294_967_295
                      },
                      %Realtime.Decoder.Messages.Relation.Column{
                        flags: [],
                        name: "info",
                        type: "jsonb",
                        type_modifier: 4_294_967_295
                      },
                      %Realtime.Decoder.Messages.Relation.Column{
                        flags: [],
                        name: "inserted_at",
                        type: "timestamp",
                        type_modifier: 4_294_967_295
                      },
                      %Realtime.Decoder.Messages.Relation.Column{
                        flags: [],
                        name: "updated_at",
                        type: "timestamp",
                        type_modifier: 4_294_967_295
                      }
                    ],
                    id: 16386,
                    name: "users",
                    namespace: "public",
                    replica_identity: :default
                  }
                },
                subscribers: [],
                transaction: nil,
                types: %{}
              }}
  end

  test "Realtime.Replication.handle_info/2 :: :EXIT when adapter conn successful" do
    with_mock Realtime.Adapters.Postgres.EpgsqlImplementation,
      init: fn _ ->
        {:ok, "epgsqpl_pid"}
      end do
      state = %{@test_state | conn_retry_delays: [0, 1023, 1999]}

      assert {:noreply,
              %State{
                config: @test_config,
                connection: "epgsqpl_pid",
                conn_retry_delays: [],
                subscribers: [],
                transaction: nil,
                relations: %{},
                types: %{}
              }} = Realtime.Replication.handle_info({:EXIT, nil, nil}, state)
    end
  end

  test "Realtime.Replication.handle_info/2 :: :EXIT when adapter conn fails" do
    with_mock Realtime.Adapters.Postgres.EpgsqlImplementation,
      init: fn _ ->
        {:error, {:error, :econnrefused}}
      end do
      state = %{@test_state | conn_retry_delays: [0, 1023, 1999]}

      assert {:noreply,
              %State{
                config: @test_config,
                connection: nil,
                conn_retry_delays: [1023, 1999],
                subscribers: [],
                transaction: nil,
                relations: %{},
                types: %{}
              }} = Realtime.Replication.handle_info({:EXIT, nil, nil}, state)
    end
  end

  test "Realtime.Replication.get_retry_delay/1 when conn_retry_delays is empty" do
    state = %State{
      conn_retry_delays: [],
      config: [
        conn_retry_initial_delay: 300,
        conn_retry_maximum_delay: 180_000,
        conn_retry_jitter: 0.2
      ]
    }

    {delay, %State{conn_retry_delays: delays}} = Realtime.Replication.get_retry_delay(state)

    assert delay == 0
    assert is_list(delays)
    refute Enum.empty?(delays)
    assert Enum.all?(delays, &(is_integer(&1) and &1 > 0))
  end

  test "Realtime.Replication.get_retry_delay/1 when conn_retry_delays is not empty" do
    state = %State{
      conn_retry_delays: [489, 1011, 1996, 4023]
    }

    {delay, %State{conn_retry_delays: delays}} = Realtime.Replication.get_retry_delay(state)

    assert delay == 489
    assert delays == [1011, 1996, 4023]
  end

  test "Realtime.Replication.reset_retry_delay/1" do
    state = %State{
      conn_retry_delays: [198, 403, 781]
    }

    %State{conn_retry_delays: delays} = Realtime.Replication.reset_retry_delay(state)

    assert delays == []
  end
end
