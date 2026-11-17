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

  describe "start/3, advance/4, open_topics/1 and summarize/1" do
    @a {"t", "a", :missing}
    @b {"t", "b", :ghost}

    test "start opens the candidates of the views and counts the entries and the kinds" do
      phoenix = %{"t1" => ["a", "b", "c"], "t2" => ["e"]}
      rollcall = %{"t1" => ["c", "d"]}

      state = Comparison.start(phoenix, rollcall, 10)

      assert Enum.sort(state.open) == [
               {"t1", "a", :missing},
               {"t1", "b", :missing},
               {"t1", "d", :ghost},
               {"t2", "e", :missing}
             ]

      # The union is a, b, c, d and e. Phoenix alone has 4 refs, and the two views together have 6.
      assert state.entries == 5
      assert state.candidates == %{missing: 3, ghost: 1}
      assert state.persistent == []
      assert state.rungs == []
    end

    test "advance keeps the open candidates and counts each rung by kind" do
      state = Comparison.start(%{"t" => ["a", "c", "d"]}, %{"t" => ["b"]}, 10)

      # a: open. b: open. c: in both views. d: in neither view.
      state = Comparison.advance(state, 1, %{"t" => ["a", "c"]}, %{"t" => ["b", "c"]})

      assert Enum.sort(state.open) == [@a, @b]

      # The views do not hold c and d any more. A closed candidate is not checked again.
      state = Comparison.advance(state, 3, %{"t" => ["a"]}, %{"t" => ["a", "b"]})

      assert state.open == [@b]

      assert state.rungs |> Enum.sort_by(&{&1.rung, &1.kind}) == [
               %{rung: 1, kind: :ghost, open: 1, converged: 0, gone: 0},
               %{rung: 1, kind: :missing, open: 1, converged: 1, gone: 1},
               %{rung: 3, kind: :ghost, open: 1, converged: 0, gone: 0},
               %{rung: 3, kind: :missing, open: 0, converged: 1, gone: 0}
             ]
    end

    test "a candidate that is open after the persistent rung stays persistent when it converges later" do
      state = Comparison.start(%{"t" => ["a", "c"]}, %{"t" => ["b"]}, 10)

      state =
        state
        |> Comparison.advance(1, %{"t" => ["a", "c"]}, %{"t" => ["b"]})
        |> Comparison.advance(10, %{"t" => ["a", "c"]}, %{"t" => ["b", "c"]})
        |> Comparison.advance(15, %{"t" => ["a", "b"]}, %{"t" => ["a", "b"]})

      # Both candidates converge at rung 15, so none is open at the end.
      assert state.open == []

      summary = Comparison.summarize(state)

      assert summary.outcome == :persistent
      assert summary.candidates == %{missing: 2, ghost: 1}
      assert Enum.sort(summary.persistent) == [@a, @b]
    end

    test "summarize gives the outcome clean when the views are equal" do
      summary = Comparison.summarize(Comparison.start(%{"t" => ["a"]}, %{"t" => ["a"]}, 10))

      assert summary == %{
               outcome: :clean,
               entries: 1,
               candidates: %{missing: 0, ghost: 0},
               persistent: [],
               rungs: []
             }
    end

    test "summarize gives the outcome transient when no candidate is open after the persistent rung" do
      state =
        %{"t" => ["a"]}
        |> Comparison.start(%{"t" => ["b"]}, 10)
        |> Comparison.advance(1, %{"t" => ["a"]}, %{"t" => ["a"]})

      summary = Comparison.summarize(state)

      assert summary.outcome == :transient
      assert summary.candidates == %{missing: 1, ghost: 1}
      assert summary.persistent == []
    end

    test "open_topics gives each topic of an open candidate once" do
      phoenix = %{"t1" => ["a", "b"], "t2" => ["c"]}

      state = Comparison.start(phoenix, %{}, 10)

      assert Enum.sort(Comparison.open_topics(state)) == ["t1", "t2"]

      # a and c converge. Only b is open, so only t1 is left.
      state = Comparison.advance(state, 1, phoenix, %{"t1" => ["a"], "t2" => ["c"]})

      assert Comparison.open_topics(state) == ["t1"]
    end
  end
end
