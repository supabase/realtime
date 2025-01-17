defmodule RealtimeWeb.RealtimeChannel.LoggingTest do
  # async: false due to changes in Logger levels
  use Realtime.DataCase, async: false
  import ExUnit.CaptureLog
  alias RealtimeWeb.RealtimeChannel.Logging

  setup do
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: :error) end)
  end

  describe "maybe_log_handle_info/2" do
    test "logs message when log_level is less than error" do
      channel_name = random_string()
      msg = random_string()
      socket = %{assigns: %{log_level: :debug, channel_name: channel_name}}

      assert capture_log(fn -> Logging.maybe_log_handle_info(socket, msg) end) =~
               "HANDLE_INFO INCOMING ON #{channel_name} message: \"#{msg}\""
    end

    test "does not log message when log_level is error" do
      socket = %{assigns: %{log_level: :error, channel_name: "test_channel"}}
      test_msg = "test message"

      assert capture_log(fn -> Logging.maybe_log_handle_info(socket, test_msg) end) == ""
    end
  end

  describe "log_error_message/3" do
    test "handles warning level errors" do
      assert capture_log(fn ->
               result = Logging.log_error_message(:warning, :test_code, "test error")
               assert {:error, %{reason: "Start channel error: test error"}} = result
             end) =~ "Start channel error: test error"
    end

    test "handles error level errors" do
      assert capture_log(fn ->
               result = Logging.log_error_message(:error, :test_code, "test error")
               assert {:error, %{reason: "test error"}} = result
             end) =~ "test error"
    end
  end
end
