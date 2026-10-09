defmodule SqlLogex.Resolver do
  @moduledoc """
  Binds a `SqlLogex.AST` into `SqlLogex.IR`, with the type of every node.

  Types are `:text`, `:uuid`, `:jsonb`, `:bool` and `:unknown`. Operators are bound by name and
  operand types from an allowlist, casts and functions likewise, and known functions are inlined
  from `SqlLogex.Catalog` when the tenant's definition matches.

  Resolution never fails. Whatever isn't allowlisted becomes `{:unsupported, reason}` in place,
  with type `:unknown`, so `SqlLogex.Eval` can still decide the rest of the expression. A node
  that has an unsupported operand is unsupported with the operand's reason, except where the
  evaluator treats operands individually: the children of `AND`, `OR` and `NOT` stay where they are.

  Reasons are one of:

    * `{:unparsed, raw}`: the parser couldn't read this part
    * `{:operator, op, left_type, right_type}`, `{:cast, from_type, to_type}`, `{:nullif, left_type,
      right_type}`: no binding for these types
    * `{:array_operator, op, quantifier}`, `:array_not_constructor`, `{:array_types, lhs_type,
      element_types}`
    * `{:not_boolean, type}`: something else where a boolean is required
    * `{:coalesce_types, types}`: arguments of different types
    * `{:function, "schema.name", why}`: `why` is `:not_allowlisted`, `:not_in_snapshot`,
      `:overloaded` (more than one definition of the name) or `:unknown_definition`
    * `{:column, name}`: a column other than `topic` and `extension`, since the other columns of
      the row aren't modelled yet
    * `:untyped_string_literal`, `{:number_literal, raw}`, `:untyped_null`: constants Postgres
      prints without a type, which it only does where we don't model the type
    * `{:unknown_node, node}`: not a node of `SqlLogex.AST`

  ## Notes on the bindings

    * `=` and `<>`: text with text, uuid with uuid
    * `||`: text with text is `textcat`, text with uuid is `textanycat` (the uuid goes through `uuid_out`)
    * `~` and `~*`, text with text: `SqlLogex.Value.regex_match/3`, with the mode as the IR literal
      `{:lit, :case_sensitive}` or `{:lit, :case_insensitive}`
    * `->>`: jsonb with text
    * `text = ANY (ARRAY[...])` over text elements. `text <> ALL (ARRAY[...])` is resolved as
      `NOT (text = ANY (ARRAY[...]))`, which is exact for text. For non-NULL operands `textne` is
      the negation of `texteq`, and both are NULL when an operand is NULL. So `<> ALL` is false
      exactly when some element is equal (where `= ANY` is true), NULL exactly when no element is
      equal and one is NULL (where `= ANY` is NULL), and true otherwise (where `= ANY` is false).
      An empty array gives true for `<> ALL` and false for `= ANY`, whatever the left side is
    * `current_setting(name, true)` with a literal name is `{:setting, name}`
    * a scalar subselect without FROM yields exactly one row, so `( SELECT x)` is `x`
  """

  alias SqlLogex.AST
  alias SqlLogex.Catalog
  alias SqlLogex.IR
  alias SqlLogex.Jsonb
  alias SqlLogex.Value

  @type type :: :text | :uuid | :jsonb | :bool | :unknown
  @type resolved :: {IR.t(), type}

  # What a literal can be cast to, by the name Postgres prints.
  @cast_types %{"text" => :text, "uuid" => :uuid, "jsonb" => :jsonb, "boolean" => :bool}

  @doc """
  Resolves `ast`. `functions` are the tenant's definitions, as in `SqlLogex.Catalog`: a call to
  `realtime.*` or `auth.*` is inlined only if its definition is one of the known ones.
  """
  @spec resolve(AST.t(), [map()]) :: resolved
  def resolve(ast, functions) when is_list(functions), do: res(ast, index(functions))

  # {schema, name} => {:ok, resolved} | {:error, why}
  defp index(functions) do
    functions
    |> Enum.group_by(&{Map.get(&1, :schema), Map.get(&1, :name)})
    |> Map.new(fn
      {key, [definition]} ->
        case Catalog.inline(definition) do
          {:ok, resolved} -> {key, {:ok, resolved}}
          :error -> {key, {:error, :unknown_definition}}
        end

      {key, _overloads} ->
        {key, {:error, :overloaded}}
    end)
  end

  ## Nodes

  defp res({:unsupported, raw}, _fns), do: unsupported({:unparsed, raw})

  # Constants and columns
  defp res({:const, :bool, value}, _fns), do: {{:lit, value}, :bool}
  defp res({:const, :string, _}, _fns), do: unsupported(:untyped_string_literal)
  defp res({:const, :number, raw}, _fns), do: unsupported({:number_literal, raw})
  defp res({:const, :null}, _fns), do: unsupported(:untyped_null)
  defp res({:column, name}, _fns) when name in ["topic", "extension"], do: {{:column, name}, :text}
  defp res({:column, name}, _fns), do: unsupported({:column, name})

  # Casts. A literal is converted now, by the primitive the executor would run on it.
  defp res({:cast, {:const, :string, string}, type}, _fns) do
    case type do
      "text" -> {{:lit, {:text, string}}, :text}
      "uuid" -> literal(Value.uuid_in({:text, string}), :uuid)
      "jsonb" -> literal(Jsonb.parse({:text, string}), :jsonb)
      "boolean" -> literal(Value.bool_in({:text, string}), :bool)
      _ -> unsupported({:cast, :string_literal, type})
    end
  end

  defp res({:cast, {:const, :null}, type}, _fns) do
    case Map.fetch(@cast_types, type) do
      {:ok, resolved_type} -> {{:lit, nil}, resolved_type}
      :error -> unsupported({:cast, :null, type})
    end
  end

  defp res({:cast, expr, type}, fns) do
    case res(expr, fns) do
      {{:unsupported, _} = unsupported, _} -> {unsupported, :unknown}
      {ir, from} -> cast(ir, from, type)
    end
  end

  # Boolean structure
  defp res({:bool_expr, op, children}, fns), do: {{op, Enum.map(children, &boolean(&1, fns))}, :bool}
  defp res({:not, child}, fns), do: {{:not, boolean(child, fns)}, :bool}

  defp res({:null_test, kind, child}, fns) do
    case res(child, fns) do
      {{:unsupported, _} = unsupported, _} -> {unsupported, :unknown}
      # `kind` is `:is_null` or `:is_not_null`, which are also the names of the primitives.
      {ir, _type} -> {call(Value, kind, [ir]), :bool}
    end
  end

  # Operators
  defp res({:op, op, left, right}, fns) do
    case propagate([res(left, fns), res(right, fns)]) do
      {:unsupported, _} = unsupported -> {unsupported, :unknown}
      [{l, lt}, {r, rt}] -> operator(op, lt, rt, l, r)
    end
  end

  defp res({:scalar_array_op, "=", :any, lhs, array}, fns), do: any(lhs, array, fns)

  defp res({:scalar_array_op, "<>", :all, lhs, array}, fns) do
    case any(lhs, array, fns) do
      {{:unsupported, _}, _} = unsupported -> unsupported
      {ir, :bool} -> {{:not, ir}, :bool}
    end
  end

  defp res({:scalar_array_op, op, quantifier, _lhs, _array}, _fns), do: unsupported({:array_operator, op, quantifier})
  defp res({:array, _}, _fns), do: unsupported(:array_not_constructor)

  # Functions
  defp res({:func, schema, name, []}, fns) when schema in ["realtime", "auth"] do
    case Map.fetch(fns, {schema, name}) do
      {:ok, {:ok, resolved}} -> resolved
      {:ok, {:error, why}} -> unsupported({:function, "#{schema}.#{name}", why})
      :error -> unsupported({:function, "#{schema}.#{name}", :not_in_snapshot})
    end
  end

  defp res({:func, nil, "current_setting", [{:cast, {:const, :string, name}, "text"}, {:const, :bool, true}]}, _fns),
    do: {{:setting, name}, :text}

  defp res({:func, schema, name, _args}, _fns),
    do: unsupported({:function, Enum.join(Enum.reject([schema, name], &is_nil/1), "."), :not_allowlisted})

  # COALESCE, NULLIF and sublinks. An unsupported COALESCE argument makes the node unsupported
  # wherever it is, see `SqlLogex.Value.coalesce/1`. Postgres gave all arguments one type.
  defp res({:coalesce, args}, fns) do
    case propagate(Enum.map(args, &res(&1, fns))) do
      {:unsupported, _} = unsupported ->
        {unsupported, :unknown}

      resolved ->
        case resolved |> Enum.map(&elem(&1, 1)) |> Enum.uniq() do
          [type] -> {{:coalesce, Enum.map(resolved, &elem(&1, 0))}, type}
          types -> unsupported({:coalesce_types, types})
        end
    end
  end

  defp res({:nullif, a, b}, fns) do
    case propagate([res(a, fns), res(b, fns)]) do
      {:unsupported, _} = unsupported -> {unsupported, :unknown}
      [{l, :text}, {r, :text}] -> {call(Value, :nullif, [l, r]), :text}
      [{_, lt}, {_, rt}] -> unsupported({:nullif, lt, rt})
    end
  end

  defp res({:sublink, expr, _alias}, fns), do: res(expr, fns)

  defp res(other, _fns), do: unsupported({:unknown_node, other})

  ## Pieces

  defp cast(ir, :text, "text"), do: {ir, :text}
  defp cast(ir, :uuid, "text"), do: {call(Value, :uuid_out, [ir]), :text}
  defp cast(ir, :text, "uuid"), do: {call(Value, :uuid_in, [ir]), :uuid}
  defp cast(ir, :text, "jsonb"), do: {call(Jsonb, :parse, [ir]), :jsonb}
  defp cast(ir, :text, "boolean"), do: {call(Value, :bool_in, [ir]), :bool}
  defp cast(_ir, from, type), do: unsupported({:cast, from, type})

  defp literal({:unsupported, _} = unsupported, _type), do: {unsupported, :unknown}
  defp literal(value, type), do: {{:lit, value}, type}

  # An operand of AND, OR or NOT: an unsupported one stays, so the evaluator can still decide the
  # rest around it.
  defp boolean(ast, fns) do
    case res(ast, fns) do
      {ir, :bool} -> ir
      {{:unsupported, _} = unsupported, _} -> unsupported
      {_ir, type} -> {:unsupported, {:not_boolean, type}}
    end
  end

  defp operator("=", :text, :text, l, r), do: {call(Value, :text_eq, [l, r]), :bool}
  defp operator("<>", :text, :text, l, r), do: {call(Value, :text_ne, [l, r]), :bool}
  defp operator("=", :uuid, :uuid, l, r), do: {call(Value, :uuid_eq, [l, r]), :bool}
  defp operator("<>", :uuid, :uuid, l, r), do: {call(Value, :uuid_ne, [l, r]), :bool}
  defp operator("||", :text, :text, l, r), do: {call(Value, :textcat, [l, r]), :text}
  defp operator("||", :text, :uuid, l, r), do: {call(Value, :textanycat, [l, r]), :text}
  defp operator("~", :text, :text, l, r), do: {regex(l, r, :case_sensitive), :bool}
  defp operator("~*", :text, :text, l, r), do: {regex(l, r, :case_insensitive), :bool}
  defp operator("->>", :jsonb, :text, l, r), do: {call(Jsonb, :object_field_text, [l, r]), :text}
  defp operator(op, lt, rt, _l, _r), do: unsupported({:operator, op, lt, rt})

  defp regex(l, r, mode), do: call(Value, :regex_match, [l, r, {:lit, mode}])

  # `lhs = ANY (ARRAY[...])` on text.
  defp any(lhs, array, fns) do
    case array_elements(array) do
      {:ok, elements} ->
        case propagate(Enum.map([lhs | elements], &res(&1, fns))) do
          {:unsupported, _} = unsupported -> {unsupported, :unknown}
          [{l, :text} | elems] -> any_text(l, elems)
          [{_, lt} | elems] -> unsupported({:array_types, lt, Enum.map(elems, &elem(&1, 1))})
        end

      :error ->
        unsupported(:array_not_constructor)
    end
  end

  defp any_text(l, elems) do
    if Enum.all?(elems, &match?({_, :text}, &1)) do
      {call(Value, :text_eq_any, [l, {:array, Enum.map(elems, &elem(&1, 0))}]), :bool}
    else
      unsupported({:array_types, :text, Enum.map(elems, &elem(&1, 1))})
    end
  end

  # An empty array is the only one Postgres prints with a cast.
  defp array_elements({:array, elements}), do: {:ok, elements}
  defp array_elements({:cast, {:array, []}, "text[]"}), do: {:ok, []}
  defp array_elements(_other), do: :error

  defp call(module, function, args), do: {:apply, module, function, args}

  defp unsupported(reason), do: {{:unsupported, reason}, :unknown}

  # The first unsupported node among `resolved`, as an IR node, or `resolved` itself if there is none.
  defp propagate(resolved) do
    Enum.find_value(resolved, resolved, fn
      {{:unsupported, _} = unsupported, _type} -> unsupported
      _supported -> nil
    end)
  end
end
