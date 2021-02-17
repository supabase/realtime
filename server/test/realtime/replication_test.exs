defmodule Realtime.ReplicationTest do
  use ExUnit.Case

  alias Realtime.Replication

  doctest Replication, import: true

  setup do
    test_state = %Replication.State{
      config: [],
      connection: "pid",
      relations: %{
        26725 => %Realtime.Decoder.Messages.Relation{
          columns: [
            %Realtime.Decoder.Messages.Relation.Column{
              flags: [:key],
              name: "id",
              type: "int8",
              type_modifier: 4_294_967_295
            },
            %Realtime.Decoder.Messages.Relation.Column{
              flags: [],
              name: "details",
              type: "text",
              type_modifier: 4_294_967_295
            },
            %Realtime.Decoder.Messages.Relation.Column{
              flags: [],
              name: "user_id",
              type: "int8",
              type_modifier: 4_294_967_295
            },
            %Realtime.Decoder.Messages.Relation.Column{
              flags: [],
              name: "inserted_at_with_time_zone",
              type: "timestamptz",
              type_modifier: 4_294_967_295
            },
            %Realtime.Decoder.Messages.Relation.Column{
              flags: [],
              name: "inserted_at_without_time_zone",
              type: "timestamp",
              type_modifier: 4_294_967_295
            }
          ],
          id: 26725,
          name: "todos",
          namespace: "public",
          replica_identity: :default
        }
      },
      subscribers: [],
      transaction:
        {{0, 688_510_024},
         %Realtime.Adapters.Changes.Transaction{
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
         }},
      types: %{}
    }

    {:ok, test_state: test_state}
  end

  test "Integration Test: 0.2.0" do
    assert Replication.handle_info(
             {:epgsql, 0,
              {:x_log_data, 0, 0,
               <<82, 0, 0, 64, 2, 112, 117, 98, 108, 105, 99, 0, 117, 115, 101, 114, 115, 0, 100,
                 0, 6, 1, 105, 100, 0, 0, 0, 0, 20, 255, 255, 255, 255, 0, 102, 105, 114, 115,
                 116, 95, 110, 97, 109, 101, 0, 0, 0, 0, 25, 255, 255, 255, 255, 0, 108, 97, 115,
                 116, 95, 110, 97, 109, 101, 0, 0, 0, 0, 25, 255, 255, 255, 255, 0, 105, 110, 102,
                 111, 0, 0, 0, 14, 218, 255, 255, 255, 255, 0, 105, 110, 115, 101, 114, 116, 101,
                 100, 95, 97, 116, 0, 0, 0, 4, 90, 255, 255, 255, 255, 0, 117, 112, 100, 97, 116,
                 101, 100, 95, 97, 116, 0, 0, 0, 4, 90, 255, 255, 255, 255>>}},
             %Replication.State{}
           ) ==
             {:noreply,
              %Replication.State{
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

  test "insert record with data type conversion", %{test_state: test_state} do
    {:noreply,
     %Replication.State{
       transaction: {_lsn, %{changes: [%Realtime.Adapters.Changes.NewRecord{record: record}]}}
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

    assert record == %{
             "details" => "Supabase is good!",
             "id" => "3",
             "inserted_at_with_time_zone" => "2021-02-16T23:47:47.51613Z",
             "inserted_at_without_time_zone" => "2021-02-16T23:47:47.51613Z",
             "user_id" => "1"
           }
  end

  test "update record with data type conversion", %{test_state: test_state} do
    {:noreply,
     %Replication.State{
       transaction:
         {_lsn,
          %{
            changes: [
              %Realtime.Adapters.Changes.UpdatedRecord{old_record: old_record, record: record}
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

    assert old_record == %{
             "details" => "Supabase is good!",
             "id" => "3",
             "inserted_at_with_time_zone" => "2021-02-16T23:47:47.51613Z",
             "inserted_at_without_time_zone" => "2021-02-16T23:47:47.51613Z",
             "user_id" => "1"
           }

    assert record == %{
             "details" => "No, Supabase is great!",
             "id" => "3",
             "inserted_at_with_time_zone" => "2021-02-16T23:47:47.51613Z",
             "inserted_at_without_time_zone" => "2021-02-16T23:47:47.51613Z",
             "user_id" => "1"
           }
  end

  test "delete record with data type conversion", %{test_state: test_state} do
    {:noreply,
     %Replication.State{
       transaction:
         {_lsn,
          %{
            changes: [
              %Realtime.Adapters.Changes.DeletedRecord{old_record: old_record}
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

    assert old_record == %{
             "details" => "See ya later!",
             "id" => "4",
             "inserted_at_with_time_zone" => "2021-02-17T01:00:56.216654Z",
             "inserted_at_without_time_zone" => "2021-02-17T01:00:56.216654Z",
             "user_id" => "1"
           }
  end
end
