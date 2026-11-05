defmodule Rollcall.UseTest do
  # The instances are named after their modules, so these tests share two names
  # and cannot run concurrently.
  use Rollcall.Case, async: false

  alias Rollcall.Tracker
  alias Rollcall.Tracker.Local

  # The modules compile at run time, as the tests for a compile error do. A
  # compile error then fails a test and not the suite.
  setup_all do
    modules = [Rollcall.UseTest.Instance, Rollcall.UseTest.Tuned]

    Code.compile_string("""
    defmodule Rollcall.UseTest.Instance do
      use Rollcall
    end

    defmodule Rollcall.UseTest.Tuned do
      use Rollcall, empty_grace_in_ms: 60_000
    end
    """)

    on_exit(fn ->
      for module <- modules do
        :code.purge(module)
        :code.delete(module)
      end
    end)

    {:ok, instance: Rollcall.UseTest.Instance, tuned: Rollcall.UseTest.Tuned}
  end

  describe "the functions of use Rollcall" do
    test "act on the instance named after the module", %{scope: scope, instance: instance} do
      start_supervised!(instance)

      {:ok, ref} = instance.track(self(), scope, "partition", "key", %{})

      assert scope in instance.scopes()
      assert [%{ref: ^ref}] = Local.entries(Tracker.get_state(instance, scope).local, "partition")

      assert :ok = instance.untrack(self(), scope, "partition", "key")
      assert Local.entries(Tracker.get_state(instance, scope).local, "partition") == []
    end

    test "give the options of use to the trackers", %{scope: scope, tuned: tuned} do
      start_supervised!(tuned)

      # The default grace period is 5000 ms, so a longer timer shows that the option is in use.
      assert grace_timer(tuned, scope) > 5_000
    end

    test "replace an option of use with the option of start_link/1", %{scope: scope, tuned: tuned} do
      start_supervised!({tuned, empty_grace_in_ms: 1_234})

      remaining = grace_timer(tuned, scope)

      assert remaining > 0
      assert remaining <= 1_234
    end

    test "do not accept the option :name in start_link/1", %{instance: instance} do
      assert_raise ArgumentError, ~r/unknown/, fn -> instance.start_link(name: :other) end
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
