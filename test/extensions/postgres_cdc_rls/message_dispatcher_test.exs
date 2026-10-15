defmodule Extensions.PostgresCdcRls.MessageDispatcherTest do
  use ExUnit.Case, async: true

  alias Extensions.PostgresCdcRls.MessageDispatcher
  alias Phoenix.Socket.Broadcast

  defmodule FakeSerializer do
    def fastlane!(msg), do: {:encoded, msg}
  end

  defmodule CountingSerializer do
    def fastlane!(msg) do
      send(self(), :encoded_message)
      {:encoded, msg}
    end
  end

  describe "dispatch/3" do
    test "uses each subscriber's serializer when the outgoing messages match" do
      parent = self()
      topic = "realtime:topic"
      data = %{"schema" => "public", "table" => "todos", "type" => "INSERT", "record" => %{"id" => 1}}
      payload = Jason.encode!(data)
      sub_ids = MapSet.new(["sub_v1", "sub_v2"])

      for serializers <- [
            [Phoenix.Socket.V1.JSONSerializer, RealtimeWeb.Socket.V2Serializer],
            [RealtimeWeb.Socket.V2Serializer, Phoenix.Socket.V1.JSONSerializer]
          ],
          new_api? <- [true, false] do
        subscriptions =
          Enum.map(serializers, fn serializer ->
            fastlane_pid =
              spawn(fn ->
                receive do
                  {:socket_push, :text, frame} -> send(parent, {serializer, Jason.decode!(IO.iodata_to_binary(frame))})
                end
              end)

            sub_id = if serializer == Phoenix.Socket.V1.JSONSerializer, do: "sub_v1", else: "sub_v2"
            {self(), {:subscriber_fastlane, fastlane_pid, serializer, [{sub_id, 1}], topic, new_api?}}
          end)

        assert :ok = MessageDispatcher.dispatch(subscriptions, self(), {"INSERT", payload, sub_ids})

        event = if new_api?, do: "postgres_changes", else: "INSERT"
        expected_payload = if new_api?, do: %{"ids" => [1], "data" => data}, else: data

        assert_receive {Phoenix.Socket.V1.JSONSerializer,
                        %{"topic" => ^topic, "event" => ^event, "payload" => ^expected_payload, "ref" => nil}}

        assert_receive {RealtimeWeb.Socket.V2Serializer, [nil, nil, ^topic, ^event, ^expected_payload]}
      end
    end

    test "dispatches to fastlane subscribers with matching sub_ids using new api" do
      parent = self()

      fastlane_pid =
        spawn(fn ->
          receive do
            msg -> send(parent, {:received, msg})
          end
        end)

      sub_ids = MapSet.new(["sub_1"])
      ids = [{"sub_1", 1}]

      subscriptions = [
        {self(), {:subscriber_fastlane, fastlane_pid, FakeSerializer, ids, "realtime:topic", true}}
      ]

      payload = Jason.encode!(%{data: "test"})

      assert :ok = MessageDispatcher.dispatch(subscriptions, self(), {"INSERT", payload, sub_ids})

      assert_receive {:received, {:encoded, %Broadcast{topic: "realtime:topic", event: "postgres_changes"}}}
    end

    test "dispatches to fastlane subscribers with matching sub_ids using old api" do
      parent = self()

      fastlane_pid =
        spawn(fn ->
          receive do
            msg -> send(parent, {:received, msg})
          end
        end)

      sub_ids = MapSet.new(["sub_1"])
      ids = [{"sub_1", 1}]

      subscriptions = [
        {self(), {:subscriber_fastlane, fastlane_pid, FakeSerializer, ids, "realtime:topic", false}}
      ]

      payload = Jason.encode!(%{data: "test"})

      assert :ok = MessageDispatcher.dispatch(subscriptions, self(), {"INSERT", payload, sub_ids})

      assert_receive {:received, {:encoded, %Broadcast{topic: "realtime:topic", event: "INSERT"}}}
    end

    test "does not dispatch when sub_ids do not match" do
      parent = self()

      fastlane_pid =
        spawn(fn ->
          receive do
            msg -> send(parent, {:received, msg})
          after
            1000 -> :ok
          end
        end)

      sub_ids = MapSet.new(["sub_2"])
      ids = [{"sub_1", 1}]

      subscriptions = [
        {self(), {:subscriber_fastlane, fastlane_pid, FakeSerializer, ids, "realtime:topic", true}}
      ]

      assert :ok = MessageDispatcher.dispatch(subscriptions, self(), {"INSERT", "payload", sub_ids})

      refute_receive {:received, _}
    end

    test "caches encoded messages across multiple subscribers" do
      parent = self()

      pids =
        for _ <- 1..2 do
          spawn(fn ->
            receive do
              msg -> send(parent, {:received, msg})
            end
          end)
        end

      sub_ids = MapSet.new(["sub_1"])
      ids = [{"sub_1", 1}]

      subscriptions =
        Enum.map(pids, fn pid ->
          {self(), {:subscriber_fastlane, pid, CountingSerializer, ids, "realtime:topic", true}}
        end)

      assert :ok = MessageDispatcher.dispatch(subscriptions, self(), {"INSERT", "payload", sub_ids})

      assert_receive {:received, {:encoded, %Broadcast{}}}
      assert_receive {:received, {:encoded, %Broadcast{}}}
      assert_receive :encoded_message
      refute_receive :encoded_message
    end
  end
end
