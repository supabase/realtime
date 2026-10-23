defmodule SqlLogex.CatalogTest do
  use ExUnit.Case, async: true

  alias SqlLogex.Catalog
  alias SqlLogex.Jsonb
  alias SqlLogex.Value

  @fixture_versions ["pg17", "pg15"]

  # The bodies the spec lists, as supabase/auth ships them, with the layout of its migrations.
  @uid_supabase_auth """

    select
    coalesce(
      nullif(current_setting('request.jwt.claim.sub', true), ''),
      (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
    )::uuid

  """

  @role_supabase_auth """
  select
  coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )::text
  """

  @jwt_supabase_auth """
  select
    coalesce(
        nullif(current_setting('request.jwt.claim', true), ''),
        nullif(current_setting('request.jwt.claims', true), '')
    )::jsonb
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

  defp uid(source, overrides \\ %{}), do: definition("auth", "uid", "uuid", source, overrides)

  defp nullif_setting(name), do: {:apply, Value, :nullif, [{:setting, name}, {:lit, {:text, ""}}]}

  defp claims_field(setting, field) do
    {:coalesce,
     [
       nullif_setting(setting),
       {:apply, Jsonb, :object_field_text,
        [{:apply, Jsonb, :parse, [nullif_setting("request.jwt.claims")]}, {:lit, {:text, field}}]}
     ]}
  end

  describe "inline/1 on the captured functions" do
    for version <- @fixture_versions do
      {catalog, _} = Code.eval_file(Path.expand("../fixtures/#{version}/catalog.exs", __DIR__))
      functions = Map.new(catalog.functions, &{{&1.schema, &1.name}, &1})
      @functions functions

      test "#{version}: realtime.topic() is nullif(setting, '')" do
        assert Catalog.inline(@functions[{"realtime", "topic"}]) ==
                 {:ok, {nullif_setting("realtime.topic"), :text}}
      end

      test "#{version}: the legacy auth.uid() is uuid_in(nullif(sub, ''))" do
        assert Catalog.inline(@functions[{"auth", "uid"}]) ==
                 {:ok, {{:apply, Value, :uuid_in, [nullif_setting("request.jwt.claim.sub")]}, :uuid}}
      end

      test "#{version}: the legacy auth.role() is nullif(role, '')" do
        assert Catalog.inline(@functions[{"auth", "role"}]) ==
                 {:ok, {nullif_setting("request.jwt.claim.role"), :text}}
      end

      test "#{version}: auth.jwt() is parsed claims, the singular setting being always NULL" do
        assert Catalog.inline(@functions[{"auth", "jwt"}]) ==
                 {:ok,
                  {{:apply, Jsonb, :parse, [{:coalesce, [{:lit, nil}, nullif_setting("request.jwt.claims")]}]}, :jsonb}}
      end
    end
  end

  describe "inline/1 on the supabase/auth bodies" do
    test "auth.uid() of migration 20220224000811 is uuid_in(coalesce(sub, claims ->> 'sub'))" do
      assert Catalog.inline(uid(@uid_supabase_auth)) ==
               {:ok, {{:apply, Value, :uuid_in, [claims_field("request.jwt.claim.sub", "sub")]}, :uuid}}
    end

    test "auth.role() of migration 20220224000811 is coalesce(role, claims ->> 'role')" do
      assert Catalog.inline(definition("auth", "role", "text", @role_supabase_auth)) ==
               {:ok, {claims_field("request.jwt.claim.role", "role"), :text}}
    end

    test "auth.jwt() of migration 20220531120530" do
      assert {:ok, {_ir, :jsonb}} = Catalog.inline(definition("auth", "jwt", "jsonb", @jwt_supabase_auth))
    end
  end

  describe "inline/1 ignores layout" do
    for {name, source} <- [
          {"the one-line form", "select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;"},
          {"no trailing semicolon", "select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid"},
          {"surrounding newlines and indentation",
           "\n    select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;\n  "},
          {"tabs and carriage returns",
           "select\tnullif(current_setting('request.jwt.claim.sub',\ttrue),\r\n''\t)::uuid;"},
          {"runs of spaces", "select   nullif(  current_setting( 'request.jwt.claim.sub' ,true )  ,  '' )::uuid ;"},
          {"no spaces around punctuation", "select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid"}
        ] do
      test "matches #{name}" do
        assert {:ok, {_ir, :uuid}} = Catalog.inline(uid(unquote(source)))
      end
    end
  end

  describe "inline/1 rejects" do
    for {name, source} <- [
          # Earlier supabase/auth bodies (github.com/supabase/auth migrations), which we deliberately don't know
          {"supabase/auth 20211124214934_update_auth_functions",
           """
             select
             coalesce(
               current_setting('request.jwt.claim.sub', true),
               (current_setting('request.jwt.claims', true)::jsonb ->> 'sub')
             )::uuid
           """},
          {"supabase/auth 20211202183645_update_auth_uid",
           """
             select
             nullif(
               coalesce(
                 current_setting('request.jwt.claim.sub', true),
                 (current_setting('request.jwt.claims', true)::jsonb ->> 'sub')
               ),
               ''
             )::uuid
           """},
          {"a body that only guards the setting with nullif",
           """
           select
             coalesce(
               nullif(current_setting('request.jwt.claim.sub', true), ''),
               (current_setting('request.jwt.claims', true)::jsonb ->> 'sub')
             )::uuid
           """},
          {"a changed literal", "select nullif(current_setting('request.jwt.claim.subx', true), '')::uuid;"},
          {"a changed empty-string literal",
           "select nullif(current_setting('request.jwt.claim.sub', true), ' ')::uuid;"},
          {"a changed missing_ok", "select nullif(current_setting('request.jwt.claim.sub', false), '')::uuid;"},
          {"a changed function", "select coalesce(current_setting('request.jwt.claim.sub', true), '')::uuid;"},
          {"another cast", "select nullif(current_setting('request.jwt.claim.sub', true), '')::text;"},
          {"upper case keywords", "SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;"},
          {"a different case in a literal", "select nullif(current_setting('Request.jwt.claim.sub', true), '')::uuid;"},
          {"a second statement", "select 1; select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;"},
          {"two semicolons", "select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;;"},
          {"a line comment", "select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid; -- hi\n"},
          {"a line comment in the middle",
           "select nullif(current_setting('request.jwt.claim.sub', true), -- hi\n'')::uuid;"},
          {"a block comment", "select /* hi */ nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;"},
          {"a block comment without a space",
           "select/**/nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;"},
          {"a dollar-quoted body", "select $$nullif(current_setting('request.jwt.claim.sub', true), '')$$::uuid;"},
          {"an escape string", "select nullif(current_setting(E'request.jwt.claim.sub', true), '')::uuid;"},
          {"nothing", ""},
          {"an unterminated literal", "select nullif(current_setting('request.jwt.claim.sub, true), '')::uuid;"}
        ] do
      test "#{name}" do
        assert Catalog.inline(uid(unquote(source))) == :error
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
          {"another name", %{name: "uid2"}}
        ] do
      test "#{name}" do
        assert Catalog.inline(
                 uid(
                   "select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;",
                   unquote(Macro.escape(overrides))
                 )
               ) ==
                 :error
      end
    end

    test "a body that matches another function's name" do
      # The auth.role() body installed as auth.uid() is not auth.uid()
      assert Catalog.inline(uid("select nullif(current_setting('request.jwt.claim.role', true), '')::text;")) == :error
      assert Catalog.inline(uid(@role_supabase_auth)) == :error
    end

    test "a definition missing fields" do
      assert Catalog.inline(%{}) == :error
      assert Catalog.inline(%{schema: "auth", name: "uid"}) == :error
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
      for source <- [@uid_supabase_auth, @role_supabase_auth, @jwt_supabase_auth, "f( 'a  b' , 'c' ) ;"] do
        assert Catalog.normalize(Catalog.normalize(source)) == Catalog.normalize(source)
      end
    end

    test "turns the supabase/auth uid into one line" do
      assert Catalog.normalize(@uid_supabase_auth) ==
               "select coalesce(nullif(current_setting('request.jwt.claim.sub',true),''),(nullif(current_setting('request.jwt.claims',true),'')::jsonb ->> 'sub'))::uuid"
    end
  end
end
