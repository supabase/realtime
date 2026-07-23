defmodule RealtimeWeb.TenantBroadcasterBrokerTest do
  use ExUnit.Case, async: false

  import Mimic

  alias Phoenix.Socket.Broadcast
  alias RealtimeWeb.TenantBroadcaster

  setup :verify_on_exit!

  describe "broker routing" do
    test "pubsub_broadcast routes through broker" do
      tenant_id = "tenant-#{System.unique_integer([:positive])}"
      topic = "test-topic"
      message = %Broadcast{topic: topic, event: "an event", payload: %{"a" => "b"}}

      expect(Realtime.Broker.Syn, :publish, fn ^topic, ^message, opts ->
        assert opts[:dispatcher] == Phoenix.PubSub
        assert opts[:from] == nil
        :ok
      end)

      assert :ok = TenantBroadcaster.pubsub_broadcast(tenant_id, topic, message, Phoenix.PubSub, :broadcast)
    end

    test "pubsub_broadcast_from routes through broker with sender exclusion" do
      tenant_id = "tenant-#{System.unique_integer([:positive])}"
      topic = "test-topic"
      message = %Broadcast{topic: topic, event: "an event", payload: %{"a" => "b"}}
      from = self()

      expect(Realtime.Broker.Syn, :publish, fn ^topic, ^message, opts ->
        assert opts[:dispatcher] == Phoenix.PubSub
        assert opts[:from] == from
        :ok
      end)

      assert :ok =
               TenantBroadcaster.pubsub_broadcast_from(tenant_id, from, topic, message, Phoenix.PubSub, :broadcast)
    end
  end
end
