# Adopted from https://github.com/phoenixframework/phoenix/blob/master/test/phoenix/socket/v1_json_serializer_test.exs and
# https://github.com/phoenixframework/phoenix/blob/master/test/phoenix/socket/v2_json_serializer_test.exs
# License: https://github.com/phoenixframework/phoenix/blob/master/LICENSE.md

defmodule Realtime.Socket.V1.JSONSerializerTest do
  use ExUnit.Case, async: true

  alias Phoenix.Socket.{Broadcast, Message, Reply}

  # v1 responses must not contain join_ref
  @serializer Realtime.Socket.V1.JSONSerializer
  @v1_msg_json "{\"event\":\"e\",\"payload\":\"m\",\"ref\":null,\"topic\":\"t\"}"
  @v1_reply_json "{\"event\":\"phx_reply\",\"payload\":{\"response\":null,\"status\":null},\"ref\":\"null\",\"topic\":\"t\"}"
  @v1_fastlane_json "{\"event\":\"e\",\"payload\":\"m\",\"ref\":null,\"topic\":\"t\"}"
  @broadcast <<
    # broadcast
    2::size(8),
    # topic_size
    5,
    # event_size
    5,
    "topic",
    "event",
    101,
    102,
    103
  >>

  def encode!(serializer, msg) do
    {:socket_push, :text, encoded} = serializer.encode!(msg)
    IO.iodata_to_binary(encoded)
  end

  def decode!(serializer, msg, opts), do: serializer.decode!(msg, opts)

  def fastlane!(serializer, msg) do
    case serializer.fastlane!(msg) do
      {:socket_push, :text, encoded} ->
        assert is_list(encoded)
        IO.iodata_to_binary(encoded)

      {:socket_push, :binary, encoded} ->
        assert is_binary(encoded)
        encoded
    end
  end

  test "encode!/1 encodes `Phoenix.Socket.Message` as JSON" do
    msg = %Message{topic: "t", event: "e", payload: "m"}
    assert encode!(@serializer, msg) == @v1_msg_json
  end

  test "encode!/1 encodes `Phoenix.Socket.Reply` as JSON" do
    msg = %Reply{topic: "t", ref: "null"}
    assert encode!(@serializer, msg) == @v1_reply_json
  end

  test "decode!/2 decodes `Phoenix.Socket.Message` from JSON" do
    assert %Message{topic: "t", event: "e", payload: "m"} ==
             decode!(@serializer, @v1_msg_json, opcode: :text)
  end

  test "fastlane!/1 encodes a broadcast into a message as JSON" do
    msg = %Broadcast{topic: "t", event: "e", payload: "m"}
    assert fastlane!(@serializer, msg) == @v1_fastlane_json
  end

  describe "binary encode" do
    test "fastlane" do
      assert fastlane!(@serializer, %Broadcast{
               topic: "topic",
               event: "event",
               payload: {:binary, <<101, 102, 103>>}
             }) == @broadcast
    end

    test "fastlane with oversized headers" do
      assert_raise ArgumentError, ~r/unable to convert topic to binary/, fn ->
        fastlane!(@serializer, %Broadcast{
          topic: String.duplicate("t", 256),
          event: "event",
          payload: {:binary, <<101, 102, 103>>}
        })
      end

      assert_raise ArgumentError, ~r/unable to convert event to binary/, fn ->
        fastlane!(@serializer, %Broadcast{
          topic: "topic",
          event: String.duplicate("e", 256),
          payload: {:binary, <<101, 102, 103>>}
        })
      end
    end
  end
end
