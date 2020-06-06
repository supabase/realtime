defmodule Realtime.ReplicationTest do
  use ExUnit.Case

  doctest Realtime.Replication, import: true

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
end
