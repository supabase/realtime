defmodule Rollcall.InstancesTest do
  # Each test starts its own instances, next to the instance of `Rollcall.Case`.
  # Instances share no process, so the tests can run concurrently.
  use Rollcall.Case, async: true

  alias Rollcall.Tracker
  alias Rollcall.Tracker.Local

  describe "two instances" do
    test "run a tracker each for one scope, with separate entries", %{scope: scope} do
      a = start_instance()
      b = start_instance()

      {:ok, ref_a} = Rollcall.track(a, self(), scope, "partition", "key_a", %{})
      {:ok, ref_b} = Rollcall.track(b, self(), scope, "partition", "key_b", %{})

      tracker_a = Tracker.whereis(a, scope)
      tracker_b = Tracker.whereis(b, scope)

      assert is_pid(tracker_a)
      assert is_pid(tracker_b)
      refute tracker_a == tracker_b
      assert [%{ref: ^ref_a}] = Local.entries(Tracker.get_state(a, scope).local, "partition")
      assert [%{ref: ^ref_b}] = Local.entries(Tracker.get_state(b, scope).local, "partition")
    end

    test "list only the scopes of their own tracker", %{scope: scope} do
      a = start_instance()
      b = start_instance()
      other_scope = unique_scope()

      {:ok, _ref} = Rollcall.track(a, self(), scope, "partition", "key", %{})
      {:ok, _ref} = Rollcall.track(b, self(), other_scope, "partition", "key", %{})

      assert scope in Rollcall.scopes(a)
      refute other_scope in Rollcall.scopes(a)
      assert other_scope in Rollcall.scopes(b)
      refute scope in Rollcall.scopes(b)
    end

    test "keep running when the other instance stops", %{scope: scope} do
      a = start_instance()
      b = start_instance()
      {:ok, _ref} = Rollcall.track(a, self(), scope, "partition", "key", %{})
      {:ok, _ref} = Rollcall.track(b, self(), scope, "partition", "key", %{})
      tracker_b = Tracker.whereis(b, scope)

      stop_supervised!(a)

      assert Process.alive?(tracker_b)
      assert Tracker.whereis(b, scope) == tracker_b
      assert {:ok, _ref} = Rollcall.track(b, self(), scope, "partition", "other_key", %{})
    end

    test "use their own options", %{scope: scope} do
      short = start_instance(empty_grace_in_ms: 1_234)
      long = start_instance(empty_grace_in_ms: 60_000)

      short_timer = grace_timer(short, scope)
      long_timer = grace_timer(long, scope)

      assert short_timer > 0
      assert short_timer <= 1_234
      assert long_timer > 5_000
    end
  end

  describe "untrack/5" do
    test "returns :ok when no instance has the name", %{scope: scope} do
      assert :ok = Rollcall.untrack(unique_name(), self(), scope, "partition", "key")
    end
  end

  # Starts an instance with `opts` and returns its name. The test supervisor
  # stops the instance when the test ends. The id of the child is the name, so
  # a test can stop one instance with `stop_supervised!/1`.
  defp start_instance(opts \\ []) do
    name = unique_name()
    start_supervised!(Supervisor.child_spec({Rollcall, [name: name] ++ opts}, id: name))
    name
  end

  # Tracks and untracks an entry, so the tracker starts its grace timer. Returns
  # the milliseconds that remain on the timer.
  defp grace_timer(rollcall, scope) do
    {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{})
    :ok = Rollcall.untrack(rollcall, self(), scope, "partition", "key")

    rollcall |> Tracker.whereis(scope) |> :sys.get_state() |> Map.fetch!(:empty_timer) |> :erlang.read_timer()
  end
end
