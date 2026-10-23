defmodule SqlLogex.ReasonTest do
  use ExUnit.Case, async: true

  alias SqlLogex.Reason

  # One of every reason shape the library produces, as `decide/3` returns it.
  @categories [
    # the setup
    {{:role, "service_role"}, :role},
    {{:role, :other}, :role},
    {{:role, nil}, :role},
    {:rls_disabled, :setup},
    {:rls_forced, :setup},
    {{:role_not_in_snapshot, "anon"}, :setup},
    {{:bypass_rls, "authenticated"}, :setup},
    {{:missing_grant, "authenticated", :select}, :setup},
    {:unmodelled_policy_role, :setup},
    {:policy_without_expression, :setup},
    {:select_policy_unsupported, :select_policy},

    # the input
    {{:unsupported, {:raises, :invalid_text_representation, "invalid input syntax for type uuid"}}, :raises},
    {{:unsupported, :regex_non_ascii}, :input},
    {{:unsupported, :bool_in_non_ascii}, :input},
    {{:unsupported, :invalid_utf8}, :input},
    {{:unsupported, :jsonb_number_text}, :input},
    {{:unsupported, :jsonb_container_text}, :input},
    {{:unsupported, :jsonb_too_deeply_nested}, :input},
    {{:unsupported, :jsonb_number_range}, :input},
    {{:unsupported, :jsonb_number_token}, :input},

    # the policy
    {{:unsupported, {:function, "auth.email", :not_in_snapshot}}, :function},
    {{:unsupported, {:function, "realtime.topic", :overloaded}}, :function},
    {{:unsupported, {:function, "lower", :not_allowlisted}}, :function},
    {{:unsupported, {:function, :other_schema, :not_allowlisted}}, :function},
    {{:unsupported, {:operator, "~~", :text, :text}}, :operator},
    {{:unsupported, {:array_operator, "<", :any}}, :operator},
    {{:unsupported, :regex_not_literal}, :operator},
    {{:unsupported, {:cast, :text, "integer"}}, :type},
    {{:unsupported, {:cast, :string_literal, :other_schema}}, :type},
    {{:unsupported, {:coalesce_types, [:text, :uuid]}}, :type},
    {{:unsupported, {:nullif, :uuid, :uuid}}, :type},
    {{:unsupported, {:array_types, :text, [:uuid]}}, :type},
    {{:unsupported, {:not_boolean, :text}}, :type},
    {{:unsupported, :untyped_string_literal}, :type},
    {{:unsupported, :untyped_null}, :type},
    {{:unsupported, :number_literal}, :type},
    {{:unsupported, :textanycat_non_uuid}, :type},
    {{:unsupported, :array_not_constructor}, :type},
    {{:unsupported, {:column, "event"}}, :column},
    {{:unsupported, {:unbound_column, "event"}}, :column},
    {{:unsupported, {:unknown_setting, "request.jwt.claim.exp"}}, :setting},
    {{:unsupported, {:unknown_setting, :other}}, :setting},
    {{:unsupported, {:unparsed, :exists}}, :subquery},
    {{:unsupported, {:unparsed, :select}}, :subquery},
    {{:unsupported, {:unparsed, :subquery}}, :subquery},
    {{:unsupported, {:unparsed, :case}}, :unparsed},
    {{:unsupported, {:unparsed, :other}}, :unparsed},
    {{:unsupported, {:unknown_node, :weird}}, :unparsed},

    # the rest
    {{:exception, UndefinedFunctionError}, :exception},
    {:something_new, :other},
    {{:unsupported, :something_new}, :other},
    {nil, :other}
  ]

  for {reason, category} <- @categories do
    test "#{inspect(reason)} is #{inspect(category)}" do
      assert Reason.category(unquote(Macro.escape(reason))) == unquote(category)
    end
  end
end
