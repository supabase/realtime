defmodule Realtime.MessageDispatcherTest do
  use ExUnit.Case
  import Realtime.MessageDispatcher
  alias Phoenix.Socket.Broadcast
  alias Phoenix.Socket.V1.JSONSerializer
  alias Realtime.Adapters.Changes.NewRecord

  @subscription_id "417e76fd-9bc5-4b3e-bd5d-a031389c4a6b"

  test "dispatch/3 for subscriber_fastlane when subscription_id in subscription_ids" do
    msg = %Broadcast{
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
        type: "INSERT"
      },
      topic: "test"
    }

    dispatch(
      [
        {self(),
         {:subscriber_fastlane, self(), JSONSerializer, @subscription_id, "test", "*", false}}
      ],
      self(),
      msg
    )

    expected = JSONSerializer.fastlane!(msg)
    assert_received ^expected
  end
end
