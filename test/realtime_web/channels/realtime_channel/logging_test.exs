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
    tenant = tenant_fixture()

    on_exit(fn ->
      :telemetry.detach(__MODULE__)
      Logger.configure(level: level)
    end)

    %{tenant: tenant}
  end

  describe "log_error/3" do
    test "logs error message with JWT claims in metadata", %{tenant: tenant} do
      sub = random_string()
      exp = System.system_time(:second) + 1000
      iss = "https://#{random_string()}.com"
      token = generate_jwt_token(tenant, %{sub: sub, exp: exp, iss: iss})
      socket = %{assigns: %{log_level: :error, tenant: tenant.external_id, access_token: token}}

      log =
        capture_log(fn ->
          {:error, %{reason: "TestError: test error"}} = Logging.log_error(socket, "TestError", "test error")
        end)

      assert log =~ "TestError: test error"
      assert log =~ "sub=#{sub}"
      assert log =~ "exp=#{exp}"
      assert log =~ "iss=#{iss}"
      assert log =~ "error_code=TestError"
    end
  end

  describe "log_warning/3" do
    test "logs warning message with JWT claims in metadata", %{tenant: tenant} do
      sub = random_string()
      exp = System.system_time(:second) + 1000
      iss = "https://#{random_string()}.com"
      token = generate_jwt_token(tenant, %{sub: sub, exp: exp, iss: iss})
      socket = %{assigns: %{log_level: :warning, tenant: tenant.external_id, access_token: token}}

      log =
        capture_log(fn ->
          {:error, %{reason: "TestWarning: test warning"}} = Logging.log_warning(socket, "TestWarning", "test warning")
        end)

      assert log =~ "TestWarning: test warning"
      assert log =~ "sub=#{sub}"
      assert log =~ "exp=#{exp}"
      assert log =~ "iss=#{iss}"
      assert log =~ "error_code=TestWarning"
    end
  end

  describe "maybe_log_error/3" do
    test "logs error message when log_level is less or equal to error" do
      log_levels = [:debug, :info, :warning, :error]

      for log_level <- log_levels do
        socket = %{assigns: %{log_level: log_level, tenant: random_string(), access_token: "test_token"}}

        log =
          capture_log(fn ->
            assert Logging.maybe_log_error(socket, "TestCode", "test message") ==
                     {:error, %{reason: "TestCode: test message"}}
          end)

        assert log =~ "TestCode: test message"
        assert log =~ "error_code=TestCode"

        assert capture_log(fn ->
                 assert Logging.maybe_log_error(socket, "TestCode", %{a: "b"}) ==
                          {:error, %{reason: "TestCode: %{a: \"b\"}"}}
               end) =~ "TestCode: %{a: \"b\"}"
      end
    end

    test "does not log error message when log_level is higher than error" do
      socket = %{assigns: %{log_level: :critical, tenant: random_string(), access_token: "test_token"}}

      assert capture_log(fn ->
               assert Logging.maybe_log_error(socket, "TestCode", "test message") ==
                        {:error, %{reason: "TestCode: test message"}}
             end) == ""
    end

    test "also returns {:error, %{reason: msg}} when log_level is error" do
      socket = %{assigns: %{log_level: :error, tenant: random_string(), access_token: "test_token"}}

      assert Logging.maybe_log_error(socket, "TestCode", "test message") ==
               {:error, %{reason: "TestCode: test message"}}
    end
  end

  describe "maybe_log_warning/3" do
    test "logs error message when log_level is less or equal to warning" do
      log_levels = [:debug, :info, :warning]

      for log_level <- log_levels do
        socket = %{assigns: %{log_level: log_level, tenant: random_string(), access_token: "test_token"}}

        log =
          capture_log(fn ->
            assert Logging.maybe_log_warning(socket, "TestCode", "test message") ==
                     {:error, %{reason: "TestCode: test message"}}
          end)

        assert log =~ "TestCode: test message"
        assert log =~ "error_code=TestCode"

        assert capture_log(fn ->
                 assert Logging.maybe_log_warning(socket, "TestCode", %{a: "b"}) ==
                          {:error, %{reason: "TestCode: %{a: \"b\"}"}}
               end) =~ "TestCode: %{a: \"b\"}"
      end
    end

    test "does not log error message when log_level is higher than warning" do
      socket = %{assigns: %{log_level: :error, tenant: random_string(), access_token: "test_token"}}

      assert capture_log(fn ->
               assert Logging.maybe_log_warning(socket, "TestCode", "test message") ==
                        {:error, %{reason: "TestCode: test message"}}
             end) == ""
    end

    test "also returns {:error, %{reason: msg}} when log_level is warning" do
      socket = %{assigns: %{log_level: :warning, tenant: random_string(), access_token: "test_token"}}

      assert Logging.maybe_log_warning(socket, "TestCode", "test message") ==
               {:error, %{reason: "TestCode: test message"}}
    end
  end

  describe "maybe_log_info/3" do
    test "logs error message when log_level is less or equal to info" do
      log_levels = [:debug, :info]

      for log_level <- log_levels do
        socket = %{assigns: %{log_level: log_level, tenant: random_string(), access_token: "test_token"}}

        assert capture_log(fn -> :ok = Logging.maybe_log_info(socket, "test message") end) =~ "test message"
        assert capture_log(fn -> :ok = Logging.maybe_log_info(socket, %{a: "b"}) end) =~ "%{a: \"b\"}"
      end
    end

    test "does not log error message when log_level is higher than info" do
      socket = %{assigns: %{log_level: :warning, tenant: random_string(), access_token: "test_token"}}
      assert capture_log(fn -> :ok = Logging.maybe_log_info(socket, "test message") end) == ""
    end
  end

  test "emits telemetry for system errors" do
    socket = %{assigns: %{log_level: :error, tenant: random_string(), access_token: "test_token"}}

    for error <- Logging.system_errors() do
      assert Logging.maybe_log_error(socket, error, "test error") ==
               {:error, %{reason: "#{error}: test error"}}

      assert_receive {[:realtime, :channel, :error], %{code: ^error}, %{code: ^error}}
    end

    assert Logging.maybe_log_error(socket, "TestError", "test error") ==
             {:error, %{reason: "TestError: test error"}}

    refute_receive {[:realtime, :channel, :error], :_, :_}
  end

  test "logs include JWT claims in metadata", %{tenant: tenant} do
    sub = random_string()
    exp = System.system_time(:second) + 1000
    iss = "https://#{random_string()}.com"
    token = generate_jwt_token(tenant, %{sub: sub, exp: exp, iss: iss})
    socket = %{assigns: %{log_level: :error, tenant: tenant.external_id, access_token: token}}
    log = capture_log(fn -> Logging.maybe_log_error(socket, "TestError", "test error") end)
    assert log =~ "sub=#{sub}"
    assert log =~ "exp=#{exp}"
    assert log =~ "iss=#{iss}"
  end

  test "logs include project metadata" do
    tenant_id = random_string()
    socket = %{assigns: %{log_level: :error, tenant: tenant_id, access_token: "test_token"}}

    log = capture_log(fn -> Logging.maybe_log_error(socket, "TestError", "test error") end)
    assert log =~ tenant_id
  end
end
