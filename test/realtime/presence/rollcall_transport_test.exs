defmodule Realtime.Presence.RollcallTransportTest do
  use ExUnit.Case, async: true
  use Mimic
  use TestHelpers

  alias Realtime.Presence.RollcallTransport
  alias Realtime.UsersCounter
  alias Rollcall.Tracker.Messages

  setup :set_mimic_from_context

  setup do
    scope = "rollcall-#{System.unique_integer([:positive])}"
    {:ok, scope: scope, topic: "rollcall:" <> scope}
  end

  describe "init/2" do
    test "subscribes the caller to the topic of the scope", %{scope: scope, topic: topic} do
      assert {:ok, _state} = RollcallTransport.init(scope, pubsub: Realtime.PubSub)

      :ok = Phoenix.PubSub.broadcast(Realtime.PubSub, topic, :ping)

      assert_receive :ping
    end

    test "does not subscribe the caller to the topic of another scope", %{scope: scope} do
      assert {:ok, _state} = RollcallTransport.init(scope, pubsub: Realtime.PubSub)

      :ok = Phoenix.PubSub.broadcast(Realtime.PubSub, "rollcall:other-#{scope}", :ping)

      refute_receive :ping, 100
    end
  end

  # The tracker asks at the end of its grace period. A node that has users of the tenant connected
  # keeps the tracker, so the users still get the state and the diffs of their peers.
  describe "has_interest?/1" do
    setup %{scope: scope} do
      {:ok, state} = RollcallTransport.init(scope, pubsub: Realtime.PubSub)
      {:ok, state: state}
    end

    test "is false when no user of the scope is connected on the node", %{state: state} do
      refute RollcallTransport.has_interest?(state)
    end

    test "is true while a user of the scope is connected on the node", %{state: state, scope: scope} do
      :ok = UsersCounter.add(connected_user(), scope)

      assert RollcallTransport.has_interest?(state)
    end

    test "is false after the process of the user exits", %{state: state, scope: scope} do
      user = connected_user()
      :ok = UsersCounter.add(user, scope)

      Process.exit(user, :kill)

      assert_eventually(not RollcallTransport.has_interest?(state))
    end

    test "is false when only a user of another scope is connected on the node", %{state: state, scope: scope} do
      :ok = UsersCounter.add(connected_user(), "other-#{scope}")

      refute RollcallTransport.has_interest?(state)
    end
  end

  # The test supervisor stops the process when the test ends. The process is not linked to the test,
  # so a test can kill it.
  defp connected_user do
    start_supervised!(Supervisor.child_spec({Task, fn -> Process.sleep(:infinity) end}, id: make_ref()))
  end

  describe "heartbeat/2" do
    setup %{scope: scope} do
      {:ok, state} = RollcallTransport.init(scope, pubsub: Realtime.PubSub)
      {:ok, state: state}
    end

    test "delivers the tagged message to the other subscribers of the topic", %{
      state: state,
      scope: scope,
      topic: topic
    } do
      subscribe_from_other_process(topic)
      message = snapshot()

      assert :ok = RollcallTransport.heartbeat(state, message)

      assert_receive {:relayed, {:tb, ^scope, ^message}}
    end

    test "does not deliver the message to the sender", %{state: state, topic: topic} do
      subscribe_from_other_process(topic)

      :ok = RollcallTransport.heartbeat(state, snapshot())

      # The other subscriber got the message, so the broadcast is complete.
      assert_receive {:relayed, {:tb, _scope, _message}}
      refute_receive {:tb, _scope, _message}, 100
    end

    test "does not deliver the message to the subscribers of another scope", %{state: state, scope: scope} do
      subscribe_from_other_process("rollcall:other-#{scope}")
      subscribe_from_other_process("rollcall:" <> scope)

      :ok = RollcallTransport.heartbeat(state, snapshot())

      # One subscriber relays the message. The subscriber of the other scope relays nothing.
      assert_receive {:relayed, {:tb, ^scope, _message}}
      refute_receive {:relayed, _}, 100
    end
  end

  describe "publish/3" do
    setup %{scope: scope} do
      stub(Realtime.FeatureFlags, :enabled?, fn flag, ^scope -> flag == "presence_rollcall_primary" end)
      {:ok, state} = RollcallTransport.init(scope, pubsub: Realtime.PubSub)
      {:ok, state: state, partition: "realtime:partition-#{scope}"}
    end

    test "sends a presence_diff with the encoded diff to the subscribers of the partition", %{
      state: state,
      partition: partition
    } do
      Phoenix.PubSub.subscribe(Realtime.PubSub, partition)
      diff = {[{"r2", "alice", %{"n" => 2, rc_prev_ref: "r1"}}], [{"r1", "alice", %{"n" => 1}}]}

      assert :ok = RollcallTransport.publish(state, partition, diff)

      assert_receive %Phoenix.Socket.Broadcast{topic: ^partition, event: "presence_diff", payload: payload}

      assert payload == %{
               joins: %{"alice" => %{metas: [%{"n" => 2, phx_ref: "r2", phx_ref_prev: "r1"}]}},
               leaves: %{"alice" => %{metas: [%{"n" => 1, phx_ref: "r1"}]}}
             }
    end

    test "sends the diff to the subscribers of other processes", %{state: state, partition: partition} do
      subscribe_from_other_process(partition)

      assert :ok = RollcallTransport.publish(state, partition, {[{"r1", "alice", %{}}], []})

      assert_receive {:relayed, %Phoenix.Socket.Broadcast{topic: ^partition, event: "presence_diff"}}
    end

    test "does not send the diff to the subscribers of another partition", %{state: state, partition: partition} do
      Phoenix.PubSub.subscribe(Realtime.PubSub, partition <> "-other")

      :ok = RollcallTransport.publish(state, partition, {[{"r1", "alice", %{}}], []})

      refute_receive %Phoenix.Socket.Broadcast{}, 100
    end

    test "sends nothing unless the Rollcall mode is on", %{scope: scope, state: state, partition: partition} do
      stub(Realtime.FeatureFlags, :enabled?, fn flag, ^scope -> flag == "presence_rollcall_shadow" end)
      Phoenix.PubSub.subscribe(Realtime.PubSub, partition)

      assert :ok = RollcallTransport.publish(state, partition, {[{"r1", "alice", %{}}], []})

      refute_receive %Phoenix.Socket.Broadcast{}, 100
    end

    test "sends the diff once to a subscriber", %{state: state, partition: partition} do
      Phoenix.PubSub.subscribe(Realtime.PubSub, partition)

      :ok = RollcallTransport.publish(state, partition, {[{"r1", "alice", %{}}], []})

      assert_receive %Phoenix.Socket.Broadcast{topic: ^partition}
      refute_receive %Phoenix.Socket.Broadcast{topic: ^partition}, 100
    end
  end

  describe "unwrap/2" do
    setup %{scope: scope} do
      {:ok, state} = RollcallTransport.init(scope, pubsub: Realtime.PubSub)
      {:ok, state: state}
    end

    for kind <- [:snapshot, :diff, :request] do
      test "returns the scope and the message for a tagged #{kind}", %{state: state, scope: scope} do
        message = message(unquote(kind))

        assert {:ok, ^scope, ^message} = RollcallTransport.unwrap(state, {:tb, scope, message})
      end
    end

    test "ignores a message without the tag", %{state: state, scope: scope} do
      assert :ignore = RollcallTransport.unwrap(state, snapshot())
      assert :ignore = RollcallTransport.unwrap(state, {:rc, scope, snapshot()})
    end

    test "ignores other messages of the tracker mailbox", %{state: state} do
      assert :ignore = RollcallTransport.unwrap(state, :tick)
      assert :ignore = RollcallTransport.unwrap(state, {:DOWN, make_ref(), :process, self(), :normal})
      assert :ignore = RollcallTransport.unwrap(state, "binary")
    end
  end

  defp message(:snapshot), do: snapshot()
  defp message(:diff), do: Messages.diff(self(), Messages.stamp(1, 2), 1, [], [])
  defp message(:request), do: Messages.request(self())

  defp snapshot do
    Messages.snapshot(self(), Messages.stamp(1, 1), [Messages.wire_entry("partition", "key", make_ref(), %{})])
  end

  # Subscribes a new process to `topic`, and returns when the subscription is
  # active. The process sends the first message it gets to the test process.
  defp subscribe_from_other_process(topic) do
    test = self()

    pid =
      spawn_link(fn ->
        :ok = Phoenix.PubSub.subscribe(Realtime.PubSub, topic)
        send(test, {:subscribed, self()})

        receive do
          message -> send(test, {:relayed, message})
        end
      end)

    assert_receive {:subscribed, ^pid}
    pid
  end
end
