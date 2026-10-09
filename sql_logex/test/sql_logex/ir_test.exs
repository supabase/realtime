defmodule SqlLogex.IRTest do
  use ExUnit.Case, async: true

  alias SqlLogex.IR
  alias SqlLogex.Parser
  alias SqlLogex.Resolver
  alias SqlLogex.Value

  @unsupported {:unsupported, :boom}
  @supported {:lit, true}

  describe "supported?/1" do
    test "the leaves are supported" do
      assert IR.supported?({:lit, true})
      assert IR.supported?({:lit, nil})
      assert IR.supported?({:lit, {:text, "a"}})
      assert IR.supported?({:lit, :case_insensitive})
      assert IR.supported?({:setting, "realtime.topic"})
      assert IR.supported?({:column, "topic"})
    end

    test "an unsupported node is not, whatever its reason" do
      refute IR.supported?(@unsupported)
      refute IR.supported?({:unsupported, {:operator, "~", :text, :int}})
    end

    test "a node with an unsupported child anywhere is not" do
      for wrap <- [
            fn node -> {:and, [@supported, node]} end,
            fn node -> {:or, [node, @supported]} end,
            fn node -> {:not, node} end,
            fn node -> {:coalesce, [@supported, node]} end,
            fn node -> {:array, [node]} end,
            fn node -> {:apply, Value, :text_eq, [@supported, node]} end
          ] do
        refute IR.supported?(wrap.(@unsupported))
        refute IR.supported?(wrap.(wrap.(@unsupported)))
        refute IR.supported?({:and, [@supported, {:or, [@supported, wrap.(@unsupported)]}]})

        assert IR.supported?(wrap.(@supported))
        assert IR.supported?(wrap.(wrap.(@supported)))
      end
    end

    test "empty nodes are supported" do
      assert IR.supported?({:and, []})
      assert IR.supported?({:or, []})
      assert IR.supported?({:array, []})
      assert IR.supported?({:apply, Value, :is_null, []})
    end

    test "something that isn't a node of the IR is not supported" do
      refute IR.supported?(:oops)
      refute IR.supported?(nil)
      refute IR.supported?({:what, 1})
      refute IR.supported?({:and, :not_a_list})
      refute IR.supported?({:apply, Value, :is_null, :not_a_list})
    end

    test "a supported tree can still evaluate to unsupported: the tree is not evaluated" do
      # The cast of a string that isn't a uuid raises in Postgres, which the evaluator reports as unsupported
      ir = {:apply, Value, :uuid_in, [{:lit, {:text, "not a uuid"}}]}

      assert IR.supported?(ir)
      assert {:unsupported, {:raises, _state, _detail}} = Value.uuid_in({:text, "not a uuid"})
    end
  end

  describe "supported?/1 on what the resolver builds" do
    setup do
      {catalog, _binding} = Code.eval_file(Path.expand("../fixtures/pg17/catalog.exs", __DIR__))
      %{functions: catalog.functions}
    end

    defp resolve(text, functions), do: text |> Parser.parse() |> Resolver.resolve(functions) |> elem(0)

    test "an expression made of what is modelled", %{functions: functions} do
      for text <- [
            "true",
            "(realtime.topic() = 'x'::text)",
            "((realtime.topic() = ('user:'::text || auth.uid())) AND (extension = ANY (ARRAY['broadcast'::text, 'presence'::text])))",
            "(realtime.topic() ~* 'public:lobby'::text)",
            "(((current_setting('request.jwt.claims'::text, true))::jsonb ->> 'k'::text))::boolean",
            "((( SELECT auth.uid() AS uid))::text = 'a'::text)"
          ] do
        assert IR.supported?(resolve(text, functions)), text
      end
    end

    test "an expression with something that isn't, anywhere in it", %{functions: functions} do
      for text <- [
            "(lower(extension) = 'x'::text)",
            "((realtime.topic() = 'x'::text) AND (lower(extension) = 'x'::text))",
            "(NOT ((realtime.topic() = 'x'::text) OR (private = true)))",
            "(auth.email() = 'a'::text)",
            "( SELECT true\n   FROM pg_sleep((1)::double precision) pg_sleep(pg_sleep))"
          ] do
        refute IR.supported?(resolve(text, functions)), text
      end
    end

    test "a function whose definition isn't the known one", %{functions: functions} do
      changed = Enum.map(functions, &if(&1.name == "topic", do: %{&1 | source: "select 'x'::text"}, else: &1))

      assert IR.supported?(resolve("(realtime.topic() = 'x'::text)", functions))
      refute IR.supported?(resolve("(realtime.topic() = 'x'::text)", changed))
    end
  end
end
