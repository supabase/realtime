defmodule Realtime.PromEx.Plugins.MusterTest do
  # async: false - mutates the :muster_scope app env and a shared persistent_term
  use ExUnit.Case, async: false
  alias Realtime.PromEx.Plugins

  @scope :muster_prom_ex_test

  defmodule MetricsTest do
    use PromEx, otp_app: :metrics_test
    @impl true
    def plugins do
      [{Plugins.Muster, poll_rate: 100}]
    end
  end

  setup_all do
    previous_scope = Application.get_env(:realtime, :muster_scope)
    Application.put_env(:realtime, :muster_scope, @scope)
    start_supervised!(MetricsTest)

    on_exit(fn ->
      Application.put_env(:realtime, :muster_scope, previous_scope)
      :persistent_term.erase({Forum.Muster, @scope, :status})
    end)

    :ok
  end

  describe "polling metrics" do
    test "emits a one-hot gauge: 1 for the current state, 0 for the others" do
      :persistent_term.put({Forum.Muster, @scope, :status}, :converging)

      metrics = poll()

      assert value(metrics, state: "ready") == 0
      assert value(metrics, state: "converging") == 1
      assert value(metrics, state: "rebalancing") == 0
    end

    test "reflects a state transition on the next poll" do
      :persistent_term.put({Forum.Muster, @scope, :status}, :ready)

      metrics = poll()
      assert value(metrics, state: "ready") == 1
      assert value(metrics, state: "converging") == 0
      assert value(metrics, state: "rebalancing") == 0

      :persistent_term.put({Forum.Muster, @scope, :status}, :rebalancing)

      metrics = poll()
      assert value(metrics, state: "ready") == 0
      assert value(metrics, state: "converging") == 0
      assert value(metrics, state: "rebalancing") == 1
    end

    test "reports every state as 0 before the coordinator has published a status" do
      :persistent_term.erase({Forum.Muster, @scope, :status})

      metrics = poll()

      assert value(metrics, state: "ready") == 0
      assert value(metrics, state: "converging") == 0
      assert value(metrics, state: "rebalancing") == 0
    end
  end

  # PromEx polls every 100ms; sleep two cycles so a poll runs after the
  # persistent_term the test just set, then read the accumulated last_value.
  defp poll do
    Process.sleep(250)
    PromEx.get_metrics(MetricsTest)
  end

  defp value(metrics, tags),
    do: MetricsHelper.search(metrics, "muster_node_status", Keyword.put(tags, :scope, @scope))
end
