defmodule Realtime.SignalHandlerTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Realtime.SignalHandler

  defmodule FakeHandler do
    def handle_event(signal, state) do
      send(self(), {:signal_received, signal})
      {:ok, state}
    end
  end

  setup do
    on_exit(fn ->
      Application.put_env(:realtime, :shutdown_in_progress, false)
    end)
  end

  describe "signal handling" do
    test "sends signal to handler_mod" do
      {:ok, state} = SignalHandler.init({%{handler_mod: FakeHandler}, :ok})

      assert capture_log(fn -> SignalHandler.handle_event(:sigterm, state) end) =~
               "SignalHandler: :sigterm received"

      assert_receive {:signal_received, :sigterm}
    end

    test "logs error for unexpected signals" do
      {:ok, state} = SignalHandler.init({%{handler_mod: FakeHandler}, :ok})

      assert capture_log(fn -> SignalHandler.handle_event(:sigusr1, state) end) =~
               "unexpected signal :sigusr1"
    end

    test "sets shutdown_in_progress on sigterm" do
      {:ok, state} = SignalHandler.init({%{handler_mod: FakeHandler}, :ok})
      capture_log(fn -> SignalHandler.handle_event(:sigterm, state) end)
      assert Application.get_env(:realtime, :shutdown_in_progress) == true
    end

    test "does not set shutdown_in_progress on non-sigterm signals" do
      Application.put_env(:realtime, :shutdown_in_progress, false)
      {:ok, state} = SignalHandler.init({%{handler_mod: FakeHandler}, :ok})
      capture_log(fn -> SignalHandler.handle_event(:sigusr1, state) end)
      refute Application.get_env(:realtime, :shutdown_in_progress)
    end

    test "sigint sets shutdown_in_progress, logs, returns state, does not delegate" do
      shutdown_called = self()
      {:ok, state} = SignalHandler.init({%{handler_mod: FakeHandler, shutdown_fn: fn -> send(shutdown_called, :shutdown_called) end}, :ok})

      log =
        capture_log(fn ->
          assert {:ok, ^state} = SignalHandler.handle_event(:sigint, state)
        end)

      assert Application.get_env(:realtime, :shutdown_in_progress) == true
      assert log =~ "SIGINT received - shutting down"
      assert_receive :shutdown_called
      refute_receive {:signal_received, :sigint}
    end
  end

  describe "shutdown_in_progress?/1" do
    test "returns error when shutdown is in progress" do
      Application.put_env(:realtime, :shutdown_in_progress, true)
      assert SignalHandler.shutdown_in_progress?() == {:error, :shutdown_in_progress}
    end

    test "returns ok when no shutdown in progress" do
      Application.put_env(:realtime, :shutdown_in_progress, false)
      assert SignalHandler.shutdown_in_progress?() == :ok
    end
  end

  describe "SIGINT shutdown path" do
    @describetag :integration
    test "peer node shuts down when sigint is handled by SignalHandler" do
      {:ok, peer_pid, node} = Clustered.start_disconnected()

      true = Node.connect(node)
      Node.monitor(node, true)

      :peer.cast(peer_pid, :gen_event, :notify, [:erl_signal_server, :sigint])

      assert_receive {:nodedown, ^node}, 10_000
    end
  end
end
