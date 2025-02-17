defmodule Realtime.SignalHandlerTest do
  use ExUnit.Case
  import ExUnit.CaptureLog
  alias Realtime.SignalHandler

  defmodule FakeHandler do
    def handle_event(:sigterm, _state), do: send(self(), :ok)
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

      assert_receive :ok
    end
  end

  describe "shutdown_in_progress?/1" do
    test "shutdown_in_progress? returns error when shutdown is in progress" do
      Application.put_env(:realtime, :shutdown_in_progress, true)
      assert SignalHandler.shutdown_in_progress?() == {:error, :shutdown_in_progress}
    end

    test "shutdown_in_progress? returns ok when no shutdown in progress" do
      Application.put_env(:realtime, :shutdown_in_progress, false)
      assert SignalHandler.shutdown_in_progress?() == :ok
    end
  end
end
