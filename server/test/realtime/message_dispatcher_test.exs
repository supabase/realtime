defmodule Realtime.MessageDispatcherTest do
  use ExUnit.Case
  import Realtime.MessageDispatcher
  alias Phoenix.Socket.Broadcast
  alias Phoenix.Socket.V1.JSONSerializer
  alias Realtime.Adapters.Changes.NewRecord

  @subscription_id <<187, 181, 30, 78, 243, 113, 68, 99, 191, 10, 175, 143, 86, 220, 154, 115>>

  test "dispatch/3 for subscriber_fastlane when subscription_ids is empty" do
    msg = msg([])

    dispatch(
      [{self(), {:subscriber_fastlane, self(), JSONSerializer, @subscription_id}}],
      self(),
      msg
    )

    expected = JSONSerializer.fastlane!(msg)
    refute_received ^expected
  end

  test "dispatch/3 for subscriber_fastlane when subscription_id in subscription_ids" do
    msg = msg(MapSet.new([@subscription_id]))

    dispatch(
      [{self(), {:subscriber_fastlane, self(), JSONSerializer, @subscription_id}}],
      self(),
      msg
    )

    expected = JSONSerializer.fastlane!(msg)
    assert_received ^expected
  end

  test "dispatch/3 for subscriber_fastlane when subscription_id not in subscription_ids" do
    msg = msg(MapSet.new([@subscription_id]))

    other_subscription_id =
      <<160, 66, 132, 13, 21, 219, 69, 221, 164, 160, 40, 72, 156, 208, 114, 4>>

    dispatch(
      [{self(), {:subscriber_fastlane, self(), JSONSerializer, other_subscription_id}}],
      self(),
      msg
    )

    expected = JSONSerializer.fastlane!(msg)
    refute_received ^expected
  end

  @spec msg(list) :: map()
  defp msg(subscription_ids) do
    %Broadcast{
      event: "INSERT",
      payload: %NewRecord{
        columns: [
          %{"name" => "id", "type" => "int8"},
          %{"name" => "details", "type" => "text"},
          %{"name" => "user_id", "type" => "int8"}
        ],
        commit_timestamp: "2021-11-05T09:45:40.512962+00:00",
        errors: nil,
        schema: "public",
        table: "todos",
        record: %{
          "details" =>
            "programming the interface won't do anything, we need to quantify the primary SMS feed!",
          "id" => 32,
          "user_id" => 1
        },
        subscription_ids: MapSet.new(subscription_ids),
        type: "INSERT"
      },
      topic: "realtime:public:todos"
    }
  end
end
