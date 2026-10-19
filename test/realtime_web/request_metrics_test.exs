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

  describe "put_outcome/3" do
    test "stores the outcome and reason on the socket", %{socket: socket} do
      socket = RequestMetrics.put_outcome(socket, :rejected, :unauthorized)

      assert socket.assigns.request_outcome == {:rejected, :unauthorized}
    end

    test "the first outcome wins", %{socket: socket} do
      socket =
        socket
        |> RequestMetrics.put_outcome(:upstream_failure, :query_canceled)
        |> RequestMetrics.put_outcome(:internal_failure, :unable_to_set_policies)

      assert socket.assigns.request_outcome == {:upstream_failure, :query_canceled}
    end
  end

  describe "track/3" do
    test "records success when no outcome was put, and returns the result", %{socket: socket} do
      assert {:noreply, ^socket} = RequestMetrics.track(:broadcast, :ws, fn -> {:noreply, socket} end)

      assert_receive {:outcome, %{count: 1}, %{request: :broadcast, transport: :ws, outcome: :success, reason: :none}}
      refute_receive {:outcome, _, _}
    end

    test "records the outcome put on the returned socket", %{socket: socket} do
      RequestMetrics.track(:broadcast, :ws, fn ->
        {:noreply, RequestMetrics.put_outcome(socket, :rejected, :unauthorized)}
      end)

      assert_receive {:outcome, _, %{outcome: :rejected, reason: :unauthorized}}
      refute_receive {:outcome, _, _}
    end

    test "finds the socket in every reply shape and clears the outcome from it", %{socket: socket} do
      marked = RequestMetrics.put_outcome(socket, :rejected, :unauthorized)

      for {result, socket_at} <- [
            {{:noreply, marked}, 1},
            {{:reply, :ok, marked}, 2},
            {{:stop, :normal, marked}, 2},
            {{:stop, :normal, :ok, marked}, 3}
          ] do
        returned = RequestMetrics.track(:broadcast, :ws, fn -> result end)

        assert_receive {:outcome, _, %{outcome: :rejected, reason: :unauthorized}}
        refute Map.get(elem(returned, socket_at).assigns, :request_outcome)
      end
    end

    test "an outcome does not leak into the next request", %{socket: socket} do
      {:noreply, socket} =
        RequestMetrics.track(:broadcast, :ws, fn ->
          {:noreply, RequestMetrics.put_outcome(socket, :rejected, :unauthorized)}
        end)

      assert_receive {:outcome, _, %{outcome: :rejected}}

      RequestMetrics.track(:broadcast, :ws, fn -> {:noreply, socket} end)
      assert_receive {:outcome, _, %{outcome: :success, reason: :none}}
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
  end

  describe "record/3 and record/4" do
    test "a success needs no reason and records :none" do
      RequestMetrics.record(:broadcast, :ws, :success)

      assert_receive {:outcome, %{count: 1}, %{outcome: :success, reason: :none}}
    end

    test "every other outcome must give a reason" do
      for outcome <- [:rejected, :internal_failure, :upstream_failure] do
        assert_raise FunctionClauseError, fn -> RequestMetrics.record(:broadcast, :ws, outcome) end
      end

      refute_receive {:outcome, _, _}
    end

    test "records the reason it is given" do
      RequestMetrics.record(:broadcast, :ws, :upstream_failure, :query_canceled)

      assert_receive {:outcome, %{count: 1}, %{outcome: :upstream_failure, reason: :query_canceled}}
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
