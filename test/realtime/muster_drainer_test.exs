defmodule Realtime.MusterDrainerTest do
  use ExUnit.Case, async: true

  alias Forum.Muster

  setup do
    scope = :"drainer_test_#{System.unique_integer([:positive])}"

    # Singleton scope: no peers to evacuate to, so drain replies :ok immediately.
    start_supervised!({Forum.Muster, [scope, [singleton_promotion_timeout_ms: 100]]})

    %{scope: scope}
  end

  test "terminating the drainer runs Muster.drain and stops accepting joins", %{scope: scope} do
    # Sanity: joins are accepted before any drain.
    assert :persistent_term.get({Forum.Muster, scope, :accepting_joins}, true) == true

    # The app already runs a Realtime.MusterDrainer under its own name, so give
    # this test instance a distinct registered name.
    drainer = start_supervised!({Realtime.MusterDrainer, scope: scope, name: :"drainer_#{scope}"})

    # Terminate it the way the app supervisor would on shutdown; its trap_exit +
    # terminate/2 runs the drain.
    :ok = stop_supervised!(Realtime.MusterDrainer)
    refute Process.alive?(drainer)

    # drain/2 flipped accepting_joins off, and a racing join now fails loudly.
    assert :persistent_term.get({Forum.Muster, scope, :accepting_joins}) == false

    pid = spawn(fn -> Process.sleep(:infinity) end)
    assert Muster.join(scope, "some_group", pid) == {:error, :draining}
  end
end
