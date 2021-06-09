defmodule Realtime.ReplicationTest do
  use ExUnit.Case

  import Mock

  alias Realtime.Replication
  alias Realtime.Adapters.Changes.Transaction
  alias Realtime.Adapters.Postgres.Decoder.Messages.Relation
  alias Realtime.Adapters.Postgres.EpgsqlServer
  alias Realtime.SubscribersNotification

  @test_columns [
    %Relation.Column{
      flags: [:key],
      name: "id",
      type: "int8",
      type_modifier: 4_294_967_295
    },
    %Relation.Column{
      flags: [],
      name: "details",
      type: "text",
      type_modifier: 4_294_967_295
    },
    %Relation.Column{
      flags: [],
      name: "user_id",
      type: "int8",
      type_modifier: 4_294_967_295
    },
    %Relation.Column{
      flags: [],
      name: "inserted_at_with_time_zone",
      type: "timestamptz",
      type_modifier: 4_294_967_295
    },
    %Relation.Column{
      flags: [],
      name: "inserted_at_without_time_zone",
      type: "timestamp",
      type_modifier: 4_294_967_295
    }
  ]

  setup do
    test_state = %Replication.State{
      relations: %{
        26725 => %Relation{
          columns: @test_columns,
          id: 26725,
          name: "todos",
          namespace: "public",
          replica_identity: :default
        }
      },
      reverse_changes: [],
      transaction: nil,
      types: %{}
    }

    {:ok, test_state: test_state}
  end

  test "transaction begin message" do
    assert {:noreply,
            %Replication.State{
              relations: %{},
              reverse_changes: [],
              transaction:
                {{0, 49_723_672},
                 %Realtime.Adapters.Changes.Transaction{
                   changes: nil,
                   commit_timestamp: %DateTime{
                     calendar: Calendar.ISO,
                     day: 2,
                     hour: 3,
                     microsecond: {725_420, 0},
                     minute: 8,
                     month: 4,
                     second: 14,
                     std_offset: 0,
                     time_zone: "Etc/UTC",
                     utc_offset: 0,
                     year: 2021,
                     zone_abbr: "UTC"
                   }
                 }},
              types: %{}
            }} =
             Replication.handle_info(
               {:epgsql, "pid",
                {:x_log_data, 0, 0,
                 <<66, 0, 0, 0, 0, 2, 246, 185, 24, 0, 2, 97, 243, 109, 116, 149, 44, 0, 0, 2,
                   254>>}},
               %Replication.State{}
             )
  end

  test "transaction relation message" do
    assert {:noreply,
            %Realtime.Replication.State{
              relations: %{
                16628 => %Realtime.Adapters.Postgres.Decoder.Messages.Relation{
                  columns: @test_columns,
                  id: 16628,
                  name: "test",
                  namespace: "public",
                  replica_identity: :default
                }
              },
              reverse_changes: [],
              transaction: nil,
              types: %{}
            }} =
             Replication.handle_info(
               {:epgsql, "pid",
                {:x_log_data, 0, 0,
                 <<82, 0, 0, 64, 244, 112, 117, 98, 108, 105, 99, 0, 116, 101, 115, 116, 0, 100,
                   0, 5, 1, 105, 100, 0, 0, 0, 0, 20, 255, 255, 255, 255, 0, 100, 101, 116, 97,
                   105, 108, 115, 0, 0, 0, 0, 25, 255, 255, 255, 255, 0, 117, 115, 101, 114, 95,
                   105, 100, 0, 0, 0, 0, 20, 255, 255, 255, 255, 0, 105, 110, 115, 101, 114, 116,
                   101, 100, 95, 97, 116, 95, 119, 105, 116, 104, 95, 116, 105, 109, 101, 95, 122,
                   111, 110, 101, 0, 0, 0, 4, 160, 255, 255, 255, 255, 0, 105, 110, 115, 101, 114,
                   116, 101, 100, 95, 97, 116, 95, 119, 105, 116, 104, 111, 117, 116, 95, 116,
                   105, 109, 101, 95, 122, 111, 110, 101, 0, 0, 0, 4, 90, 255, 255, 255, 255>>}},
               %Replication.State{}
             )
  end

  test "transaction insert message", %{test_state: test_state} do
    test_state = %{
      test_state
      | transaction:
          {{0, 688_510_024},
           %Transaction{
             changes: [],
             commit_timestamp: %DateTime{
               calendar: Calendar.ISO,
               day: 16,
               hour: 23,
               microsecond: {518_844, 0},
               minute: 47,
               month: 2,
               second: 47,
               std_offset: 0,
               time_zone: "Etc/UTC",
               utc_offset: 0,
               year: 2021,
               zone_abbr: "UTC"
             }
           }}
    }

    assert {:noreply,
            %Replication.State{
              reverse_changes: [
                {26725, "INSERT",
                 {"3", "Supabase is good!", "1", "2021-02-16 23:47:47.51613+00",
                  "2021-02-16 23:47:47.51613"}, nil}
              ],
              transaction: {_lsn, %Transaction{changes: []}}
            }} =
             Replication.handle_info(
               {:epgsql, "pid",
                {:x_log_data, 0, 0,
                 <<73, 0, 0, 104, 101, 78, 0, 5, 116, 0, 0, 0, 1, 51, 116, 0, 0, 0, 17, 83, 117,
                   112, 97, 98, 97, 115, 101, 32, 105, 115, 32, 103, 111, 111, 100, 33, 116, 0, 0,
                   0, 1, 49, 116, 0, 0, 0, 28, 50, 48, 50, 49, 45, 48, 50, 45, 49, 54, 32, 50, 51,
                   58, 52, 55, 58, 52, 55, 46, 53, 49, 54, 49, 51, 43, 48, 48, 116, 0, 0, 0, 25,
                   50, 48, 50, 49, 45, 48, 50, 45, 49, 54, 32, 50, 51, 58, 52, 55, 58, 52, 55, 46,
                   53, 49, 54, 49, 51>>}},
               test_state
             )
  end

  test "transaction update message", %{test_state: test_state} do
    test_state = %{
      test_state
      | transaction:
          {{0, 688_510_024},
           %Transaction{
             changes: [],
             commit_timestamp: %DateTime{
               calendar: Calendar.ISO,
               day: 16,
               hour: 23,
               microsecond: {518_844, 0},
               minute: 47,
               month: 2,
               second: 47,
               std_offset: 0,
               time_zone: "Etc/UTC",
               utc_offset: 0,
               year: 2021,
               zone_abbr: "UTC"
             }
           }}
    }

    assert {:noreply,
            %Replication.State{
              reverse_changes: [
                {26725, "UPDATE",
                 {"3", "No, Supabase is great!", "1", "2021-02-16 23:47:47.51613+00",
                  "2021-02-16 23:47:47.51613"},
                 {"3", "Supabase is good!", "1", "2021-02-16 23:47:47.51613+00",
                  "2021-02-16 23:47:47.51613"}}
              ],
              transaction:
                {_lsn,
                 %Transaction{
                   changes: []
                 }}
            }} =
             Replication.handle_info(
               {:epgsql, "pid",
                {:x_log_data, 0, 0,
                 <<85, 0, 0, 104, 101, 79, 0, 5, 116, 0, 0, 0, 1, 51, 116, 0, 0, 0, 17, 83, 117,
                   112, 97, 98, 97, 115, 101, 32, 105, 115, 32, 103, 111, 111, 100, 33, 116, 0, 0,
                   0, 1, 49, 116, 0, 0, 0, 28, 50, 48, 50, 49, 45, 48, 50, 45, 49, 54, 32, 50, 51,
                   58, 52, 55, 58, 52, 55, 46, 53, 49, 54, 49, 51, 43, 48, 48, 116, 0, 0, 0, 25,
                   50, 48, 50, 49, 45, 48, 50, 45, 49, 54, 32, 50, 51, 58, 52, 55, 58, 52, 55, 46,
                   53, 49, 54, 49, 51, 78, 0, 5, 116, 0, 0, 0, 1, 51, 116, 0, 0, 0, 22, 78, 111,
                   44, 32, 83, 117, 112, 97, 98, 97, 115, 101, 32, 105, 115, 32, 103, 114, 101,
                   97, 116, 33, 116, 0, 0, 0, 1, 49, 116, 0, 0, 0, 28, 50, 48, 50, 49, 45, 48, 50,
                   45, 49, 54, 32, 50, 51, 58, 52, 55, 58, 52, 55, 46, 53, 49, 54, 49, 51, 43, 48,
                   48, 116, 0, 0, 0, 25, 50, 48, 50, 49, 45, 48, 50, 45, 49, 54, 32, 50, 51, 58,
                   52, 55, 58, 52, 55, 46, 53, 49, 54, 49, 51>>}},
               test_state
             )
  end

  test "transaction delete message", %{test_state: test_state} do
    test_state = %{
      test_state
      | transaction:
          {{0, 688_510_024},
           %Transaction{
             changes: [],
             commit_timestamp: %DateTime{
               calendar: Calendar.ISO,
               day: 16,
               hour: 23,
               microsecond: {518_844, 0},
               minute: 47,
               month: 2,
               second: 47,
               std_offset: 0,
               time_zone: "Etc/UTC",
               utc_offset: 0,
               year: 2021,
               zone_abbr: "UTC"
             }
           }}
    }

    assert {:noreply,
            %Replication.State{
              reverse_changes: [
                {26725, "DELETE", nil,
                 {"4", "See ya later!", "1", "2021-02-17 01:00:56.216654+00",
                  "2021-02-17 01:00:56.216654"}}
              ],
              transaction:
                {_lsn,
                 %Transaction{
                   changes: []
                 }}
            }} =
             Replication.handle_info(
               {:epgsql, "pid",
                {:x_log_data, 0, 0,
                 <<68, 0, 0, 104, 101, 79, 0, 5, 116, 0, 0, 0, 1, 52, 116, 0, 0, 0, 13, 83, 101,
                   101, 32, 121, 97, 32, 108, 97, 116, 101, 114, 33, 116, 0, 0, 0, 1, 49, 116, 0,
                   0, 0, 29, 50, 48, 50, 49, 45, 48, 50, 45, 49, 55, 32, 48, 49, 58, 48, 48, 58,
                   53, 54, 46, 50, 49, 54, 54, 53, 52, 43, 48, 48, 116, 0, 0, 0, 26, 50, 48, 50,
                   49, 45, 48, 50, 45, 49, 55, 32, 48, 49, 58, 48, 48, 58, 53, 54, 46, 50, 49, 54,
                   54, 53, 52>>}},
               test_state
             )
  end

  test "transaction truncate message" do
    test_state = %Replication.State{
      relations: %{
        16628 => %Relation{
          columns: @test_columns,
          id: 16628,
          name: "test",
          namespace: "public",
          replica_identity: :default
        }
      },
      reverse_changes: [],
      transaction:
        {{0, 50_302_656},
         %Realtime.Adapters.Changes.Transaction{
           changes: nil,
           commit_timestamp: %DateTime{
             calendar: Calendar.ISO,
             day: 2,
             hour: 3,
             microsecond: {0, 0},
             minute: 58,
             month: 4,
             second: 40,
             std_offset: 0,
             time_zone: "Etc/UTC",
             utc_offset: 0,
             year: 2021,
             zone_abbr: "UTC"
           }
         }}
    }

    assert {
             :noreply,
             %Replication.State{
               relations: %{
                 16628 => %Relation{
                   columns: @test_columns,
                   id: 16628,
                   name: "test",
                   namespace: "public",
                   replica_identity: :default
                 }
               },
               reverse_changes: [{16628, "TRUNCATE", nil, nil}],
               transaction:
                 {{0, 50_302_656},
                  %Transaction{
                    changes: nil,
                    commit_timestamp: %DateTime{
                      calendar: Calendar.ISO,
                      day: 2,
                      hour: 3,
                      microsecond: {0, 0},
                      minute: 58,
                      month: 4,
                      second: 40,
                      std_offset: 0,
                      time_zone: "Etc/UTC",
                      utc_offset: 0,
                      year: 2021,
                      zone_abbr: "UTC"
                    }
                  }},
               types: %{}
             }
           } =
             Replication.handle_info(
               {:epgsql, "pid", {:x_log_data, 0, 0, <<84, 0, 0, 0, 1, 3, 0, 0, 64, 244>>}},
               test_state
             )
  end

  test "transaction commit message", %{test_state: test_state} do
    test_state = %{
      test_state
      | transaction:
          {{0, 2_097_482_504},
           %Transaction{
             changes: [],
             commit_timestamp: %DateTime{
               calendar: Calendar.ISO,
               day: 22,
               hour: 02,
               microsecond: {0, 0},
               minute: 15,
               month: 2,
               second: 04,
               std_offset: 0,
               time_zone: "Etc/UTC",
               utc_offset: 0,
               year: 2021,
               zone_abbr: "UTC"
             }
           }}
    }

    {:noreply, insert_state} =
      Replication.handle_info(
        {:epgsql, "pid",
         {:x_log_data, 0, 0,
          <<73, 0, 0, 104, 101, 78, 0, 5, 116, 0, 0, 0, 1, 49, 116, 0, 0, 0, 10, 66, 111, 105,
            108, 32, 119, 97, 116, 101, 114, 116, 0, 0, 0, 1, 49, 116, 0, 0, 0, 29, 50, 48, 50,
            49, 45, 48, 50, 45, 50, 50, 32, 48, 50, 58, 49, 53, 58, 51, 57, 46, 57, 53, 48, 55,
            50, 54, 43, 48, 48, 116, 0, 0, 0, 26, 50, 48, 50, 49, 45, 48, 50, 45, 50, 50, 32, 48,
            50, 58, 49, 53, 58, 51, 57, 46, 57, 53, 48, 55, 50, 54>>}},
        test_state
      )

    assert {:noreply,
            %Replication.State{
              reverse_changes: [
                {26725, "INSERT",
                 {"2", "Cook ramen", "1", "2021-02-22 02:15:39.950726+00",
                  "2021-02-22 02:15:39.950726"}, nil},
                {26725, "INSERT",
                 {"1", "Boil water", "1", "2021-02-22 02:15:39.950726+00",
                  "2021-02-22 02:15:39.950726"}, nil}
              ],
              transaction:
                {_lsn,
                 %Transaction{
                   changes: [],
                   commit_timestamp: %DateTime{
                     calendar: Calendar.ISO,
                     day: 22,
                     hour: 02,
                     microsecond: {0, 0},
                     minute: 15,
                     month: 2,
                     second: 04,
                     std_offset: 0,
                     time_zone: "Etc/UTC",
                     utc_offset: 0,
                     year: 2021,
                     zone_abbr: "UTC"
                   }
                 }}
            }} =
             Replication.handle_info(
               {:epgsql, "pid",
                {:x_log_data, 0, 0,
                 <<73, 0, 0, 104, 101, 78, 0, 5, 116, 0, 0, 0, 1, 50, 116, 0, 0, 0, 10, 67, 111,
                   111, 107, 32, 114, 97, 109, 101, 110, 116, 0, 0, 0, 1, 49, 116, 0, 0, 0, 29,
                   50, 48, 50, 49, 45, 48, 50, 45, 50, 50, 32, 48, 50, 58, 49, 53, 58, 51, 57, 46,
                   57, 53, 48, 55, 50, 54, 43, 48, 48, 116, 0, 0, 0, 26, 50, 48, 50, 49, 45, 48,
                   50, 45, 50, 50, 32, 48, 50, 58, 49, 53, 58, 51, 57, 46, 57, 53, 48, 55, 50,
                   54>>}},
               insert_state
             )

    with_mocks([
      {
        SubscribersNotification,
        [],
        [
          notify: fn _txn -> :ok end
        ]
      },
      {
        EpgsqlServer,
        [],
        [
          acknowledge_lsn: fn _lsn -> :ok end
        ]
      }
    ]) do
      {:noreply,
       %Replication.State{
         relations: %{
           26725 => %Relation{
             columns: @test_columns,
             id: 26725,
             name: "todos",
             namespace: "public",
             replica_identity: :default
           }
         },
         reverse_changes: [],
         transaction: nil,
         types: %{}
       },
       :hibernate} =
        Replication.handle_info(
          {:epgsql, "pid",
           {:x_log_data, 0, 0,
            <<67, 0, 0, 0, 0, 0, 125, 5, 11, 8, 0, 0, 0, 0, 125, 5, 12, 240, 0, 2, 94, 226, 35,
              122, 94, 188>>}},
          insert_state
        )

      assert called(
               SubscribersNotification.notify(%Replication.State{
                 relations: %{
                   26725 => %Relation{
                     columns: @test_columns,
                     id: 26725,
                     name: "todos",
                     namespace: "public",
                     replica_identity: :default
                   }
                 },
                 reverse_changes: [],
                 transaction:
                   {{0, 2_097_482_504},
                    %Transaction{
                      changes: [
                        {26725, "INSERT",
                         {"1", "Boil water", "1", "2021-02-22 02:15:39.950726+00",
                          "2021-02-22 02:15:39.950726"}, nil}
                      ],
                      commit_timestamp: ~U[2021-02-22 02:15:04Z]
                    }},
                 types: %{}
               })
             )

      assert called(EpgsqlServer.acknowledge_lsn({0, 2_097_482_992}))
    end
  end

  test "Replication :: data_tuple_to_map/2 when columns and tuple_data inputs are correct" do
    assert %{
             "details" => "supabase launch week!",
             "id" => "1",
             "inserted_at_with_time_zone" => "2021-04-02T04:11:30.834234Z",
             "inserted_at_without_time_zone" => "2021-04-02T04:11:30.834234Z",
             "user_id" => "1"
           } =
             Replication.data_tuple_to_map(
               @test_columns,
               {"1", "supabase launch week!", "1", "2021-04-02 04:11:30.834234+00",
                "2021-04-02 04:11:30.834234"}
             )
  end

  test "Replication :: data_tuple_to_map/2 when columns and tuple_data inputs are mismatched" do
    assert %{
             "details" => "rain check",
             "id" => "1"
           } =
             Replication.data_tuple_to_map(
               @test_columns,
               {"1", "rain check"}
             )
  end

  test "Replication :: data_tuple_to_map/2 when columns is not list" do
    assert %{} = Replication.data_tuple_to_map(%{}, {})
  end

  test "Replication :: data_tuple_to_map/2 when tuple_data is not a tuple" do
    assert %{} = Replication.data_tuple_to_map(%{}, [])
  end
end
