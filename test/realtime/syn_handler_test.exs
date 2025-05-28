defmodule Realtime.SynHandlerTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Realtime.SynHandler

  @mod SynHandler
  @name "test"
  @topic "syn_handler"

  describe "on_process_unregistered/5" do
    setup do
      RealtimeWeb.Endpoint.subscribe("#{@topic}:#{@name}")
    end

    test "it handles :syn_conflict_resolution reason" do
      reason = :syn_conflict_resolution

      log =
        capture_log(fn ->
          assert SynHandler.on_process_unregistered(@mod, @name, self(), %{region: "us-east-1"}, reason) == :ok
        end)

      topic = "#{@topic}:#{@name}"
      event = "#{@topic}_down"

      assert log =~ "#{@mod} terminated: #{inspect(@name)} #{node()}"
      refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: ^event, payload: nil}
    end

    test "it handles :syn_conflict_resolution reason without region" do
      reason = :syn_conflict_resolution

      log =
        capture_log(fn ->
          assert SynHandler.on_process_unregistered(@mod, @name, self(), %{}, reason) == :ok
        end)

      topic = "#{@topic}:#{@name}"
      event = "#{@topic}_down"

      assert log =~ "#{@mod} terminated: #{inspect(@name)} #{node()}"
      refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: ^event, payload: nil}
    end

    test "it handles other reasons" do
      reason = :other_reason

      log =
        capture_log(fn ->
          assert SynHandler.on_process_unregistered(@mod, @name, self(), %{}, reason) == :ok
        end)

      topic = "#{@topic}:#{@name}"
      event = "#{@topic}_down"

      refute log =~ "#{@mod} terminated: #{inspect(@name)} #{node()}"
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: ^event, payload: nil}, 500
    end
  end

  describe "resolve_registry_conflict/4" do
    test "returns the correct pid to keep" do
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      time1 = System.monotonic_time()

      pid2 = spawn(fn -> Process.sleep(:infinity) end)
      time2 = System.monotonic_time()

      assert pid1 ==
               SynHandler.resolve_registry_conflict(
                 __MODULE__,
                 Generators.random_string(),
                 {pid1, %{}, time1},
                 {pid2, %{}, time2}
               )
    end
  end
end
