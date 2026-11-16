defmodule Realtime.Presence.ComparisonTest do
  use ExUnit.Case, async: true

  alias Realtime.Presence.Comparison

  describe "diff/2" do
    test "finds the refs that only one view holds, and nothing for equal topics" do
      phoenix = %{"t1" => ["a", "b"], "t2" => ["c"]}
      rollcall = %{"t1" => ["b", "d"], "t2" => ["c"]}

      assert Enum.sort(Comparison.diff(phoenix, rollcall)) == [{"t1", "a", :missing}, {"t1", "d", :ghost}]
    end

    test "finds every ref of a topic that only one view holds" do
      phoenix = %{"only-phoenix" => ["a", "b"]}
      rollcall = %{"only-rollcall" => ["c"]}

      assert Enum.sort(Comparison.diff(phoenix, rollcall)) ==
               [{"only-phoenix", "a", :missing}, {"only-phoenix", "b", :missing}, {"only-rollcall", "c", :ghost}]
    end
  end

  describe "step/3" do
    test "converges a candidate when the ref is in both views or has moved to the other view" do
      candidates = [{"t", "a", :missing}, {"t", "b", :ghost}, {"t", "c", :missing}]
      phoenix = %{"t" => ["a", "b"]}
      rollcall = %{"t" => ["a", "c"]}

      assert Enum.sort(Comparison.step(candidates, phoenix, rollcall)) ==
               [
                 {{"t", "a", :missing}, :converged},
                 {{"t", "b", :ghost}, :converged},
                 {{"t", "c", :missing}, :converged}
               ]
    end

    test "keeps a candidate open while one view holds the ref, and ends it when neither view does" do
      candidates = [
        {"t", "a", :missing},
        {"t", "b", :ghost},
        {"t", "c", :missing},
        {"t", "d", :ghost},
        {"left-both", "e", :missing}
      ]

      phoenix = %{"t" => ["a"]}
      rollcall = %{"t" => ["b"]}

      assert Enum.sort(Comparison.step(candidates, phoenix, rollcall)) ==
               [
                 {{"left-both", "e", :missing}, :gone},
                 {{"t", "a", :missing}, :open},
                 {{"t", "b", :ghost}, :open},
                 {{"t", "c", :missing}, :gone},
                 {{"t", "d", :ghost}, :gone}
               ]
    end
  end
end
