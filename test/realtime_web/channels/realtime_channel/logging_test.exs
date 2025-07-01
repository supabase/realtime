defmodule RealtimeWeb.RealtimeChannel.LoggingTest do
  # async: false due to changes in Logger levels
  use Realtime.DataCase, async: false
  import ExUnit.CaptureLog
  alias RealtimeWeb.RealtimeChannel.Logging

  def handle_telemetry(event, measures, metadata, pid: pid), do: send(pid, {event, measures, metadata})

  setup do
    :telemetry.attach(__MODULE__, [:realtime, :channel, :error], &__MODULE__.handle_telemetry/4, pid: self())
    level = Logger.level()
    Logger.configure(level: :info)

    on_exit(fn ->
      :telemetry.detach(__MODULE__)
      Logger.configure(level: level)
    end)
  end

  describe "maybe_log_handle_info/2" do
    test "logs message when log_level is less than error and payload is structure" do
      channel_name = random_string()
      msg = %{"payload" => %{"a" => "b"}}
      socket = %{assigns: %{log_level: :info, channel_name: channel_name}}

      assert capture_log(fn -> Logging.maybe_log_handle_info(socket, msg) end) =~
               "Received message on #{channel_name} with payload: #{inspect(msg, pretty: true)}"
    end

    test "logs message when log_level is less than error and payload is string" do
      channel_name = random_string()
      msg = random_string()
      socket = %{assigns: %{log_level: :info, channel_name: channel_name}}

      assert capture_log(fn -> Logging.maybe_log_handle_info(socket, msg) end) =~
               "Received message on #{channel_name} with payload: #{msg}"
    end

    test "does not log message when log_level is error" do
      socket = %{assigns: %{log_level: :error, channel_name: "test_channel"}}
      test_msg = "test message"

      assert capture_log(fn -> Logging.maybe_log_handle_info(socket, test_msg) end) == ""
    end
  end

  describe "log_error_message/3" do
    test "handles warning level errors" do
      assert capture_log([level: :warning], fn ->
               result = Logging.log_error_message(:warning, "TestError", "test error")
               assert {:error, %{reason: "test error"}} = result
             end) =~ "TestError: test error"
    end

    test "handles error level errors" do
      assert capture_log(fn ->
               result = Logging.log_error_message(:error, "TestCodeError", "test error")
               assert {:error, %{reason: "test error"}} = result
             end) =~ "test error"
    end

    test "only emits telemetry for system errors" do
      errors = Logging.system_errors()

      for error <- errors do
        Logging.log_error_message(:error, error, "test error")
        assert_receive {[:realtime, :channel, :error], %{code: ^error}, %{code: ^error}}
      end

      Logging.log_error_message(:error, "DatabaseConnectionIssue", "test error")
      refute_receive {[:realtime, :channel, :error], %{code: "DatabaseConnectionIssue"}, %{code: "UnableToSetPolicies"}}
    end
  end

  describe "maybe_log/3" do
    test "logs messages at the specified level" do
      socket = %{assigns: %{log_level: :info}}

      assert capture_log(fn ->
               Logging.maybe_log(socket, :info, "TestCode", "test message")
             end) =~ "TestCode: test message"

      assert capture_log(fn ->
               Logging.maybe_log(socket, :error, "TestError", "test error")
             end) =~ "TestError: test error"
    end

    test "does not log messages when log level is higher than the configured level" do
      socket = %{assigns: %{log_level: :error}}

      assert capture_log(fn ->
               Logging.maybe_log(socket, :info, "TestCode", "test message")
             end) == ""
    end
  end

  describe "maybe_log_error/3" do
    test "logs error messages at the error level" do
      socket = %{assigns: %{log_level: :info}}

      assert capture_log(fn ->
               Logging.maybe_log_error(socket, "TestError", "test error")
             end) =~ "TestError: test error"
    end

    test "does not log when log level is higher than error" do
      socket = %{assigns: %{log_level: :emergency}}

      assert capture_log(fn ->
               Logging.maybe_log_error(socket, "TestError", "test error")
             end) == ""
    end
  end

  describe "maybe_log_warning/3" do
    test "logs warning messages at the warning level" do
      socket = %{assigns: %{log_level: :warning}}

      assert capture_log(fn ->
               Logging.maybe_log_warning(socket, "TestWarning", "test warning")
             end) =~ "TestWarning: test warning"
    end

    test "does not log when log level is higher than warning" do
      socket = %{assigns: %{log_level: :error}}

      assert capture_log(fn -> Logging.maybe_log_warning(socket, "TestWarning", "test warning") end) == ""
    end
  end

  describe "maybe_log_info/3" do
    test "logs info messages at the info level" do
      socket = %{assigns: %{log_level: :info}}

      assert capture_log(fn -> Logging.maybe_log_info(socket, "test info") end) =~ "test info"
    end

    test "does not log when log level is higher than info" do
      socket = %{assigns: %{log_level: :warning}}

      assert capture_log(fn -> Logging.maybe_log_info(socket, "test info") end) == ""
    end
  end
end
