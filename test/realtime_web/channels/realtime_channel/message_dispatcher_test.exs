defmodule RealtimeWeb.RealtimeChannel.MessageDispatcherTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Phoenix.Socket.Broadcast
  alias RealtimeWeb.RealtimeChannel.MessageDispatcher

  defmodule TestSerializer do
    def fastlane!(msg) do
      Agent.update(TestSerializer, fn count -> count + 1 end)
      {:encoded, msg}
    end
  end

  describe "fastlane_metadata/5" do
    test "info level" do
      assert MessageDispatcher.fastlane_metadata(self(), Serializer, "realtime:topic", :info, "tenant_id") ==
               {:realtime_channel_fastlane, self(), Serializer, "realtime:topic", {:log, "tenant_id"}}
    end

    test "non-info level" do
      assert MessageDispatcher.fastlane_metadata(self(), Serializer, "realtime:topic", :warning, "tenant_id") ==
               {:realtime_channel_fastlane, self(), Serializer, "realtime:topic"}
    end
  end

  describe "dispatch/3" do
    setup do
      {:ok, _pid} = Agent.start_link(fn -> 0 end, name: TestSerializer)
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
        {subscriber_pid, {:realtime_channel_fastlane, self(), TestSerializer, "realtime:topic", {:log, "tenant123"}}},
        {subscriber_pid, {:realtime_channel_fastlane, self(), TestSerializer, "realtime:topic"}}
      ]

      msg = %Broadcast{topic: "some:other:topic", event: "event", payload: %{data: "test"}}
      require Logger

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
  end
end
