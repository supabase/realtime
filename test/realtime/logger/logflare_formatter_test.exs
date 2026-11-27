defmodule Realtime.Logger.LogflareFormatterTest do
  # Global: the Logger backend, the :logger handler and the LogflareApiClient stub are node-wide
  use ExUnit.Case, async: false
  use Mimic

  require Logger

  alias Realtime.Logger.LogflareFormatter

  setup :set_mimic_global

  defmodule Crasher do
    @moduledoc false
    # A gen_statem that crashes with a FunctionClauseError, the shape of a
    # Postgrex connection crash in production: OTP domain, error_logger metadata
    # with a report_cb function, and a stacktrace entry with args
    @behaviour :gen_statem

    def callback_mode, do: :handle_event_function
    def init(marker), do: {:ok, :idle, marker}
    def handle_event(:cast, :crash, :idle, marker), do: only_ok(marker)

    def only_ok(:ok), do: :ok
  end

  defmodule CaptureHandler do
    @moduledoc false
    # A :logger handler that sends the formatted output to a test process
    def log(event, %{formatter: {formatter, formatter_config}, config: %{pid: pid}}) do
      send(pid, {:formatted, IO.iodata_to_binary(formatter.format(event, formatter_config))})
    end
  end

  describe "format/2" do
    test "writes one JSON line in the payload shape that Logflare expects" do
      event = %{
        level: :warning,
        msg: {:string, "line one\nline two"},
        meta: %{
          time: 1_764_072_000_123_456,
          mfa: {Realtime.Tenants.Connect, :handle_info, 2},
          file: ~c"lib/realtime/tenants/connect.ex",
          line: 42,
          pid: self(),
          project: "tenant-1",
          external_id: "tenant-1",
          error_code: "SomeError"
        }
      }

      output = event |> LogflareFormatter.format(%{}) |> IO.iodata_to_binary()

      assert [line, ""] = String.split(output, "\n")

      assert %{
               "message" => "line one\nline two",
               "timestamp" => "2025-11-25T12:00:00.123000Z",
               "metadata" => %{
                 "level" => "warn",
                 "project" => "tenant-1",
                 "external_id" => "tenant-1",
                 "error_code" => "SomeError",
                 "context" => %{
                   "module" => "Elixir.Realtime.Tenants.Connect",
                   "function" => "handle_info/2",
                   "file" => "lib/realtime/tenants/connect.ex",
                   "line" => 42,
                   "mfa" => ["Elixir.Realtime.Tenants.Connect", "handle_info", "2"],
                   "pid" => pid,
                   "vm" => %{"node" => node}
                 }
               }
             } = JSON.decode!(line)

      assert pid == self() |> :erlang.pid_to_list() |> to_string()
      assert node == to_string(Node.self())
    end

    test "turns terms that JSON cannot hold into strings" do
      ref = make_ref()

      event = %{
        level: :info,
        msg: {:string, "hello"},
        meta: %{time: 1_764_072_000_000_000, ref: ref, invalid: <<255, 254>>, map: %{1 => :a}}
      }

      line = event |> LogflareFormatter.format(%{}) |> IO.iodata_to_binary()

      assert %{"metadata" => metadata} = JSON.decode!(line)
      assert metadata["ref"] == inspect(ref)
      assert metadata["invalid"] == inspect(<<255, 254>>)
      assert metadata["map"] == %{"1" => "a"}
    end
  end

  describe "parity with LogflareLogger.HttpBackend" do
    setup do
      test_pid = self()

      stub(LogflareApiClient, :post_logs, fn _client, batch, _source_id ->
        send(test_pid, {:posted, batch})
        {:ok, %Tesla.Env{status: 200, body: ""}}
      end)

      previous_env = Application.get_all_env(:logflare_logger_backend)

      Application.put_all_env(
        logflare_logger_backend: [
          url: "http://localhost",
          api_key: "api-key",
          source_id: "source-id",
          flush_interval: 50,
          max_batch_size: 50,
          metadata: :all
        ]
      )

      {:ok, _} = Logger.add_backend(LogflareLogger.HttpBackend, flush: true)

      :ok =
        :logger.add_handler(:logflare_formatter_test, CaptureHandler, %{
          formatter: {LogflareFormatter, %{}},
          config: %{pid: test_pid}
        })

      on_exit(fn ->
        :logger.remove_handler(:logflare_formatter_test)
        Logger.remove_backend(LogflareLogger.HttpBackend)

        for {key, _} <- Application.get_all_env(:logflare_logger_backend),
            do: Application.delete_env(:logflare_logger_backend, key)

        Application.put_all_env(logflare_logger_backend: previous_env)
      end)
    end

    test "string message with Logger metadata" do
      marker = marker()

      Logger.metadata(project: "tenant-1", external_id: "tenant-1")
      Logger.warning("#{marker} broadcast failed", error_code: "UnableToBroadcast")

      assert_same_payload(marker)
    end

    test "error with a crash reason and a stacktrace" do
      marker = marker()

      try do
        raise ArgumentError, "boom"
      rescue
        e -> :logger.error(~c"~ts crashed", [marker], %{crash_reason: {e, __STACKTRACE__}})
      end

      assert_same_payload(marker)
    end

    test "Erlang format string with nested metadata" do
      marker = marker()

      :logger.notice(~c"~ts received ~p", [marker, {:ok, [1, 2]}], %{
        nested: %{list: [1, 2], tuple: {:a, "b"}, keyword: [x: 1]},
        pid_value: self()
      })

      assert_same_payload(marker)
    end

    test "report message" do
      marker = marker()

      :logger.info(%{marker: marker, reason: :normal, values: [1, 2, 3]})

      assert_same_payload(marker)
    end

    test "process crash from a supervised process" do
      marker = marker()

      {:ok, pid} = Task.start(fn -> raise RuntimeError, marker end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      assert_same_payload(marker)
    end

    test "gen_statem crash with a FunctionClauseError" do
      marker = marker()

      {:ok, pid} = :gen_statem.start(Crasher, marker, [])
      ref = Process.monitor(pid)
      :gen_statem.cast(pid, :crash)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      assert %{"metadata" => %{"error_logger" => %{"report_cb" => "&" <> _}, "stacktrace" => [first | _]}} =
               assert_same_payload(marker)

      assert %{"function" => "only_ok", "args" => args} = first
      assert args =~ marker
    end
  end

  defp marker, do: "marker-#{System.unique_integer([:positive])}"

  # Compares the event that the backend posts with the line from the formatter,
  # as Logflare reads both: maps with string keys, JSON values
  defp assert_same_payload(marker) do
    formatted = receive_formatted(marker)
    posted = receive_posted(marker)

    decoded = JSON.decode!(formatted)
    assert decoded == posted |> JSON.encode!() |> JSON.decode!()
    decoded
  end

  defp receive_formatted(marker) do
    receive do
      {:formatted, line} ->
        if String.contains?(line, marker), do: line, else: receive_formatted(marker)
    after
      2_000 -> flunk("formatter output with #{marker} not received")
    end
  end

  defp receive_posted(marker) do
    receive do
      {:posted, batch} ->
        case Enum.find(batch, &(&1 |> inspect(limit: :infinity) |> String.contains?(marker))) do
          nil -> receive_posted(marker)
          event -> event
        end
    after
      2_000 -> flunk("backend batch with #{marker} not received")
    end
  end
end
