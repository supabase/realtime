defmodule Realtime.Broker.SynTest do
  use ExUnit.Case, async: false

  alias Phoenix.Socket.Broadcast
  alias Realtime.Broker.Syn

  describe "child_spec/1" do
    test "returns a supervisor child spec" do
      assert %{
               id: Syn,
               start: {Syn, :start_link, [[name: Syn]]},
               type: :worker,
               restart: :permanent
             } = Syn.child_spec([])
    end
  end

  describe "publish/3" do
    setup do
      previous_pubsub = Application.get_env(:realtime, Realtime.PubSub)
      pubsub_name = :"syn_broker_test_pubsub_#{System.unique_integer([:positive])}"
      {:ok, _pid} = start_supervised({Phoenix.PubSub, name: pubsub_name, adapter: Phoenix.PubSub.PG2})
      Application.put_env(:realtime, Realtime.PubSub, pubsub_name)

      broker_name = :"syn_broker_test_#{System.unique_integer([:positive])}"
      {:ok, broker} = start_supervised({Syn, pubsub: pubsub_name, name: broker_name})

      on_exit(fn ->
        Application.put_env(:realtime, Realtime.PubSub, previous_pubsub)
      end)

      {:ok, broker: broker, pubsub: pubsub_name}
    end

    test "relays published messages to local Phoenix.PubSub subscribers", %{broker: broker, pubsub: pubsub} do
      Phoenix.PubSub.subscribe(pubsub, "topic")

      assert :ok = Syn.publish("topic", %Broadcast{topic: "topic", event: "e", payload: %{}}, broker_pid: broker)

      assert_receive %Broadcast{topic: "topic", event: "e"}
    end

    test "relays remote :syn messages to local subscribers", %{broker: broker, pubsub: pubsub} do
      Phoenix.PubSub.subscribe(pubsub, "topic")

      send(broker, {"topic", %Broadcast{topic: "topic", event: "e", payload: %{}}, nil, nil})

      assert_receive %Broadcast{topic: "topic", event: "e"}
    end

    test "excludes sender when :from option is provided", %{broker: broker, pubsub: pubsub} do
      parent = self()

      sender =
        spawn(fn ->
          Phoenix.PubSub.subscribe(pubsub, "topic")
          send(parent, :ready)

          receive do
            msg -> send(parent, {:sender_got, msg})
          end
        end)

      _other =
        spawn(fn ->
          Phoenix.PubSub.subscribe(pubsub, "topic")
          send(parent, :ready)

          receive do
            msg -> send(parent, {:other_got, msg})
          end
        end)

      assert_receive :ready
      assert_receive :ready

      assert :ok =
               Syn.publish("topic", %Broadcast{topic: "topic", event: "e", payload: %{}},
                 broker_pid: broker,
                 from: sender
               )

      assert_receive {:other_got, %Broadcast{topic: "topic", event: "e"}}
      refute_receive {:sender_got, _}, 100
    end
  end

  describe "subscribe/2 and unsubscribe/1" do
    setup do
      pubsub_name = :"syn_broker_sub_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = start_supervised({Phoenix.PubSub, name: pubsub_name, adapter: Phoenix.PubSub.PG2})
      {:ok, pubsub: pubsub_name}
    end

    test "delegates to Phoenix.PubSub", %{pubsub: pubsub} do
      assert :ok = Syn.subscribe("topic", pubsub: pubsub)
      Phoenix.PubSub.broadcast(pubsub, "topic", :hello)
      assert_receive :hello

      assert :ok = Syn.unsubscribe("topic")
    end
  end

  describe "batching" do
    setup do
      pubsub_name = :"syn_broker_batch_pubsub_#{System.unique_integer([:positive])}"
      {:ok, _pid} = start_supervised({Phoenix.PubSub, name: pubsub_name, adapter: Phoenix.PubSub.PG2})
      {:ok, pubsub: pubsub_name}
    end

    test "batches multiple messages for the same topic and routes through batch-aware dispatcher", %{pubsub: pubsub} do
      topic = "batch-topic-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(pubsub, topic)

      broker_name = :"syn_broker_batch_test_#{System.unique_integer([:positive])}"

      {:ok, broker} =
        start_supervised(%{
          Syn.child_spec(pubsub: pubsub, name: broker_name, flush_interval_ms: 5_000, flush_max_size: 3)
          | id: {Syn, broker_name}
        })

      msg1 = %Broadcast{topic: topic, event: "e1", payload: %{"n" => 1}}
      msg2 = %Broadcast{topic: topic, event: "e2", payload: %{"n" => 2}}
      msg3 = %Broadcast{topic: topic, event: "e3", payload: %{"n" => 3}}

      assert :ok = Syn.publish(topic, msg1, broker_pid: broker, dispatcher: __MODULE__.TestDispatcher)
      assert :ok = Syn.publish(topic, msg2, broker_pid: broker, dispatcher: __MODULE__.TestDispatcher)
      assert :ok = Syn.publish(topic, msg3, broker_pid: broker, dispatcher: __MODULE__.TestDispatcher)

      # The custom dispatcher must unwrap the batch and deliver individual messages.
      assert_receive ^msg1
      assert_receive ^msg2
      assert_receive ^msg3
      refute_receive %Broadcast{event: "__batch__"}
    end

    test "flushes immediately when buffer reaches max size", %{pubsub: pubsub} do
      topic = "max-topic-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(pubsub, topic)

      broker_name = :"syn_broker_max_test_#{System.unique_integer([:positive])}"

      {:ok, broker} =
        start_supervised(%{
          Syn.child_spec(pubsub: pubsub, name: broker_name, flush_interval_ms: 5_000, flush_max_size: 2)
          | id: {Syn, broker_name}
        })

      msg1 = %Broadcast{topic: topic, event: "e1", payload: %{}}
      msg2 = %Broadcast{topic: topic, event: "e2", payload: %{}}

      assert :ok = Syn.publish(topic, msg1, broker_pid: broker, dispatcher: __MODULE__.TestDispatcher)
      refute_receive %Broadcast{event: "e1", topic: ^topic}, 50

      assert :ok = Syn.publish(topic, msg2, broker_pid: broker, dispatcher: __MODULE__.TestDispatcher)

      assert_receive ^msg1
      assert_receive ^msg2
      refute_receive %Broadcast{event: "__batch__"}
    end

    test "does not batch messages for non batch-aware dispatchers", %{pubsub: pubsub} do
      topic = "plain-topic-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(pubsub, topic)

      broker_name = :"syn_broker_plain_test_#{System.unique_integer([:positive])}"

      {:ok, broker} =
        start_supervised(%{
          Syn.child_spec(pubsub: pubsub, name: broker_name, flush_interval_ms: 5_000, flush_max_size: 2)
          | id: {Syn, broker_name}
        })

      msg1 = %Broadcast{topic: topic, event: "e1", payload: %{}}
      msg2 = %Broadcast{topic: topic, event: "e2", payload: %{}}

      assert :ok = Syn.publish(topic, msg1, broker_pid: broker, dispatcher: Phoenix.PubSub)
      refute_receive %Broadcast{event: "e1", topic: ^topic}, 50

      assert :ok = Syn.publish(topic, msg2, broker_pid: broker, dispatcher: Phoenix.PubSub)

      assert_receive ^msg1
      assert_receive ^msg2
      refute_receive %Broadcast{event: "__batch__"}
    end
  end

  defmodule TestDispatcher do
    @moduledoc "Custom dispatcher used to prove batches are routed correctly."

    alias Phoenix.Socket.Broadcast

    def batch_dispatch?, do: true

    def dispatch(subscribers, from, %Broadcast{event: "__batch__", payload: messages}) do
      Enum.each(messages, fn {msg, msg_from} ->
        dispatch(subscribers, msg_from || from, msg)
      end)

      :ok
    end

    def dispatch(subscribers, from, msg) do
      Enum.each(subscribers, fn
        {pid, _} when pid == from -> :ok
        {pid, _} -> send(pid, msg)
      end)

      :ok
    end
  end
end
