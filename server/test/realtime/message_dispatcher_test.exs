defmodule Realtime.MessageDispatcherTest do
  use ExUnit.Case
  import Realtime.MessageDispatcher
  alias Phoenix.Socket.V1.JSONSerializer

  @user_id <<187, 181, 30, 78, 243, 113, 68, 99, 191, 10, 175, 143, 86, 220, 154, 115>>

  test "dispatch/3 for user_fastlane when rls disabled and no users" do
    msg = msg(false, [])
    dispatch([{self(), {:user_fastlane, self(), JSONSerializer, ""}}], self(), msg)
    expected = JSONSerializer.fastlane!(msg)
    assert_received ^expected
  end

  test "dispatch/3 for user_fastlane when rls enabled and user in users" do
    msg = msg(true, MapSet.new([@user_id]))
    dispatch([{self(), {:user_fastlane, self(), JSONSerializer, @user_id}}], self(), msg)
    expected = JSONSerializer.fastlane!(msg)
    assert_received ^expected
  end

  test "dispatch/3 for user_fastlane when rls enabled and user not in users" do
    msg = msg(true, MapSet.new([@user_id]))
    dispatch([{self(), {:user_fastlane, self(), JSONSerializer, "wrong_user_id"}}], self(), msg)
    expected = JSONSerializer.fastlane!(msg)
    refute_receive ^expected
  end

  test "dispatch/3 for fastlane when rls enabled" do
    msg = msg(true, [])
    dispatch([{self(), {:fastlane, self(), JSONSerializer, ""}}], self(), msg)
    expected = JSONSerializer.fastlane!(msg)
    refute_receive ^expected
  end

  test "dispatch/3 for fastlane when rls disabled" do
    msg = msg(false, [])
    dispatch([{self(), {:fastlane, self(), JSONSerializer, ""}}], self(), msg)
    expected = JSONSerializer.fastlane!(msg)
    assert_received ^expected
  end

  @spec msg(atom, list) :: map()
  defp msg(rls, users) do
    %Phoenix.Socket.Broadcast{
      event: "INSERT",
      payload: %Realtime.Adapters.Changes.NewRecord{
        columns: [
          %{"name" => "id", "type" => "int8"},
          %{"name" => "details", "type" => "text"},
          %{"name" => "user_id", "type" => "int8"}
        ],
        commit_timestamp: "2021-11-05T09:45:40.512962+00:00",
        is_rls_enabled: rls,
        record: %{
          "details" =>
            "programming the interface won't do anything, we need to quantify the primary SMS feed!",
          "id" => 32,
          "user_id" => 1
        },
        schema: "public",
        table: "todos",
        type: "INSERT",
        users: users
      },
      topic: "realtime:public:todos"
    }
  end
end
