defmodule RealtimeWeb.RealtimeChannel.MessageDispatcherTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Phoenix.Socket.Broadcast
  alias Phoenix.Socket.V1
  alias RealtimeWeb.RealtimeChannel.MessageDispatcher
  alias RealtimeWeb.Socket.UserBroadcast
  alias RealtimeWeb.Socket.V2Serializer

  defmodule TestSerializer do
    def fastlane!(msg) do
      Agent.update(TestSerializer, fn count -> count + 1 end)
      {:encoded, msg}
    end
  end

  describe "fastlane_metadata/5" do
    test "info level" do
      assert MessageDispatcher.fastlane_metadata(self(), Serializer, "realtime:topic", :info, "tenant_id") ==
               {:rc_fastlane, self(), Serializer, "realtime:topic", :info, "tenant_id", MapSet.new()}
    end

    test "non-info level" do
      assert MessageDispatcher.fastlane_metadata(self(), Serializer, "realtime:topic", :warning, "tenant_id") ==
               {:rc_fastlane, self(), Serializer, "realtime:topic", :warning, "tenant_id", MapSet.new()}
    end

    test "replayed message ids" do
      assert MessageDispatcher.fastlane_metadata(
               self(),
               Serializer,
               "realtime:topic",
               :warning,
               "tenant_id",
               MapSet.new([1])
             ) ==
               {:rc_fastlane, self(), Serializer, "realtime:topic", :warning, "tenant_id", MapSet.new([1])}
    end
  end

  describe "dispatch/3" do
    setup do
      {:ok, _pid} =
        start_supervised(%{
          id: TestSerializer,
          start: {Agent, :start_link, [fn -> 0 end, [name: TestSerializer]]}
        })

      :ok
    end

    test "dispatches messages to fastlane subscribers" do
      parent = self()

      subscriber_pid =
        spawn(fn ->
          loop = fn loop ->
            receive do
              msg ->
                send(parent, {:subscriber, msg})
                loop.(loop)
            end
          end

          loop.(loop)
        end)

      from_pid = :erlang.list_to_pid(~c'<0.2.1>')

      subscribers = [
        {subscriber_pid, {:rc_fastlane, self(), TestSerializer, "realtime:topic", :info, "tenant123", MapSet.new()}},
        {subscriber_pid, {:rc_fastlane, self(), TestSerializer, "realtime:topic", :warning, "tenant123", MapSet.new()}}
      ]

      msg = %Broadcast{topic: "some:other:topic", event: "event", payload: %{data: "test"}}

      log =
        capture_log(fn ->
          assert MessageDispatcher.dispatch(subscribers, from_pid, msg) == :ok
        end)

      assert log =~ "Received message on realtime:topic with payload: #{inspect(msg, pretty: true)}"

      assert_receive {:encoded, %Broadcast{event: "event", payload: %{data: "test"}, topic: "realtime:topic"}}
      assert_receive {:encoded, %Broadcast{event: "event", payload: %{data: "test"}, topic: "realtime:topic"}}

      assert Agent.get(TestSerializer, & &1) == 1

      assert_receive {:subscriber, :update_rate_counter}
      assert_receive {:subscriber, :update_rate_counter}

      refute_receive _any
    end

    test "dispatches 'presence_diff' messages to fastlane subscribers" do
      parent = self()

      subscriber_pid =
        spawn(fn ->
          loop = fn loop ->
            receive do
              msg ->
                send(parent, {:subscriber, msg})
                loop.(loop)
            end
          end

          loop.(loop)
        end)

      from_pid = :erlang.list_to_pid(~c'<0.2.1>')

      subscribers = [
        {subscriber_pid, {:rc_fastlane, self(), TestSerializer, "realtime:topic", :info, "tenant456", MapSet.new()}},
        {subscriber_pid, {:rc_fastlane, self(), TestSerializer, "realtime:topic", :warning, "tenant456", MapSet.new()}}
      ]

      msg = %Broadcast{topic: "some:other:topic", event: "presence_diff", payload: %{data: "test"}}

      log =
        capture_log(fn ->
          assert MessageDispatcher.dispatch(subscribers, from_pid, msg) == :ok
        end)

      assert log =~ "Received message on realtime:topic with payload: #{inspect(msg, pretty: true)}"

      assert_receive {:encoded, %Broadcast{event: "presence_diff", payload: %{data: "test"}, topic: "realtime:topic"}}
      assert_receive {:encoded, %Broadcast{event: "presence_diff", payload: %{data: "test"}, topic: "realtime:topic"}}

      assert Agent.get(TestSerializer, & &1) == 1

      assert Realtime.GenCounter.get(Realtime.Tenants.presence_events_per_second_key("tenant456")) == 2

      refute_receive _any
    end

    test "does not dispatch messages to fastlane subscribers if they already replayed it" do
      parent = self()

      subscriber_pid =
        spawn(fn ->
          loop = fn loop ->
            receive do
              msg ->
                send(parent, {:subscriber, msg})
                loop.(loop)
            end
          end

          loop.(loop)
        end)

      from_pid = :erlang.list_to_pid(~c'<0.2.1>')
      replaeyd_message_ids = MapSet.new(["123"])

      subscribers = [
        {subscriber_pid,
         {:rc_fastlane, self(), TestSerializer, "realtime:topic", :info, "tenant123", replaeyd_message_ids}},
        {subscriber_pid,
         {:rc_fastlane, self(), TestSerializer, "realtime:topic", :warning, "tenant123", replaeyd_message_ids}}
      ]

      msg = %Broadcast{
        topic: "some:other:topic",
        event: "event",
        payload: %{"data" => "test", "meta" => %{"id" => "123"}}
      }

      assert MessageDispatcher.dispatch(subscribers, from_pid, msg) == :ok

      assert Agent.get(TestSerializer, & &1) == 0

      refute_receive _any
    end

    test "payload is not a map" do
      parent = self()

      subscriber_pid =
        spawn(fn ->
          loop = fn loop ->
            receive do
              msg ->
                send(parent, {:subscriber, msg})
                loop.(loop)
            end
          end

          loop.(loop)
        end)

      from_pid = :erlang.list_to_pid(~c'<0.2.1>')

      subscribers = [
        {subscriber_pid, {:rc_fastlane, self(), TestSerializer, "realtime:topic", :info, "tenant123", MapSet.new()}},
        {subscriber_pid, {:rc_fastlane, self(), TestSerializer, "realtime:topic", :warning, "tenant123", MapSet.new()}}
      ]

      msg = %Broadcast{topic: "some:other:topic", event: "event", payload: "not a map"}

      log =
        capture_log(fn ->
          assert MessageDispatcher.dispatch(subscribers, from_pid, msg) == :ok
        end)

      assert log =~ "Received message on realtime:topic with payload: #{inspect(msg, pretty: true)}"

      assert_receive {:encoded, %Broadcast{event: "event", payload: "not a map", topic: "realtime:topic"}}
      assert_receive {:encoded, %Broadcast{event: "event", payload: "not a map", topic: "realtime:topic"}}

      assert Agent.get(TestSerializer, & &1) == 1

      assert_receive {:subscriber, :update_rate_counter}
      assert_receive {:subscriber, :update_rate_counter}

      refute_receive _any
    end

    test "dispatches messages to non fastlane subscribers" do
      from_pid = :erlang.list_to_pid(~c'<0.2.1>')

      subscribers = [
        {self(), :not_fastlane},
        {self(), :not_fastlane}
      ]

      msg = %Broadcast{topic: "some:other:topic", event: "event", payload: %{data: "test"}}

      assert MessageDispatcher.dispatch(subscribers, from_pid, msg) == :ok

      assert_receive %Phoenix.Socket.Broadcast{topic: "some:other:topic", event: "event", payload: %{data: "test"}}
      assert_receive %Phoenix.Socket.Broadcast{topic: "some:other:topic", event: "event", payload: %{data: "test"}}

      # TestSerializer is not called
      assert Agent.get(TestSerializer, & &1) == 0
    end

    test "dispatches Broadcast to V1 & V2 Serializers" do
      parent = self()

      subscriber_pid =
        spawn(fn ->
          loop = fn loop ->
            receive do
              msg ->
                send(parent, {:subscriber, msg})
                loop.(loop)
            end
          end

          loop.(loop)
        end)

      from_pid = :erlang.list_to_pid(~c'<0.2.1>')

      subscribers = [
        {subscriber_pid, {:rc_fastlane, self(), V1.JSONSerializer, "realtime:topic", :info, "tenant123", MapSet.new()}},
        {subscriber_pid, {:rc_fastlane, self(), V1.JSONSerializer, "realtime:topic", :info, "tenant123", MapSet.new()}},
        {subscriber_pid, {:rc_fastlane, self(), V2Serializer, "realtime:topic", :info, "tenant123", MapSet.new()}},
        {subscriber_pid, {:rc_fastlane, self(), V2Serializer, "realtime:topic", :info, "tenant123", MapSet.new()}}
      ]

      msg = %Broadcast{topic: "some:other:topic", event: "event", payload: %{data: "test"}}

      log =
        capture_log(fn ->
          assert MessageDispatcher.dispatch(subscribers, from_pid, msg) == :ok
        end)

      assert log =~ "Received message on realtime:topic with payload: #{inspect(msg, pretty: true)}"

      # Receive 2 messages using V1
      assert_receive {:socket_push, :text, message_v1}
      assert_receive {:socket_push, :text, ^message_v1}

      assert Jason.decode!(message_v1) == %{
               "event" => "event",
               "payload" => %{"data" => "test"},
               "ref" => nil,
               "topic" => "realtime:topic"
             }

      # Receive 2 messages using V2
      assert_receive {:socket_push, :text, message_v2}
      assert_receive {:socket_push, :text, ^message_v2}

      # V2 is an array format
      assert Jason.decode!(message_v2) == [nil, nil, "realtime:topic", "event", %{"data" => "test"}]

      assert_receive {:subscriber, :update_rate_counter}
      assert_receive {:subscriber, :update_rate_counter}
      assert_receive {:subscriber, :update_rate_counter}
      assert_receive {:subscriber, :update_rate_counter}

      refute_receive _any
    end

    test "dispatches json UserBroadcast to V1 & V2 Serializers" do
      parent = self()

      subscriber_pid =
        spawn(fn ->
          loop = fn loop ->
            receive do
              msg ->
                send(parent, {:subscriber, msg})
                loop.(loop)
            end
          end

          loop.(loop)
        end)

      from_pid = :erlang.list_to_pid(~c'<0.2.1>')

      subscribers = [
        {subscriber_pid, {:rc_fastlane, self(), V1.JSONSerializer, "realtime:topic", :info, "tenant123", MapSet.new()}},
        {subscriber_pid, {:rc_fastlane, self(), V1.JSONSerializer, "realtime:topic", :info, "tenant123", MapSet.new()}},
        {subscriber_pid, {:rc_fastlane, self(), V2Serializer, "realtime:topic", :info, "tenant123", MapSet.new()}},
        {subscriber_pid, {:rc_fastlane, self(), V2Serializer, "realtime:topic", :info, "tenant123", MapSet.new()}}
      ]

      user_payload = Jason.encode!(%{data: "test"})

      msg = %UserBroadcast{
        topic: "some:other:topic",
        user_event: "event123",
        user_payload: user_payload,
        user_payload_encoding: :json,
        metadata: %{"id" => "123", "replayed" => true}
      }

      log =
        capture_log(fn ->
          assert MessageDispatcher.dispatch(subscribers, from_pid, msg) == :ok
        end)

      assert log =~ "Received message on realtime:topic with payload: #{inspect(msg, pretty: true)}"

      # Receive 2 messages using V1
      assert_receive {:socket_push, :text, message_v1}
      assert_receive {:socket_push, :text, ^message_v1}

      assert Jason.decode!(message_v1) == %{
               "event" => "broadcast",
               "payload" => %{
                 "event" => "event123",
                 "meta" => %{"id" => "123", "replayed" => true},
                 "payload" => %{"data" => "test"},
                 "type" => "broadcast"
               },
               "ref" => nil,
               "topic" => "realtime:topic"
             }

      # Receive 2 messages using V2
      assert_receive {:socket_push, :binary, message_v2}
      assert_receive {:socket_push, :binary, ^message_v2}

      encoded_metadata = Jason.encode!(%{"id" => "123", "replayed" => true})
      metadata_size = byte_size(encoded_metadata)

      # binary payload structure
      assert message_v2 ==
               <<
                 # user broadcast = 4
                 4::size(8),
                 # topic_size
                 14,
                 # user_event_size
                 8,
                 # metadata_size
                 metadata_size,
                 # json encoding
                 1::size(8),
                 "realtime:topic",
                 "event123"
               >> <> encoded_metadata <> user_payload

      assert_receive {:subscriber, :update_rate_counter}
      assert_receive {:subscriber, :update_rate_counter}
      assert_receive {:subscriber, :update_rate_counter}
      assert_receive {:subscriber, :update_rate_counter}

      refute_receive _any
    end

    test "dispatches binary UserBroadcast to V1 & V2 Serializers" do
      parent = self()

      subscriber_pid =
        spawn(fn ->
          loop = fn loop ->
            receive do
              msg ->
                send(parent, {:subscriber, msg})
                loop.(loop)
            end
          end

          loop.(loop)
        end)

      from_pid = :erlang.list_to_pid(~c'<0.2.1>')

      subscribers = [
        {subscriber_pid, {:rc_fastlane, self(), V1.JSONSerializer, "realtime:topic", :info, "tenant123", MapSet.new()}},
        {subscriber_pid, {:rc_fastlane, self(), V1.JSONSerializer, "realtime:topic", :info, "tenant123", MapSet.new()}},
        {subscriber_pid, {:rc_fastlane, self(), V2Serializer, "realtime:topic", :info, "tenant123", MapSet.new()}},
        {subscriber_pid, {:rc_fastlane, self(), V2Serializer, "realtime:topic", :info, "tenant123", MapSet.new()}}
      ]

      user_payload = <<123, 456, 789>>

      msg = %UserBroadcast{
        topic: "some:other:topic",
        user_event: "event123",
        user_payload: user_payload,
        user_payload_encoding: :binary,
        metadata: %{"id" => "123", "replayed" => true}
      }

      log =
        capture_log(fn ->
          assert MessageDispatcher.dispatch(subscribers, from_pid, msg) == :ok
        end)

      assert log =~ "Received message on realtime:topic with payload: #{inspect(msg, pretty: true)}"
      assert log =~ "User payload encoding is not JSON"

      # No V1 message received as binary payloads are not supported
      refute_receive {:socket_push, :text, _message_v1}

      # Receive 2 messages using V2
      assert_receive {:socket_push, :binary, message_v2}
      assert_receive {:socket_push, :binary, ^message_v2}

      encoded_metadata = Jason.encode!(%{"id" => "123", "replayed" => true})
      metadata_size = byte_size(encoded_metadata)

      # binary payload structure
      assert message_v2 ==
               <<
                 # user broadcast = 4
                 4::size(8),
                 # topic_size
                 14,
                 # user_event_size
                 8,
                 # metadata_size
                 metadata_size,
                 # binary encoding
                 0::size(8),
                 "realtime:topic",
                 "event123"
               >> <> encoded_metadata <> user_payload

      assert_receive {:subscriber, :update_rate_counter}
      assert_receive {:subscriber, :update_rate_counter}
      assert_receive {:subscriber, :update_rate_counter}
      assert_receive {:subscriber, :update_rate_counter}

      refute_receive _any
    end
  end
end
