defmodule Rollcall.RefOptionTest do
  use Rollcall.Case, async: true

  alias Rollcall.Transport.PublishProbe

  describe "track with the option :ref" do
    test "returns the ref and puts it in the state", %{scope: scope, rollcall: rollcall} do
      ref = "caller-ref-#{System.unique_integer([:positive])}"

      assert {:ok, ^ref} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{n: 1}, ref: ref)

      assert Rollcall.state(rollcall, scope, "partition") == [{ref, "key", %{n: 1}}]
    end

    test "publishes the ref in the diff" do
      name = unique_name()
      scope = unique_scope()

      start_supervised!(
        {Rollcall, name: name, transport: {PublishProbe, to: self(), rollcall: name}, heartbeat_period_in_ms: :manual}
      )

      {:ok, _ref} = Rollcall.track(name, self(), scope, "partition", "key", %{n: 1}, ref: "caller-ref")

      assert_receive {:published, "partition", {[{"caller-ref", "key", %{n: 1}}], []}, _state}
    end

    test "uses the ref as the previous ref of the next update", %{scope: scope, rollcall: rollcall} do
      {:ok, first} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{n: 1}, ref: "first")
      {:ok, second} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{n: 2}, ref: "second")

      assert Rollcall.state(rollcall, scope, "partition") == [{second, "key", %{n: 2, rc_prev_ref: first}}]
    end

    test "gives the supplied ref to an update that follows an update with no ref", %{scope: scope, rollcall: rollcall} do
      {:ok, generated} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{n: 1})
      {:ok, supplied} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{n: 2}, ref: "supplied")

      assert supplied == "supplied"
      assert Rollcall.state(rollcall, scope, "partition") == [{supplied, "key", %{n: 2, rc_prev_ref: generated}}]
    end

    test "leaves the next track with no ref to make its own ref", %{scope: scope, rollcall: rollcall} do
      {:ok, supplied} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{n: 1}, ref: "supplied")
      {:ok, generated} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{n: 2})

      refute generated == supplied
      assert Rollcall.state(rollcall, scope, "partition") == [{generated, "key", %{n: 2, rc_prev_ref: supplied}}]
    end

    test "makes a ref when the option is nil", %{scope: scope, rollcall: rollcall} do
      {:ok, ref} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{}, ref: nil)

      assert is_binary(ref)
      assert Rollcall.state(rollcall, scope, "partition") == [{ref, "key", %{}}]
    end

    test "removes the entry that has a supplied ref on untrack", %{scope: scope, rollcall: rollcall} do
      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{}, ref: "supplied")

      assert :ok = Rollcall.untrack(rollcall, self(), scope, "partition", "key")

      assert Rollcall.state(rollcall, scope, "partition") == []
    end
  end
end
