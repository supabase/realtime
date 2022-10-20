defmodule StreamTest do
  use ExUnit.Case, async: false
  alias Extensions.Postgres.Stream
  alias Realtime.Adapters.Postgres.Decoder

  alias Decoder.Messages.{
    Begin,
    Commit,
    Relation,
    Insert,
    Update,
    Delete,
    Truncate,
    Type
  }

  alias Realtime.Adapters.Changes.{
    DeletedRecord,
    NewRecord,
    UpdatedRecord
  }

  # test "data_tuple_to_map" do
  #   columns = [
  #     %Relation.Column{
  #       flags: [:key],
  #       name: "id",
  #       type: "int4",
  #       type_modifier: 4_294_967_295
  #     },
  #     %Relation.Column{
  #       flags: [],
  #       name: "details",
  #       type: "text",
  #       type_modifier: 4_294_967_295
  #     }
  #   ]

  #   tuple_data = {"1", "some details"}

  #   assert %{"id" => "1", "details" => "some details"} =
  #            Stream.data_tuple_to_map(columns, tuple_data)
  # end

  test "generate_record update" do
    columns = [
      %{name: "id", type: "int4"},
      %{name: "details", type: "text"}
    ]

    msg = %Update{
      relation_id: 16393,
      changed_key_tuple_data: nil,
      old_tuple_data: nil,
      tuple_data: {"1", "some details"}
    }

    tuple_data = {"1", "some details"}

    assert %UpdatedRecord{
             columns: [
               %{name: "id", type: "int4"},
               %{name: "details", type: "text"}
             ],
             commit_timestamp: "2022-10-11T17:53:36Z",
             errors: nil,
             schema: "public",
             table: "test",
             # %{"id" => 1},
             old_record: nil,
             record: %{"details" => "some details", "id" => "1"},
             type: "UPDATE"
           } = Stream.generate_record(msg, columns, "public", "test")
  end
end
