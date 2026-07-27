defmodule Realtime.PromEx.Plugins.MusterTest do
  # async: false - mutates the :muster_scope app env and a shared persistent_term
  use ExUnit.Case, async: false
  alias Realtime.PromEx.Plugins
  use Mimic

  setup :set_mimic_from_context

  defmodule MetricsTest do
    use PromEx, otp_app: :metrics_test
    @impl true
    def plugins do
      [{Plugins.Muster, poll_rate: 100}]
    end
  end

  setup_all do
    start_supervised!(MetricsTest)
    :ok
  end

  describe "polling metrics" do
    test "emits a one-hot gauge: 1 for the current state, 0 for the others" do
      stub(Forum.Muster, :status, fn _ -> :converging end)

      metrics = poll()

      assert value(metrics, state: "converging") == 1
      assert value(metrics, state: "ready") == 0
      assert value(metrics, state: "rebalancing") == 0
    end

    test "reflects a state transition on the next poll" do
      stub(Forum.Muster, :status, fn _ -> :ready end)

      metrics = poll()
      assert value(metrics, state: "ready") == 1
      assert value(metrics, state: "converging") == 0
      assert value(metrics, state: "rebalancing") == 0

      stub(Forum.Muster, :status, fn _ -> :rebalancing end)

      metrics = poll()
      assert value(metrics, state: "ready") == 0
      assert value(metrics, state: "converging") == 0
      assert value(metrics, state: "rebalancing") == 1
    end

    test "reports every state as 0 before the coordinator has published a status" do
      stub(Forum.Muster, :status, fn _ -> :unknown end)

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

  defp value(metrics, tags), do: MetricsHelper.search(metrics, "muster_node_status", tags)
end
