Application.put_env(:phoenix_pubsub, :test_adapter, {Realtime.GenRpcPubSub, []})
Code.require_file("../../deps/phoenix_pubsub/test/shared/pubsub_test.exs", __DIR__)

defmodule Realtime.GenRpcPubSubTest do
  use ExUnit.Case, async: true

  test "it sets off_heap message_queue_data flag on the workers" do
    assert Realtime.PubSubElixir.Realtime.PubSub.Adapter_1
           |> Process.whereis()
           |> Process.info(:message_queue_data) == {:message_queue_data, :off_heap}
  end

  test "it sets fullsweep_after flag on the workers" do
    assert Realtime.PubSubElixir.Realtime.PubSub.Adapter_1
           |> Process.whereis()
           |> Process.info(:fullsweep_after) == {:fullsweep_after, 100}
  end
end
