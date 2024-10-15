defmodule Realtime.Tenants.Authorization.Policies.BroadcastPoliciesTest do
  # async: false due to the fact that multiple operations against the database will use the same connection
  use Realtime.DataCase, async: false

  alias Realtime.Api.Message
  alias Realtime.Database
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias Realtime.Tenants.Migrations

  alias RealtimeWeb.Joken.CurrentTime

  describe "check_read_policies/3" do
    setup [:rls_context]

    @tag role: "authenticated", policies: [:authenticated_read_broadcast]
    test "authenticated user has read policies", context do
      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)

        assert {:ok, result} =
                 BroadcastPolicies.check_read_policies(
                   transaction_conn,
                   context.ids,
                   %Policies{},
                   context.authorization_context
                 )

        assert result == %Policies{broadcast: %BroadcastPolicies{read: true}}
      end)
    end

    @tag role: "anon", policies: [:authenticated_read_broadcast]
    test "anon user has read policies", context do
      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)

        assert {:ok, result} =
                 BroadcastPolicies.check_read_policies(
                   transaction_conn,
                   context.ids,
                   %Policies{},
                   context.authorization_context
                 )

        assert result == %Policies{broadcast: %BroadcastPolicies{read: false}}
      end)
    end

    @tag role: "anon", policies: []
    test "no topic in context returns false policies", context do
      authorization_context = %{context.authorization_context | topic: nil}

      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)

        assert {:ok, result} =
                 BroadcastPolicies.check_read_policies(
                   transaction_conn,
                   context.ids,
                   %Policies{},
                   authorization_context
                 )

        assert result == %Policies{broadcast: %BroadcastPolicies{read: false}}
      end)
    end

    @tag role: "anon", policies: []
    test "handles database errors", context do
      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)
        Process.unlink(context.db_conn)
        Process.exit(context.db_conn, :shutdown)
        :timer.sleep(100)

        assert {:error, _} =
                 BroadcastPolicies.check_read_policies(
                   transaction_conn,
                   context.ids,
                   %Policies{},
                   context.authorization_context
                 )
      end)
    end
  end

  describe "check_write_policies/3" do
    setup [:rls_context]

    @tag role: "authenticated",
         policies: [:authenticated_read_broadcast, :authenticated_write_broadcast]
    test "authenticated user has write policies and reverts updated_at", context do
      query = from(m in Message, where: m.topic == ^context.topic)
      assert {:ok, %Message{}} = Repo.one(context.db_conn, query, Message)

      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)

        assert {:ok, result} =
                 BroadcastPolicies.check_write_policies(
                   transaction_conn,
                   %Policies{},
                   context.authorization_context
                 )

        assert result == %Policies{broadcast: %BroadcastPolicies{write: true}}
      end)
    end

    @tag role: "anon", policies: [:authenticated_read_broadcast, :authenticated_write_broadcast]
    test "anon user has no write policies", context do
      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)

        assert {:ok, result} =
                 BroadcastPolicies.check_write_policies(
                   transaction_conn,
                   %Policies{},
                   context.authorization_context
                 )

        assert result == %Policies{broadcast: %BroadcastPolicies{write: false}}
      end)
    end

    @tag role: "anon", policies: []
    test "no topic in context returns false", context do
      authorization_context = %{context.authorization_context | topic: nil}

      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)

        assert {:ok, result} =
                 BroadcastPolicies.check_write_policies(
                   transaction_conn,
                   %Policies{},
                   authorization_context
                 )

        assert result == %Policies{broadcast: %BroadcastPolicies{write: false}}
      end)
    end
  end

  def rls_context(context) do
    start_supervised!(CurrentTime.Mock)
    tenant = tenant_fixture()
    [%{settings: settings} | _] = tenant.extensions

    migrations = %Migrations{
      tenant_external_id: tenant.external_id,
      settings: settings
    }

    Migrations.run_migrations(migrations)

    {:ok, db_conn} = Database.connect(tenant, "realtime_test", 1)

    clean_table(db_conn, "realtime", "messages")
    message = message_fixture(tenant, %{extension: :broadcast})

    create_rls_policies(db_conn, context.policies, message)

    claims = %{sub: random_string(), role: context.role, exp: Joken.current_time() + 1_000}
    signer = Joken.Signer.create("HS256", "secret")
    jwt = Joken.generate_and_sign!(%{}, claims, signer)

    authorization_context =
      Authorization.build_authorization_params(%{
        topic: message.topic,
        headers: [{"header-1", "value-1"}],
        jwt: jwt,
        claims: claims,
        role: claims.role
      })

    %{
      ids: %{broadcast_id: message.id},
      topic: message.topic,
      db_conn: db_conn,
      authorization_context: authorization_context
    }
  end
end
