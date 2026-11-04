defmodule Rollcall.OptionsTest do
  # A test that needs options starts its own instance with `start_instance/1`.
  use Rollcall.Case, async: true

  import Rollcall.NetworkHelpers
  import Rollcall.Tracker.Messages, only: [snapshot: 3, stamp: 2]

  alias Rollcall.Tracker
  alias Rollcall.Transport.FailInit
  alias Rollcall.Transport.InMemory

  @probe :probe@host

  describe "transport" do
    test "gives the transport to a tracker that track/6 starts", %{scope: scope} do
      network = start_network()
      rollcall = start_instance(transport: in_memory(network))
      probe = join_probe(network, scope, @probe)

      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{})
      tracker = Tracker.whereis(rollcall, scope)
      # The goodbye is the first message that a stopped tracker sends.
      :ok = GenServer.stop(tracker)

      assert {:snapshot, _origin, _stamp, []} = receive_message(probe)
    end

    # The transport fails once. A retry of the start would hide the error.
    test "track/6 returns the error when init/2 of the transport fails", %{scope: scope} do
      rollcall = start_instance(transport: failing_transport(1))

      assert {:error, {%RuntimeError{message: "transport init failed"}, _stacktrace}} =
               Rollcall.track(rollcall, self(), scope, "partition", "key", %{})

      assert Tracker.whereis(rollcall, scope) == nil
    end

    test "track/6 starts a tracker after a start error", %{scope: scope} do
      rollcall = start_instance(transport: failing_transport(1))

      assert {:error, _reason} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{})
      assert {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{})
      assert scope in Rollcall.scopes(rollcall)
    end
  end

  describe "heartbeat_period_in_ms" do
    test "gives the period to a tracker that track/6 starts", %{scope: scope} do
      network = start_network()
      rollcall = start_instance(transport: in_memory(network), heartbeat_period_in_ms: 20)
      probe = join_probe(network, scope, @probe)

      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{})

      # The default period is 1500 ms. A tick inside 500 ms shows that the option is in use.
      assert {:snapshot, _origin, _stamp, _entries} = receive_message(probe, 500)
    end
  end

  describe "silence_threshold" do
    test "gives the threshold to a tracker that track/6 starts", %{scope: scope} do
      network = start_network()

      rollcall =
        start_instance(transport: in_memory(network), heartbeat_period_in_ms: :manual, silence_threshold: 2)

      probe = join_probe(network, scope, @probe)

      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{})
      tracker = Tracker.whereis(rollcall, scope)
      send_from_probe(probe, snapshot(self(), stamp(1, 1), []))
      sync(tracker)

      # The default threshold is 10 ticks. A purge after 2 ticks shows that the option is in use.
      tick(tracker)
      assert peer(tracker, @probe)

      tick(tracker)
      refute peer(tracker, @probe)
    end
  end

  describe "empty_grace_in_ms" do
    test "gives the grace period to a tracker that track/6 starts", %{scope: scope} do
      rollcall = start_instance(empty_grace_in_ms: 1_234)

      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{})
      tracker = Tracker.whereis(rollcall, scope)
      :ok = Rollcall.untrack(rollcall, self(), scope, "partition", "key")

      assert_timer_within(tracker, 1_234)
    end
  end

  # The checks raise before the library starts a process, so these tests start
  # no instance.
  describe "start_link/1" do
    test "raises for an unknown option" do
      assert_raise ArgumentError, ~r/unknown/, fn -> Rollcall.start_link(name: :options_test, unknown: 1) end
    end

    test "raises when the option :name is missing" do
      assert_raise ArgumentError, ~r/name/, fn -> Rollcall.start_link([]) end
    end

    test "raises when the option :name is not an atom" do
      assert_raise ArgumentError, ~r/invalid value for the option :name/, fn ->
        Rollcall.start_link(name: "options_test")
      end
    end

    for {key, value} <- [
          transport: :not_a_tuple,
          transport: {"module", []},
          transport: {Rollcall.Transport.Null, :not_a_list},
          heartbeat_period_in_ms: 0,
          heartbeat_period_in_ms: :auto,
          silence_threshold: 0,
          silence_threshold: :many,
          empty_grace_in_ms: -1,
          empty_grace_in_ms: "5000"
        ] do
      test "raises when #{key} is #{inspect(value)}" do
        assert_raise ArgumentError, ~r/invalid value for the option #{inspect(unquote(key))}/, fn ->
          Rollcall.start_link([{:name, :options_test}, {unquote(key), unquote(Macro.escape(value))}])
        end
      end
    end
  end

  describe "Tracker.start_link/1" do
    test "sets the grace period with the option :empty_grace_in_ms", %{scope: scope, rollcall: rollcall} do
      tracker = start_supervised!({Tracker, {scope, name: rollcall, empty_grace_in_ms: 1_234}})

      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{})
      :ok = Rollcall.untrack(rollcall, self(), scope, "partition", "key")

      assert_timer_within(tracker, 1_234)
    end
  end

  # Starts an instance with `opts` and returns its name. The test supervisor
  # stops the instance when the test ends. Start the network before the
  # instance. The trackers send their goodbye through the network when they stop.
  defp start_instance(opts) do
    name = unique_name()
    start_supervised!({Rollcall, [name: name] ++ opts})
    name
  end

  defp in_memory(network), do: {InMemory, network: network, node: :a@host}

  # A transport whose `init/2` raises for the first `failures` starts.
  defp failing_transport(failures) do
    counter = :atomics.new(1, [])
    :atomics.put(counter, 1, failures)

    {FailInit, failures: counter}
  end

  # The tracker starts the timer when its last entry leaves. The default length
  # is 5000 ms, so a value up to `length` shows that the option is in use.
  defp assert_timer_within(tracker, length) do
    remaining = :erlang.read_timer(:sys.get_state(tracker).empty_timer)

    assert is_integer(remaining)
    assert remaining > 0
    assert remaining <= length
  end
end
