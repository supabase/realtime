defmodule PostgresDecoderTest do
  use ExUnit.Case
  alias Realtime.Adapters.Postgres.Decoder

  alias Decoder.Messages.{
    Begin,
    Commit,
    Origin,
    Relation,
    Relation.Column,
    Insert,
    Update,
    Delete,
    Truncate,
    Type
  }

  test "decodes begin messages" do
    {:ok, expected_dt_no_microseconds, 0} = DateTime.from_iso8601("2019-07-18T17:02:35Z")
    expected_dt = DateTime.add(expected_dt_no_microseconds, 726_322, :microsecond)

    assert Decoder.decode_message(
             <<66, 0, 0, 0, 2, 167, 244, 168, 128, 0, 2, 48, 246, 88, 88, 213, 242, 0, 0, 2, 107>>
           ) == %Begin{commit_timestamp: expected_dt, final_lsn: {2, 2_817_828_992}, xid: 619}
  end

  test "decodes commit messages" do
    {:ok, expected_dt_no_microseconds, 0} = DateTime.from_iso8601("2019-07-18T17:02:35Z")
    expected_dt = DateTime.add(expected_dt_no_microseconds, 726_322, :microsecond)

    assert Decoder.decode_message(
             <<67, 0, 0, 0, 0, 2, 167, 244, 168, 128, 0, 0, 0, 2, 167, 244, 168, 176, 0, 2, 48,
               246, 88, 88, 213, 242>>
           ) == %Commit{
             flags: [],
             lsn: {2, 2_817_828_992},
             end_lsn: {2, 2_817_829_040},
             commit_timestamp: expected_dt
           }
  end

  test "decodes origin messages" do
    assert Decoder.decode_message(<<79, 0, 0, 0, 2, 167, 244, 168, 128>> <> "Elmer Fud") ==
             %Origin{
               origin_commit_lsn: {2, 2_817_828_992},
               name: "Elmer Fud"
             }
  end

  test "decodes relation messages" do
    assert Decoder.decode_message(
             <<82, 0, 0, 96, 0, 112, 117, 98, 108, 105, 99, 0, 102, 111, 111, 0, 100, 0, 2, 0, 98,
               97, 114, 0, 0, 0, 0, 25, 255, 255, 255, 255, 1, 105, 100, 0, 0, 0, 0, 23, 255, 255,
               255, 255>>
           ) == %Relation{
             id: 24_576,
             namespace: "public",
             name: "foo",
             replica_identity: :default,
             columns: [
               %Column{
                 flags: [],
                 name: "bar",
                 type: "text",
                 type_modifier: 4_294_967_295
               },
               %Column{
                 flags: [:key],
                 name: "id",
                 type: "int4",
                 type_modifier: 4_294_967_295
               }
             ]
           }
  end

  test "decodes type messages" do
    assert Decoder.decode_message(
             <<89, 0, 0, 128, 52, 112, 117, 98, 108, 105, 99, 0, 101, 120, 97, 109, 112, 108, 101,
               95, 116, 121, 112, 101, 0>>
           ) ==
             %Type{
               id: 32_820,
               namespace: "public",
               name: "example_type"
             }
  end

  describe "truncate messages" do
    test "decodes messages" do
      assert Decoder.decode_message(<<84, 0, 0, 0, 1, 0, 0, 0, 96, 0>>) ==
               %Truncate{
                 number_of_relations: 1,
                 options: [],
                 truncated_relations: [24_576]
               }
    end

    test "decodes messages with cascade option" do
      assert Decoder.decode_message(<<84, 0, 0, 0, 1, 1, 0, 0, 96, 0>>) ==
               %Truncate{
                 number_of_relations: 1,
                 options: [:cascade],
                 truncated_relations: [24_576]
               }
    end

    test "decodes messages with restart identity option" do
      assert Decoder.decode_message(<<84, 0, 0, 0, 1, 2, 0, 0, 96, 0>>) ==
               %Truncate{
                 number_of_relations: 1,
                 options: [:restart_identity],
                 truncated_relations: [24_576]
               }
    end
  end

  describe "data message (TupleData) decoder" do
    test "decodes insert messages" do
      assert Decoder.decode_message(
               <<73, 0, 0, 96, 0, 78, 0, 2, 116, 0, 0, 0, 3, 98, 97, 122, 116, 0, 0, 0, 3, 53, 54,
                 48>>
             ) == %Insert{
               relation_id: 24_576,
               tuple_data: {"baz", "560"}
             }
    end

    test "decodes insert messages with null values" do
      assert Decoder.decode_message(
               <<73, 0, 0, 96, 0, 78, 0, 2, 110, 116, 0, 0, 0, 3, 53, 54, 48>>
             ) == %Insert{
               relation_id: 24_576,
               tuple_data: {nil, "560"}
             }
    end

    test "decodes insert messages with unchanged toasted values" do
      assert Decoder.decode_message(
               <<73, 0, 0, 96, 0, 78, 0, 2, 117, 116, 0, 0, 0, 3, 53, 54, 48>>
             ) == %Insert{
               relation_id: 24_576,
               tuple_data: {:unchanged_toast, "560"}
             }
    end

    test "decodes update messages with default replica identity setting" do
      assert Decoder.decode_message(
               <<85, 0, 0, 96, 0, 78, 0, 2, 116, 0, 0, 0, 7, 101, 120, 97, 109, 112, 108, 101,
                 116, 0, 0, 0, 3, 53, 54, 48>>
             ) == %Update{
               relation_id: 24_576,
               changed_key_tuple_data: nil,
               old_tuple_data: nil,
               tuple_data: {"example", "560"}
             }
    end

    test "decodes update messages with FULL replica identity setting" do
      assert Decoder.decode_message(
               <<85, 0, 0, 96, 0, 79, 0, 2, 116, 0, 0, 0, 3, 98, 97, 122, 116, 0, 0, 0, 3, 53, 54,
                 48, 78, 0, 2, 116, 0, 0, 0, 7, 101, 120, 97, 109, 112, 108, 101, 116, 0, 0, 0, 3,
                 53, 54, 48>>
             ) == %Update{
               relation_id: 24_576,
               changed_key_tuple_data: nil,
               old_tuple_data: {"baz", "560"},
               tuple_data: {"example", "560"}
             }
    end

    test "decodes update messages with USING INDEX replica identity setting" do
      assert Decoder.decode_message(
               <<85, 0, 0, 96, 0, 75, 0, 2, 116, 0, 0, 0, 3, 98, 97, 122, 110, 78, 0, 2, 116, 0,
                 0, 0, 7, 101, 120, 97, 109, 112, 108, 101, 116, 0, 0, 0, 3, 53, 54, 48>>
             ) == %Update{
               relation_id: 24_576,
               changed_key_tuple_data: {"baz", nil},
               old_tuple_data: nil,
               tuple_data: {"example", "560"}
             }
    end

    test "decodes DELETE messages with USING INDEX replica identity setting" do
      assert Decoder.decode_message(
               <<68, 0, 0, 96, 0, 75, 0, 2, 116, 0, 0, 0, 7, 101, 120, 97, 109, 112, 108, 101,
                 110>>
             ) == %Delete{
               relation_id: 24_576,
               changed_key_tuple_data: {"example", nil}
             }
    end

    test "decodes DELETE messages with FULL replica identity setting" do
      assert Decoder.decode_message(
               <<68, 0, 0, 96, 0, 79, 0, 2, 116, 0, 0, 0, 3, 98, 97, 122, 116, 0, 0, 0, 3, 53, 54,
                 48>>
             ) == %Delete{
               relation_id: 24_576,
               old_tuple_data: {"baz", "560"}
             }
    end
  end
end
