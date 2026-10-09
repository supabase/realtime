defmodule SqlLogex.EvalTest do
  use ExUnit.Case, async: true

  alias SqlLogex.Env
  alias SqlLogex.Eval
  alias SqlLogex.Value

  @env Env.new(
         %{"role" => "authenticated", "realtime.topic" => "room:1", "request.jwt.claim.role" => nil},
         %{"topic" => {:text, "room:1"}}
       )

  # Each of the four results as a literal IR node, and as a name for the tables below
  @nodes %{t: {:lit, true}, f: {:lit, false}, n: {:lit, nil}, u: {:unsupported, :boom}}
  @unsupported {:unsupported, :boom}

  defp eval(ir), do: Eval.eval(ir, @env)

  describe "leaves" do
    test "a literal is its value" do
      assert eval({:lit, true}) == true
      assert eval({:lit, nil}) == nil
      assert eval({:lit, {:text, "a"}}) == {:text, "a"}
      assert eval({:lit, :case_sensitive}) == :case_sensitive
    end

    test "an unsupported node is its reason" do
      assert eval({:unsupported, :boom}) == @unsupported
    end

    test "a setting is read from the env, a nil setting as the empty string" do
      assert eval({:setting, "realtime.topic"}) == {:text, "room:1"}
      assert eval({:setting, "REALTIME.TOPIC"}) == {:text, "room:1"}
      assert eval({:setting, "request.jwt.claim.role"}) == {:text, ""}
    end

    test "a setting that isn't in the env is unsupported" do
      assert eval({:setting, "app.x"}) == {:unsupported, {:unknown_setting, "app.x"}}
    end

    test "a column is read from the row, an unbound one is unsupported" do
      assert eval({:column, "topic"}) == {:text, "room:1"}
      assert eval({:column, "extension"}) == {:unsupported, {:unbound_column, "extension"}}
    end
  end

  describe "apply" do
    test "calls the primitive with the evaluated arguments" do
      ir = {:apply, Value, :text_eq, [{:column, "topic"}, {:lit, {:text, "room:1"}}]}
      assert eval(ir) == true
      assert eval({:apply, Value, :text_eq, [{:column, "topic"}, {:lit, {:text, "other"}}]}) == false
    end

    test "evaluates the arguments of nested calls" do
      ir =
        {:apply, Value, :text_eq,
         [{:apply, Value, :nullif, [{:setting, "request.jwt.claim.role"}, {:lit, {:text, ""}}]}, {:lit, {:text, "x"}}]}

      assert eval(ir) == nil
    end

    test "an array argument is the list of its evaluated elements" do
      ir =
        {:apply, Value, :text_eq_any, [{:column, "topic"}, {:array, [{:lit, {:text, "a"}}, {:lit, {:text, "room:1"}}]}]}

      assert eval(ir) == true

      assert eval({:array, [{:lit, nil}, {:lit, {:text, "a"}}]}) == [nil, {:text, "a"}]
      assert eval({:array, []}) == []
    end

    test "evaluates every argument first, so an unsupported one beats a NULL" do
      ir = {:apply, Value, :text_eq, [{:lit, nil}, {:unsupported, :boom}]}
      assert eval(ir) == @unsupported
    end

    test "the regex mode literal is passed through" do
      ir = {:apply, Value, :regex_match, [{:column, "topic"}, {:lit, {:text, "ROOM"}}, {:lit, :case_insensitive}]}
      assert eval(ir) == true

      ir = {:apply, Value, :regex_match, [{:column, "topic"}, {:lit, {:text, "ROOM"}}, {:lit, :case_sensitive}]}
      assert eval(ir) == false
    end
  end

  describe "coalesce" do
    test "picks the first non-NULL value" do
      assert eval({:coalesce, [{:lit, nil}, {:lit, {:text, "a"}}, {:lit, {:text, "b"}}]}) == {:text, "a"}
      assert eval({:coalesce, [{:lit, nil}, {:lit, nil}]}) == nil
      assert eval({:coalesce, [{:lit, nil}, {:lit, false}]}) == false
    end

    test "an unsupported argument makes it unsupported wherever it is" do
      assert eval({:coalesce, [{:lit, {:text, "a"}}, {:unsupported, :boom}]}) == @unsupported
      assert eval({:coalesce, [{:lit, nil}, {:unsupported, :boom}, {:lit, {:text, "a"}}]}) == @unsupported
    end
  end

  describe "NOT" do
    for {input, expected} <- [t: false, f: true, n: nil, u: {:unsupported, :boom}] do
      test "NOT #{input}" do
        assert eval({:not, @nodes[unquote(input)]}) == unquote(Macro.escape(expected))
      end
    end
  end

  # An unsupported child makes the node unsupported, even next to a child that would decide it
  describe "AND" do
    for {a, b, result} <- [
          {:t, :t, true},
          {:t, :f, false},
          {:t, :n, nil},
          {:t, :u, @unsupported},
          {:f, :t, false},
          {:f, :f, false},
          {:f, :n, false},
          {:f, :u, @unsupported},
          {:n, :t, nil},
          {:n, :f, false},
          {:n, :n, nil},
          {:n, :u, @unsupported},
          {:u, :t, @unsupported},
          {:u, :f, @unsupported},
          {:u, :n, @unsupported},
          {:u, :u, @unsupported}
        ] do
      test "#{a} AND #{b} is #{inspect(result)}" do
        assert eval({:and, [@nodes[unquote(a)], @nodes[unquote(b)]]}) == unquote(Macro.escape(result))
      end
    end

    test "of nothing is true, and of one child is the child" do
      assert eval({:and, []}) == true
      assert eval({:and, [{:lit, nil}]}) == nil
    end

    test "three children: an unsupported one makes it unsupported wherever it is" do
      assert eval({:and, [{:lit, true}, {:unsupported, :boom}, {:lit, false}]}) == @unsupported
      assert eval({:and, [{:lit, nil}, {:lit, false}, {:unsupported, :boom}]}) == @unsupported
      assert eval({:and, [{:lit, true}, {:lit, nil}, {:lit, true}]}) == nil
      assert eval({:and, [{:lit, true}, {:lit, false}, {:lit, nil}]}) == false
    end

    test "the first unsupported reason is the one returned" do
      assert eval({:and, [{:unsupported, :a}, {:unsupported, :b}]}) == {:unsupported, :a}
      assert eval({:and, [{:lit, true}, {:unsupported, :b}, {:unsupported, :c}]}) == {:unsupported, :b}
    end
  end

  describe "OR" do
    for {a, b, result} <- [
          {:t, :t, true},
          {:t, :f, true},
          {:t, :n, true},
          {:t, :u, @unsupported},
          {:f, :t, true},
          {:f, :f, false},
          {:f, :n, nil},
          {:f, :u, @unsupported},
          {:n, :t, true},
          {:n, :f, nil},
          {:n, :n, nil},
          {:n, :u, @unsupported},
          {:u, :t, @unsupported},
          {:u, :f, @unsupported},
          {:u, :n, @unsupported},
          {:u, :u, @unsupported}
        ] do
      test "#{a} OR #{b} is #{inspect(result)}" do
        assert eval({:or, [@nodes[unquote(a)], @nodes[unquote(b)]]}) == unquote(Macro.escape(result))
      end
    end

    test "of nothing is false, and of one child is the child" do
      assert eval({:or, []}) == false
      assert eval({:or, [{:lit, nil}]}) == nil
    end

    test "three children: an unsupported one makes it unsupported wherever it is" do
      assert eval({:or, [{:lit, false}, {:unsupported, :boom}, {:lit, true}]}) == @unsupported
      assert eval({:or, [{:lit, nil}, {:lit, true}, {:unsupported, :boom}]}) == @unsupported
      assert eval({:or, [{:lit, false}, {:lit, nil}, {:lit, false}]}) == nil
      assert eval({:or, [{:lit, false}, {:lit, true}, {:lit, nil}]}) == true
    end
  end

  describe "children that aren't booleans" do
    test "are unsupported rather than a crash" do
      assert {:unsupported, {:not_boolean, {:text, "a"}}} = eval({:and, [{:lit, {:text, "a"}}, {:lit, true}]})
      assert {:unsupported, {:not_boolean, {:text, "a"}}} = eval({:or, [{:lit, false}, {:lit, {:text, "a"}}]})
    end
  end
end
