defmodule Realtime.LogFilterTest do
  use ExUnit.Case, async: true

  alias Realtime.LogFilter

  describe "filter/2 - gen_statem crash reports" do
    test "stops DBConnection.ConnectionError crashes" do
      event = gen_statem_event(%DBConnection.ConnectionError{message: "tcp connect: connection refused"})
      assert :stop = LogFilter.filter(event, [])
    end

    test "passes through gen_statem crashes for other reasons" do
      event = gen_statem_event(:some_other_reason)
      assert ^event = LogFilter.filter(event, [])
    end

    test "passes through non-gen_statem reports" do
      event = %{msg: {:report, %{label: {:supervisor, :child_terminated}}}, meta: %{}}
      assert ^event = LogFilter.filter(event, [])
    end
  end

  describe "filter/2 - DBConnection.Connection log calls" do
    test "stops messages from DBConnection.Connection" do
      event = db_connection_log_event("Postgrex.Protocol failed to connect: connection refused")
      assert :stop = LogFilter.filter(event, [])
    end

    test "passes through messages from other modules" do
      event = %{msg: {:string, "some log"}, meta: %{mfa: {SomeOtherModule, :some_fun, 1}}}
      assert ^event = LogFilter.filter(event, [])
    end

    test "passes through messages with no mfa metadata" do
      event = %{msg: {:string, "some log"}, meta: %{}}
      assert ^event = LogFilter.filter(event, [])
    end
  end

  describe "filter/2 - Ranch connection killed reports" do
    test "stops Ranch reports when connection was killed" do
      event = ranch_event(RealtimeWeb.Endpoint.HTTP, :cowboy_clear, self(), :killed)
      assert :stop = LogFilter.filter(event, [])
    end

    test "passes through Ranch reports when connection exited for other reasons" do
      event = ranch_event(RealtimeWeb.Endpoint.HTTP, :cowboy_clear, self(), :some_error)
      assert ^event = LogFilter.filter(event, [])
    end
  end

  describe "setup/0" do
    test "installs the primary filter" do
      LogFilter.setup()
      %{filters: filters} = :logger.get_primary_config()
      assert List.keymember?(filters, :connection_noise, 0)
    end

    test "is idempotent when called multiple times" do
      LogFilter.setup()
      assert :ok = LogFilter.setup()
    end
  end

  defp gen_statem_event(reason) do
    %{
      msg: {:report, %{label: {:gen_statem, :terminate}, name: self(), reason: {:error, reason, []}}},
      meta: %{pid: self(), time: System.system_time()}
    }
  end

  @ranch_format "Ranch listener ~p had connection process started with ~p:start_link/3 at ~p exit with reason: ~0p~n"

  defp ranch_event(ref, protocol, pid, reason) do
    %{msg: {:format, @ranch_format, [ref, protocol, pid, reason]}, meta: %{pid: self()}}
  end

  defp db_connection_log_event(message) do
    %{
      msg: {:string, message},
      meta: %{mfa: {DBConnection.Connection, :handle_event, 4}, pid: self()}
    }
  end
end
