defmodule Realtime.Tenants.SqlLogexEnvTest do
  # Realtime.Tenants.SqlLogexEnv.build/2 against what Authorization actually sends to Postgres.
  use RealtimeWeb.ConnCase, async: true

  alias Realtime.Database
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.SqlLogexEnv

  @uid "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"

  defp context(opts) do
    Authorization.build_authorization_params(%{
      tenant_id: Keyword.get(opts, :tenant_id, "tenant"),
      topic: Keyword.get(opts, :topic, "room:1"),
      headers: Keyword.get(opts, :headers, [{"x-client-info", "supabase-js/2.0"}]),
      claims: Keyword.get(opts, :claims, %{"sub" => @uid, "role" => "authenticated"}),
      role: Keyword.get(opts, :role, "authenticated"),
      sub: Keyword.get(opts, :sub, @uid)
    })
  end

  describe "build/2" do
    test "the settings map matches what Authorization.set_conn_config/2 sends" do
      ctx = context([])

      assert {:ok, env} = SqlLogexEnv.build(ctx, :broadcast)

      assert env.settings == %{
               "role" => "authenticated",
               "realtime.topic" => "room:1",
               "request.jwt.claims" => Jason.encode!(ctx.claims),
               "request.jwt.claim.sub" => @uid,
               "request.jwt.claim.role" => "authenticated",
               "request.headers" => Jason.encode!(%{"x-client-info" => "supabase-js/2.0"})
             }

      assert env.row == %{"topic" => {:text, "room:1"}, "extension" => {:text, "broadcast"}}
    end

    test "the row's extension reflects the argument" do
      ctx = context([])

      for extension <- [:broadcast, :presence, :persistence] do
        assert {:ok, env} = SqlLogexEnv.build(ctx, extension)
        assert env.row["extension"] == {:text, Atom.to_string(extension)}
      end
    end

    test "returns an error, not a crash, for an extension outside broadcast/presence/persistence" do
      ctx = context([])

      assert {:error, {:unsupported_extension, :postgres_changes}} = SqlLogexEnv.build(ctx, :postgres_changes)
    end

    test "a nil sub becomes a nil setting, the same as a GUC that was never set" do
      ctx = context(sub: nil)

      assert {:ok, env} = SqlLogexEnv.build(ctx, :broadcast)
      assert env.settings["request.jwt.claim.sub"] == nil
    end

    test "a nil topic becomes SQL NULL in the row, not {:text, nil}" do
      ctx = context(topic: nil)

      assert {:ok, env} = SqlLogexEnv.build(ctx, :broadcast)
      assert env.row["topic"] == nil
      assert env.settings["realtime.topic"] == nil
    end

    test "returns an error, not a crash, when claims can't be JSON-encoded" do
      # A tuple would still encode: lib/realtime/logs.ex defines a Jason.Encoder for Tuple so stray
      # tuples in logged values never crash. A pid has no encoder anywhere, so it genuinely fails.
      ctx = context(claims: %{"bad" => self()})

      assert {:error, _reason} = SqlLogexEnv.build(ctx, :broadcast)
    end
  end

  describe "build/2 against a real connection" do
    setup [:checkout_tenant_and_connect]

    test "the settings read back from Postgres match the env, exactly", %{db_conn: db_conn} do
      ctx = context([])

      {:ok, [role, topic, claims, sub, jwt_role, headers]} =
        Database.transaction(db_conn, fn conn ->
          Authorization.set_conn_config(conn, ctx)

          %{rows: [row]} =
            Postgrex.query!(
              conn,
              """
              SELECT current_setting('role', true),
                     current_setting('realtime.topic', true),
                     current_setting('request.jwt.claims', true),
                     current_setting('request.jwt.claim.sub', true),
                     current_setting('request.jwt.claim.role', true),
                     current_setting('request.headers', true)
              """,
              []
            )

          row
        end)

      assert {:ok, env} = SqlLogexEnv.build(ctx, :broadcast)

      assert env.settings == %{
               "role" => role,
               "realtime.topic" => topic,
               "request.jwt.claims" => claims,
               "request.jwt.claim.sub" => sub,
               "request.jwt.claim.role" => jwt_role,
               "request.headers" => headers
             }
    end
  end
end
