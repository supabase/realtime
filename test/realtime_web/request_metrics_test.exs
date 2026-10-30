defmodule RealtimeWeb.RequestMetricsTest do
  use ExUnit.Case, async: true

  alias Phoenix.Socket
  alias RealtimeWeb.RequestMetrics

  @event RequestMetrics.event()

  # Handlers attached by :telemetry_test receive every emission in the VM, so each test gets its own
  # tenant and only matches events for it.
  setup do
    ref = :telemetry_test.attach_event_handlers(self(), [@event])
    tenant = "request-metrics-#{System.unique_integer([:positive])}"
    {:ok, ref: ref, tenant: tenant, socket: %Socket{assigns: %{}}}
  end

  describe "track/4" do
    test "records the outcome the function returns, and returns the result untouched", %{
      ref: ref,
      tenant: tenant,
      socket: socket
    } do
      assert {:noreply, ^socket} =
               RequestMetrics.track(:broadcast, :ws, tenant, fn -> {{:noreply, socket}, :success} end)

      assert_receive {@event, ^ref, %{count: 1},
                      %{tenant: ^tenant, request: :broadcast, transport: :ws, outcome: :success, reason: :none}}

      refute_receive {@event, ^ref, _, %{tenant: ^tenant}}
    end

    test "records a failure with its reason", %{ref: ref, tenant: tenant, socket: socket} do
      RequestMetrics.track(:broadcast, :ws, tenant, fn -> {{:noreply, socket}, {:rejected, :unauthorized}} end)

      assert_receive {@event, ^ref, _, %{tenant: ^tenant, outcome: :rejected, reason: :unauthorized}}
      refute_receive {@event, ^ref, _, %{tenant: ^tenant}}
    end

    # The result is not inspected, so any callback reply works and the socket is never touched.
    test "returns every reply shape unchanged", %{ref: ref, tenant: tenant, socket: socket} do
      for result <- [
            {:noreply, socket},
            {:reply, :ok, socket},
            {:stop, :normal, socket},
            {:stop, :normal, :ok, socket}
          ] do
        assert ^result = RequestMetrics.track(:broadcast, :ws, tenant, fn -> {result, :success} end)

        assert_receive {@event, ^ref, _, %{tenant: ^tenant, outcome: :success}}
      end
    end

    test "a raise is counted as an internal failure and re-raised", %{ref: ref, tenant: tenant} do
      assert_raise RuntimeError, "boom", fn ->
        RequestMetrics.track(:broadcast, :ws, tenant, fn -> raise "boom" end)
      end

      assert_receive {@event, ^ref, _, %{tenant: ^tenant, outcome: :internal_failure, reason: :error}}
      refute_receive {@event, ^ref, _, %{tenant: ^tenant}}
    end

    test "an exit and a throw are counted and re-raised", %{ref: ref, tenant: tenant} do
      assert catch_exit(RequestMetrics.track(:broadcast, :ws, tenant, fn -> exit(:shutdown) end)) == :shutdown
      assert_receive {@event, ^ref, _, %{tenant: ^tenant, outcome: :internal_failure, reason: :exit}}

      assert catch_throw(RequestMetrics.track(:broadcast, :ws, tenant, fn -> throw(:oops) end)) == :oops
      assert_receive {@event, ^ref, _, %{tenant: ^tenant, outcome: :internal_failure, reason: :throw}}
    end

    test "a crash keeps its original stacktrace", %{tenant: tenant} do
      {_, stacktrace} =
        try do
          RequestMetrics.track(:broadcast, :ws, tenant, fn -> raise "boom" end)
        rescue
          error -> {error, __STACKTRACE__}
        end

      assert Enum.any?(stacktrace, fn {module, _fun, _arity, _loc} -> module == __MODULE__ end)
    end
  end

  # An outcome is :success or {kind, reason}. Only a success has no reason of its own, so the
  # reason "none" can never be attached to a failure.
  describe "record/4" do
    test "a success records the reason :none", %{ref: ref, tenant: tenant} do
      RequestMetrics.record(:broadcast, :ws, tenant, :success)

      assert_receive {@event, ^ref, %{count: 1},
                      %{tenant: ^tenant, request: :broadcast, transport: :ws, outcome: :success, reason: :none}}
    end

    test "a failure records the kind and the reason it carries", %{ref: ref, tenant: tenant} do
      RequestMetrics.record(:broadcast, :http, tenant, {:upstream_failure, :query_canceled})

      assert_receive {@event, ^ref, %{count: 1},
                      %{tenant: ^tenant, transport: :http, outcome: :upstream_failure, reason: :query_canceled}}
    end

    test "a success cannot be given a reason", %{ref: ref, tenant: tenant} do
      assert_raise FunctionClauseError, fn -> RequestMetrics.record(:broadcast, :ws, tenant, {:success, :none}) end

      refute_receive {@event, ^ref, _, %{tenant: ^tenant}}
    end

    test "records exactly one event per call", %{ref: ref, tenant: tenant} do
      RequestMetrics.record(:broadcast, :ws, tenant, {:rejected, :unauthorized})

      assert_receive {@event, ^ref, _, %{tenant: ^tenant, outcome: :rejected}}
      refute_receive {@event, ^ref, _, %{tenant: ^tenant}}
    end
  end

  describe "classify_broadcast_error/1" do
    test "client-caused errors are rejected" do
      assert {:rejected, :unauthorized} = RequestMetrics.classify_broadcast_error(:unauthorized)
      assert {:rejected, :payload_size_exceeded} = RequestMetrics.classify_broadcast_error(:payload_size_exceeded)
      assert {:rejected, :invalid_persist_ttl} = RequestMetrics.classify_broadcast_error(:invalid_persist_ttl)

      assert {:rejected, :persistence_unauthorized} =
               RequestMetrics.classify_broadcast_error(:persistence_unauthorized)
    end

    test "dependency errors are upstream failures" do
      for code <- [
            :rls_policy_error,
            :query_canceled,
            :unable_to_connect_to_project,
            :database_lack_of_connections,
            :database_connection_rate_limit_reached,
            :initializing_project_connection,
            :increase_connection_pool,
            :persistence_failed
          ] do
        assert {:upstream_failure, ^code} = RequestMetrics.classify_broadcast_error(code)
      end
    end

    test "anything else, including unknown codes, is an internal failure" do
      for code <- [:missing_partition, :unable_to_set_policies, :unable_to_handle_broadcast, :brand_new] do
        assert {:internal_failure, ^code} = RequestMetrics.classify_broadcast_error(code)
      end
    end
  end
end
