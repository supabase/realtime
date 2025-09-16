Application.put_env(:phoenix_pubsub, :test_adapter, {Realtime.GenRpcPubSub, []})
Code.require_file("../../deps/phoenix_pubsub/test/shared/pubsub_test.exs", __DIR__)
