defmodule RealtimeWeb.RequestMetricsTest do
  use ExUnit.Case, async: true

  alias Phoenix.Socket
  alias RealtimeWeb.RequestMetrics

  # Telemetry handlers are global and run in the emitting process, so forward only this test's events.
  def forward(_event, measurements, metadata, test_pid) do
    if self() == test_pid, do: send(test_pid, {:outcome, measurements, metadata})
  end

  setup do
    id = {__MODULE__, make_ref()}
    :telemetry.attach(id, RequestMetrics.event(), &__MODULE__.forward/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
    {:ok, socket: %Socket{assigns: %{}}}
  end

  describe "track/3" do
    test "records the outcome the function returns, and returns the result untouched", %{socket: socket} do
      assert {:noreply, ^socket} = RequestMetrics.track(:broadcast, :ws, fn -> {{:noreply, socket}, :success} end)

      assert_receive {:outcome, %{count: 1}, %{request: :broadcast, transport: :ws, outcome: :success, reason: :none}}
      refute_receive {:outcome, _, _}
    end

    test "records a failure with its reason", %{socket: socket} do
      RequestMetrics.track(:broadcast, :ws, fn -> {{:noreply, socket}, {:rejected, :unauthorized}} end)

      assert_receive {:outcome, _, %{outcome: :rejected, reason: :unauthorized}}
      refute_receive {:outcome, _, _}
    end

    # The result is not inspected, so any callback reply works and the socket is never touched.
    test "returns every reply shape unchanged", %{socket: socket} do
      for result <- [
            {:noreply, socket},
            {:reply, :ok, socket},
            {:stop, :normal, socket},
            {:stop, :normal, :ok, socket}
          ] do
        assert ^result = RequestMetrics.track(:broadcast, :ws, fn -> {result, :success} end)

        assert_receive {:outcome, _, %{outcome: :success}}
      end
    end

    test "a raise is counted as an internal failure and re-raised" do
      assert_raise RuntimeError, "boom", fn ->
        RequestMetrics.track(:broadcast, :ws, fn -> raise "boom" end)
      end

      assert_receive {:outcome, _, %{outcome: :internal_failure, reason: :error}}
      refute_receive {:outcome, _, _}
    end

    test "an exit and a throw are counted and re-raised" do
      assert catch_exit(RequestMetrics.track(:broadcast, :ws, fn -> exit(:shutdown) end)) == :shutdown
      assert_receive {:outcome, _, %{outcome: :internal_failure, reason: :exit}}

      assert catch_throw(RequestMetrics.track(:broadcast, :ws, fn -> throw(:oops) end)) == :oops
      assert_receive {:outcome, _, %{outcome: :internal_failure, reason: :throw}}
    end

    test "a crash keeps its original stacktrace" do
      {_, stacktrace} =
        try do
          RequestMetrics.track(:broadcast, :ws, fn -> raise "boom" end)
        rescue
          error -> {error, __STACKTRACE__}
        end

      assert Enum.any?(stacktrace, fn {module, _fun, _arity, _loc} -> module == __MODULE__ end)
    end
  end

  # An outcome is :success or {kind, reason}. Only a success has no reason of its own, so the
  # reason "none" can never be attached to a failure.
  describe "record/3" do
    test "a success records the reason :none" do
      RequestMetrics.record(:broadcast, :ws, :success)

      assert_receive {:outcome, %{count: 1}, %{request: :broadcast, transport: :ws, outcome: :success, reason: :none}}
    end

    test "a failure records the kind and the reason it carries" do
      RequestMetrics.record(:broadcast, :http, {:upstream_failure, :query_canceled})

      assert_receive {:outcome, %{count: 1}, %{transport: :http, outcome: :upstream_failure, reason: :query_canceled}}
    end

    test "a success cannot be given a reason" do
      assert_raise FunctionClauseError, fn -> RequestMetrics.record(:broadcast, :ws, {:success, :none}) end

      refute_receive {:outcome, _, _}
    end

    test "records exactly one event per call" do
      RequestMetrics.record(:broadcast, :ws, {:rejected, :unauthorized})

      assert_receive {:outcome, _, %{outcome: :rejected}}
      refute_receive {:outcome, _, _}
    end
  end

  describe "classify_broadcast_error/1" do
    test "client-caused errors are rejected" do
      assert {:rejected, :unauthorized} = RequestMetrics.classify_broadcast_error(:unauthorized)
      assert {:rejected, :payload_size_exceeded} = RequestMetrics.classify_broadcast_error(:payload_size_exceeded)
    end

    test "dependency errors are upstream failures" do
      for code <- [
            :rls_policy_error,
            :query_canceled,
            :unable_to_connect_to_project,
            :database_lack_of_connections,
            :database_connection_rate_limit_reached,
            :initializing_project_connection,
            :increase_connection_pool
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
