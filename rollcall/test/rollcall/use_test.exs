defmodule Rollcall.UseTest do
  # The instances are named after their modules, so these tests share two names
  # and cannot run concurrently.
  use Rollcall.Case, async: false

  alias Rollcall.Tracker
  alias Rollcall.Tracker.Local

  defmodule Instance do
    use Rollcall
  end

  defmodule Tuned do
    use Rollcall, empty_grace_in_ms: 60_000
  end

  describe "the functions of use Rollcall" do
    test "act on the instance named after the module", %{scope: scope} do
      start_supervised!(Instance)

      {:ok, ref} = Instance.track(self(), scope, "partition", "key", %{})

      assert scope in Instance.scopes()
      assert [%{ref: ^ref}] = Local.entries(Tracker.get_state(Instance, scope).local, "partition")
      assert Instance.state(scope, "partition") == [{ref, "key", %{}}]
      assert Instance.state(scope) == [{"partition", ref, "key", %{}}]

      assert :ok = Instance.untrack(self(), scope, "partition", "key")
      assert Local.entries(Tracker.get_state(Instance, scope).local, "partition") == []
    end

    test "ensure_started/1 starts a tracker on the instance named after the module", %{scope: scope} do
      start_supervised!(Instance)

      assert :ok = Instance.ensure_started(scope)

      assert is_pid(Tracker.whereis(Instance, scope))
      assert scope in Instance.scopes()
    end

    test "pass the option :ref of track to the tracker", %{scope: scope} do
      start_supervised!(Instance)

      assert {:ok, "caller-ref"} = Instance.track(self(), scope, "partition", "key", %{}, ref: "caller-ref")

      assert Instance.state(scope, "partition") == [{"caller-ref", "key", %{}}]
    end

    test "give the options of use to the trackers", %{scope: scope} do
      start_supervised!(Tuned)

      # The default grace period is 5000 ms, so a longer timer shows that the option is in use.
      assert grace_timer(Tuned, scope) > 5_000
    end

    test "replace an option of use with the option of start_link/1", %{scope: scope} do
      start_supervised!({Tuned, empty_grace_in_ms: 1_234})

      remaining = grace_timer(Tuned, scope)

      assert remaining > 0
      assert remaining <= 1_234
    end

    test "do not accept the option :name in start_link/1" do
      assert_raise ArgumentError, ~r/unknown/, fn -> Instance.start_link(name: :other) end
    end
  end

  describe "use Rollcall" do
    test "raises at compile time for the option :name" do
      assert_raise ArgumentError, fn ->
        Code.compile_string("""
        defmodule Rollcall.UseTest.Invalid do
          use Rollcall, name: :other
        end
        """)
      end
    end
  end

  # Tracks and untracks an entry, so the tracker starts its grace timer. Returns
  # the milliseconds that remain on the timer.
  defp grace_timer(instance, scope) do
    {:ok, _ref} = instance.track(self(), scope, "partition", "key", %{})
    :ok = instance.untrack(self(), scope, "partition", "key")

    instance |> Tracker.whereis(scope) |> :sys.get_state() |> Map.fetch!(:empty_timer) |> :erlang.read_timer()
  end
end
