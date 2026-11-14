defmodule PolicyEval.CatalogTest do
  use ExUnit.Case, async: true

  alias PolicyEval.Catalog
  alias PolicyEval.Jsonb
  alias PolicyEval.Test.ExampleProfile
  alias PolicyEval.Value

  # The known functions of the example profile
  @known ExampleProfile.profile().functions

  @fixture_versions ["pg17", "pg15"]

  # The fallback bodies of the example, with the layout of a migration
  @user_id_fallback """

    select
    coalesce(
      nullif(current_setting('app.user_id', true), ''),
      (nullif(current_setting('app.claims', true), '')::jsonb ->> 'sub')
    )::uuid

  """

  @user_role_fallback """
  select
  coalesce(
    nullif(current_setting('app.user_role', true), ''),
    (nullif(current_setting('app.claims', true), '')::jsonb ->> 'role')
  )::text
  """

  defp definition(schema, name, return_type, source, overrides \\ %{}) do
    Map.merge(
      %{
        schema: schema,
        name: name,
        language: "sql",
        volatility: "s",
        security_definer: false,
        config: nil,
        return_type: return_type,
        source: source
      },
      overrides
    )
  end

  defp inline(definition), do: Catalog.inline(definition, @known)

  defp user_id(source, overrides \\ %{}), do: definition("app", "user_id", "uuid", source, overrides)

  defp nullif_setting(name), do: {:apply, Value, :nullif, [{:setting, name}, {:lit, {:text, ""}}]}

  defp claims_field(setting, field) do
    {:coalesce,
     [
       nullif_setting(setting),
       {:apply, Jsonb, :object_field_text,
        [{:apply, Jsonb, :parse, [nullif_setting("app.claims")]}, {:lit, {:text, field}}]}
     ]}
  end

  describe "inline/2 on the captured functions" do
    for version <- @fixture_versions do
      {catalog, _} = Code.eval_file(Path.expand("../fixtures/#{version}/catalog.exs", __DIR__))
      functions = Map.new(catalog.functions, &{{&1.schema, &1.name}, &1})
      @functions functions

      test "#{version}: app.team() is nullif(setting, '')" do
        assert inline(@functions[{"app", "team"}]) ==
                 {:ok, {nullif_setting("app.team"), :text}}
      end

      test "#{version}: the simple app.user_id() is uuid_in(nullif(user_id, ''))" do
        assert inline(@functions[{"app", "user_id"}]) ==
                 {:ok, {{:apply, Value, :uuid_in, [nullif_setting("app.user_id")]}, :uuid}}
      end

      test "#{version}: the simple app.user_role() is nullif(user_role, '')" do
        assert inline(@functions[{"app", "user_role"}]) ==
                 {:ok, {nullif_setting("app.user_role"), :text}}
      end

      test "#{version}: app.claims() is the parsed claims setting" do
        assert inline(@functions[{"app", "claims"}]) ==
                 {:ok, {{:apply, Jsonb, :parse, [nullif_setting("app.claims")]}, :jsonb}}
      end
    end
  end

  describe "inline/2 on the fallback bodies" do
    test "app.user_id() is uuid_in(coalesce(user_id, claims ->> 'sub'))" do
      assert inline(user_id(@user_id_fallback)) ==
               {:ok, {{:apply, Value, :uuid_in, [claims_field("app.user_id", "sub")]}, :uuid}}
    end

    test "app.user_role() is coalesce(user_role, claims ->> 'role')" do
      assert inline(definition("app", "user_role", "text", @user_role_fallback)) ==
               {:ok, {claims_field("app.user_role", "role"), :text}}
    end
  end

  describe "inline/2 ignores layout" do
    for {name, source} <- [
          {"the one-line form", "select nullif(current_setting('app.user_id', true), '')::uuid;"},
          {"no trailing semicolon", "select nullif(current_setting('app.user_id', true), '')::uuid"},
          {"surrounding newlines and indentation",
           "\n    select nullif(current_setting('app.user_id', true), '')::uuid;\n  "},
          {"tabs and carriage returns", "select\tnullif(current_setting('app.user_id',\ttrue),\r\n''\t)::uuid;"},
          {"runs of spaces", "select   nullif(  current_setting( 'app.user_id' ,true )  ,  '' )::uuid ;"},
          {"no spaces around punctuation", "select nullif(current_setting('app.user_id',true),'')::uuid"}
        ] do
      test "matches #{name}" do
        assert {:ok, {_ir, :uuid}} = inline(user_id(unquote(source)))
      end
    end
  end

  describe "inline/2 rejects" do
    for {name, source} <- [
          # Earlier versions of the fallback body, which the profile does not know
          {"an earlier fallback body without nullif",
           """
             select
             coalesce(
               current_setting('app.user_id', true),
               (current_setting('app.claims', true)::jsonb ->> 'sub')
             )::uuid
           """},
          {"an earlier fallback body with nullif around the coalesce",
           """
             select
             nullif(
               coalesce(
                 current_setting('app.user_id', true),
                 (current_setting('app.claims', true)::jsonb ->> 'sub')
               ),
               ''
             )::uuid
           """},
          {"a body that only guards the setting with nullif",
           """
           select
             coalesce(
               nullif(current_setting('app.user_id', true), ''),
               (current_setting('app.claims', true)::jsonb ->> 'sub')
             )::uuid
           """},
          {"a changed literal", "select nullif(current_setting('app.user_idx', true), '')::uuid;"},
          {"a changed empty-string literal", "select nullif(current_setting('app.user_id', true), ' ')::uuid;"},
          {"a changed missing_ok", "select nullif(current_setting('app.user_id', false), '')::uuid;"},
          {"a changed function", "select coalesce(current_setting('app.user_id', true), '')::uuid;"},
          {"another cast", "select nullif(current_setting('app.user_id', true), '')::text;"},
          {"upper case keywords", "SELECT nullif(current_setting('app.user_id', true), '')::uuid;"},
          {"a different case in a literal", "select nullif(current_setting('App.user_id', true), '')::uuid;"},
          {"a second statement", "select 1; select nullif(current_setting('app.user_id', true), '')::uuid;"},
          {"two semicolons", "select nullif(current_setting('app.user_id', true), '')::uuid;;"},
          {"a line comment", "select nullif(current_setting('app.user_id', true), '')::uuid; -- hi\n"},
          {"a line comment in the middle", "select nullif(current_setting('app.user_id', true), -- hi\n'')::uuid;"},
          {"a block comment", "select /* hi */ nullif(current_setting('app.user_id', true), '')::uuid;"},
          {"a block comment without a space", "select/**/nullif(current_setting('app.user_id', true), '')::uuid;"},
          {"a dollar-quoted body", "select $$nullif(current_setting('app.user_id', true), '')$$::uuid;"},
          {"an escape string", "select nullif(current_setting(E'app.user_id', true), '')::uuid;"},
          {"nothing", ""},
          {"an unterminated literal", "select nullif(current_setting('app.user_id, true), '')::uuid;"}
        ] do
      test "#{name}" do
        assert inline(user_id(unquote(source))) == :error
      end
    end

    for {name, overrides} <- [
          {"a different volatility (volatile)", %{volatility: "v"}},
          {"a different volatility (immutable)", %{volatility: "i"}},
          {"security definer", %{security_definer: true}},
          {"a function config", %{config: ["search_path=public"]}},
          {"an empty function config", %{config: []}},
          {"another language", %{language: "plpgsql"}},
          {"another return type", %{return_type: "text"}},
          {"another schema", %{schema: "public"}},
          {"another name", %{name: "user_id2"}}
        ] do
      test "#{name}" do
        assert inline(
                 user_id(
                   "select nullif(current_setting('app.user_id', true), '')::uuid;",
                   unquote(Macro.escape(overrides))
                 )
               ) ==
                 :error
      end
    end

    test "a body that matches another function's name" do
      # The app.user_role() body installed as app.user_id() is not app.user_id()
      assert inline(user_id("select nullif(current_setting('app.user_role', true), '')::text;")) == :error
      assert inline(user_id(@user_role_fallback)) == :error
    end

    test "a definition missing fields" do
      assert inline(%{}) == :error
      assert inline(%{schema: "app", name: "user_id"}) == :error
    end
  end

  describe "normalize/1" do
    for {input, expected} <- [
          {"select 1", "select 1"},
          {"  select   1  ", "select 1"},
          {"select\n1", "select 1"},
          {"select 1;", "select 1"},
          {"select 1 ;", "select 1"},
          {"select 1;;", "select 1;"},
          {"f( a , b )", "f(a,b)"},
          {"f ( a )", "f(a)"},
          {"f(a) ,  g(b)", "f(a),g(b)"},
          {"f( )", "f()"},
          {"( ( a ) )", "((a))"},
          {"a\t\tb\r\nc", "a b c"},
          # string literals are untouched
          {"'a  b'", "'a  b'"},
          {"f(' a , b ' , ' ( ')", "f(' a , b ',' ( ')"},
          {"f('')", "f('')"},
          {"'it''s  ok'", "'it''s  ok'"},
          {"'it''s'  ||  'x'", "'it''s' || 'x'"},
          {"'a;'", "'a;'"},
          {"'x' ;", "'x'"},
          {"' x ' ", "' x '"},
          # case is kept
          {"SELECT Now()", "SELECT Now()"},
          # an unterminated literal is kept as it is
          {"select 'a  b", "select 'a  b"},
          {"", ""},
          {"   ", ""}
        ] do
      test "#{inspect(input)} becomes #{inspect(expected)}" do
        assert Catalog.normalize(unquote(input)) == unquote(expected)
      end
    end

    test "is idempotent" do
      for source <- [@user_id_fallback, @user_role_fallback, "f( 'a  b' , 'c' ) ;"] do
        assert Catalog.normalize(Catalog.normalize(source)) == Catalog.normalize(source)
      end
    end

    test "turns the fallback body of app.user_id() into one line" do
      assert Catalog.normalize(@user_id_fallback) ==
               "select coalesce(nullif(current_setting('app.user_id',true),''),(nullif(current_setting('app.claims',true),'')::jsonb ->> 'sub'))::uuid"
    end
  end
end
