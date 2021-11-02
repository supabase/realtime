defmodule Realtime.ReplicationTest do
  use ExUnit.Case

  import Mock

  alias Realtime.Replication
  alias Realtime.Adapters.Changes.{Transaction, NewRecord, UpdatedRecord, DeletedRecord}
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
      transaction: nil,
      types: %{}
    }

    {:ok, test_state: test_state}
  end

  test "Integration Test: 0.2.0" do
    assert {:noreply,
            %Replication.State{
              relations: %{
                16386 => %Relation{
                  columns: [
                    %Relation.Column{
                      flags: [:key],
                      name: "id",
                      type: "int8",
                      type_modifier: 4_294_967_295
                    },
                    %Relation.Column{
                      flags: [],
                      name: "first_name",
                      type: "text",
                      type_modifier: 4_294_967_295
                    },
                    %Relation.Column{
                      flags: [],
                      name: "last_name",
                      type: "text",
                      type_modifier: 4_294_967_295
                    },
                    %Relation.Column{
                      flags: [],
                      name: "info",
                      type: "jsonb",
                      type_modifier: 4_294_967_295
                    },
                    %Relation.Column{
                      flags: [],
                      name: "inserted_at",
                      type: "timestamp",
                      type_modifier: 4_294_967_295
                    },
                    %Relation.Column{
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
              transaction: nil,
              types: %{}
            }} =
             Replication.handle_info(
               {:epgsql, 0,
                {:x_log_data, 0, 0,
                 <<82, 0, 0, 64, 2, 112, 117, 98, 108, 105, 99, 0, 117, 115, 101, 114, 115, 0,
                   100, 0, 6, 1, 105, 100, 0, 0, 0, 0, 20, 255, 255, 255, 255, 0, 102, 105, 114,
                   115, 116, 95, 110, 97, 109, 101, 0, 0, 0, 0, 25, 255, 255, 255, 255, 0, 108,
                   97, 115, 116, 95, 110, 97, 109, 101, 0, 0, 0, 0, 25, 255, 255, 255, 255, 0,
                   105, 110, 102, 111, 0, 0, 0, 14, 218, 255, 255, 255, 255, 0, 105, 110, 115,
                   101, 114, 116, 101, 100, 95, 97, 116, 0, 0, 0, 4, 90, 255, 255, 255, 255, 0,
                   117, 112, 100, 97, 116, 101, 100, 95, 97, 116, 0, 0, 0, 4, 90, 255, 255, 255,
                   255>>}},
               %Replication.State{}
             )
  end

  test "insert record with data type conversion", %{test_state: test_state} do
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

    {:noreply,
     %Replication.State{
       transaction: {_lsn, %{changes: [%NewRecord{record: record}]}}
     }} =
      Replication.handle_info(
        {:epgsql, "pid",
         {:x_log_data, 0, 0,
          <<73, 0, 0, 104, 101, 78, 0, 5, 116, 0, 0, 0, 1, 51, 116, 0, 0, 0, 17, 83, 117, 112, 97,
            98, 97, 115, 101, 32, 105, 115, 32, 103, 111, 111, 100, 33, 116, 0, 0, 0, 1, 49, 116,
            0, 0, 0, 28, 50, 48, 50, 49, 45, 48, 50, 45, 49, 54, 32, 50, 51, 58, 52, 55, 58, 52,
            55, 46, 53, 49, 54, 49, 51, 43, 48, 48, 116, 0, 0, 0, 25, 50, 48, 50, 49, 45, 48, 50,
            45, 49, 54, 32, 50, 51, 58, 52, 55, 58, 52, 55, 46, 53, 49, 54, 49, 51>>}},
        test_state
      )

    assert %{
             "details" => "Supabase is good!",
             "id" => "3",
             "inserted_at_with_time_zone" => "2021-02-16T23:47:47.51613Z",
             "inserted_at_without_time_zone" => "2021-02-16T23:47:47.51613Z",
             "user_id" => "1"
           } = record
  end

  test "update record with data type conversion", %{test_state: test_state} do
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

    {:noreply,
     %Replication.State{
       transaction:
         {_lsn,
          %{
            changes: [
              %UpdatedRecord{old_record: old_record, record: record}
            ]
          }}
     }} =
      Replication.handle_info(
        {:epgsql, "pid",
         {:x_log_data, 0, 0,
          <<85, 0, 0, 104, 101, 79, 0, 5, 116, 0, 0, 0, 1, 51, 116, 0, 0, 0, 17, 83, 117, 112, 97,
            98, 97, 115, 101, 32, 105, 115, 32, 103, 111, 111, 100, 33, 116, 0, 0, 0, 1, 49, 116,
            0, 0, 0, 28, 50, 48, 50, 49, 45, 48, 50, 45, 49, 54, 32, 50, 51, 58, 52, 55, 58, 52,
            55, 46, 53, 49, 54, 49, 51, 43, 48, 48, 116, 0, 0, 0, 25, 50, 48, 50, 49, 45, 48, 50,
            45, 49, 54, 32, 50, 51, 58, 52, 55, 58, 52, 55, 46, 53, 49, 54, 49, 51, 78, 0, 5, 116,
            0, 0, 0, 1, 51, 116, 0, 0, 0, 22, 78, 111, 44, 32, 83, 117, 112, 97, 98, 97, 115, 101,
            32, 105, 115, 32, 103, 114, 101, 97, 116, 33, 116, 0, 0, 0, 1, 49, 116, 0, 0, 0, 28,
            50, 48, 50, 49, 45, 48, 50, 45, 49, 54, 32, 50, 51, 58, 52, 55, 58, 52, 55, 46, 53,
            49, 54, 49, 51, 43, 48, 48, 116, 0, 0, 0, 25, 50, 48, 50, 49, 45, 48, 50, 45, 49, 54,
            32, 50, 51, 58, 52, 55, 58, 52, 55, 46, 53, 49, 54, 49, 51>>}},
        test_state
      )

    assert %{
             "details" => "Supabase is good!",
             "id" => "3",
             "inserted_at_with_time_zone" => "2021-02-16T23:47:47.51613Z",
             "inserted_at_without_time_zone" => "2021-02-16T23:47:47.51613Z",
             "user_id" => "1"
           } = old_record

    assert %{
             "details" => "No, Supabase is great!",
             "id" => "3",
             "inserted_at_with_time_zone" => "2021-02-16T23:47:47.51613Z",
             "inserted_at_without_time_zone" => "2021-02-16T23:47:47.51613Z",
             "user_id" => "1"
           } = record
  end

  test "delete record with data type conversion", %{test_state: test_state} do
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

    {:noreply,
     %Replication.State{
       transaction:
         {_lsn,
          %{
            changes: [
              %DeletedRecord{old_record: old_record}
            ]
          }}
     }} =
      Replication.handle_info(
        {:epgsql, "pid",
         {:x_log_data, 0, 0,
          <<68, 0, 0, 104, 101, 79, 0, 5, 116, 0, 0, 0, 1, 52, 116, 0, 0, 0, 13, 83, 101, 101, 32,
            121, 97, 32, 108, 97, 116, 101, 114, 33, 116, 0, 0, 0, 1, 49, 116, 0, 0, 0, 29, 50,
            48, 50, 49, 45, 48, 50, 45, 49, 55, 32, 48, 49, 58, 48, 48, 58, 53, 54, 46, 50, 49,
            54, 54, 53, 52, 43, 48, 48, 116, 0, 0, 0, 26, 50, 48, 50, 49, 45, 48, 50, 45, 49, 55,
            32, 48, 49, 58, 48, 48, 58, 53, 54, 46, 50, 49, 54, 54, 53, 52>>}},
        test_state
      )

    assert %{
             "details" => "See ya later!",
             "id" => "4",
             "inserted_at_with_time_zone" => "2021-02-17T01:00:56.216654Z",
             "inserted_at_without_time_zone" => "2021-02-17T01:00:56.216654Z",
             "user_id" => "1"
           } = old_record
  end

  test "commit record", %{test_state: test_state} do
    expected_commit_timestamp = %DateTime{
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

    test_state = %{
      test_state
      | transaction:
          {{0, 2_097_482_504},
           %Transaction{changes: [], commit_timestamp: expected_commit_timestamp}}
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

    {:noreply,
     %Replication.State{transaction: {_lsn, %Transaction{changes: changes}}} = insert_state} =
      Replication.handle_info(
        {:epgsql, "pid",
         {:x_log_data, 0, 0,
          <<73, 0, 0, 104, 101, 78, 0, 5, 116, 0, 0, 0, 1, 50, 116, 0, 0, 0, 10, 67, 111, 111,
            107, 32, 114, 97, 109, 101, 110, 116, 0, 0, 0, 1, 49, 116, 0, 0, 0, 29, 50, 48, 50,
            49, 45, 48, 50, 45, 50, 50, 32, 48, 50, 58, 49, 53, 58, 51, 57, 46, 57, 53, 48, 55,
            50, 54, 43, 48, 48, 116, 0, 0, 0, 26, 50, 48, 50, 49, 45, 48, 50, 45, 50, 50, 32, 48,
            50, 58, 49, 53, 58, 51, 57, 46, 57, 53, 48, 55, 50, 54>>}},
        insert_state
      )

    assert [
             %NewRecord{
               record: %{
                 "details" => "Cook ramen",
                 "id" => "2",
                 "inserted_at_with_time_zone" => "2021-02-22T02:15:39.950726Z",
                 "inserted_at_without_time_zone" => "2021-02-22T02:15:39.950726Z",
                 "user_id" => "1"
               }
             },
             %NewRecord{
               record: %{
                 "details" => "Boil water",
                 "id" => "1",
                 "inserted_at_with_time_zone" => "2021-02-22T02:15:39.950726Z",
                 "inserted_at_without_time_zone" => "2021-02-22T02:15:39.950726Z",
                 "user_id" => "1"
               }
             }
           ] = changes

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
      {:noreply, commit_state} =
        Replication.handle_info(
          {:epgsql, "pid",
           {:x_log_data, 0, 0,
            <<67, 0, 0, 0, 0, 0, 125, 5, 11, 8, 0, 0, 0, 0, 125, 5, 12, 240, 0, 2, 94, 226, 35,
              122, 94, 188>>}},
          insert_state
        )

      assert called(
               SubscribersNotification.notify(%Transaction{
                 commit_timestamp: expected_commit_timestamp,
                 changes: [
                   %NewRecord{
                     columns: @test_columns,
                     commit_timestamp: expected_commit_timestamp,
                     record: %{
                       "details" => "Boil water",
                       "id" => "1",
                       "inserted_at_with_time_zone" => "2021-02-22T02:15:39.950726Z",
                       "inserted_at_without_time_zone" => "2021-02-22T02:15:39.950726Z",
                       "user_id" => "1"
                     },
                     schema: "public",
                     table: "todos",
                     type: "INSERT",
                     is_rls_enabled: false
                   },
                   %NewRecord{
                     columns: @test_columns,
                     commit_timestamp: expected_commit_timestamp,
                     record: %{
                       "details" => "Cook ramen",
                       "id" => "2",
                       "inserted_at_with_time_zone" => "2021-02-22T02:15:39.950726Z",
                       "inserted_at_without_time_zone" => "2021-02-22T02:15:39.950726Z",
                       "user_id" => "1"
                     },
                     schema: "public",
                     table: "todos",
                     type: "INSERT",
                     is_rls_enabled: false
                   }
                 ]
               })
             )

      assert called(EpgsqlServer.acknowledge_lsn({0, 2_097_482_992}))

      assert %Replication.State{transaction: nil} = commit_state
    end
  end
end
