defmodule Realtime.Tenants.Authorization.Policies.TopicPoliciesTest do
  # async: false due to the fact that multiple operations against the database will use the same connection
  use Realtime.DataCase, async: false

  import Ecto.Query
  alias Realtime.Api.Message
  alias Realtime.Repo
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.TopicPolicies
  alias Realtime.Tenants.Connect

  alias RealtimeWeb.Joken.CurrentTime

  describe "check_read_policies/3" do
    setup [:rls_context]

    @tag role: "authenticated", policies: [:authenticated_read_topic]
    test "authenticated user has read policies", context do
      assert {:ok, result} =
               Postgrex.transaction(context.db_conn, fn transaction_conn ->
                 Realtime.Repo.all(transaction_conn, Message, Message)

                 Authorization.set_conn_config(transaction_conn, context.authorization_context)

                 TopicPolicies.check_read_policies(
                   transaction_conn,
                   %Policies{},
                   context.authorization_context
                 )
               end)

      assert {:ok, %Policies{topic: %TopicPolicies{read: true}}} = result
    end

    @tag role: "anon", policies: [:authenticated_read_topic]
    test "anon user has no read policies", context do
      assert {:ok, result} =
               Postgrex.transaction(context.db_conn, fn transaction_conn ->
                 Authorization.set_conn_config(transaction_conn, context.authorization_context)

                 TopicPolicies.check_read_policies(
                   transaction_conn,
                   %Policies{},
                   context.authorization_context
                 )
               end)

      assert {:ok, %Policies{topic: %TopicPolicies{read: false}}} = result
    end

    @tag role: "authenticated", policies: [:authenticated_all_topic_read]
    test "no topic with authenticated returns false", context do
      authorization_context = %{context.authorization_context | topic: nil}

      assert {:ok, result} =
               Postgrex.transaction(context.db_conn, fn transaction_conn ->
                 Authorization.set_conn_config(transaction_conn, context.authorization_context)

                 TopicPolicies.check_read_policies(
                   transaction_conn,
                   %Policies{},
                   authorization_context
                 )
               end)

      assert {:ok, %Policies{topic: %TopicPolicies{read: false}}} = result
    end

    @tag role: "anon", policies: [:authenticated_all_topic_read]
    test "no topic with anon in context returns false", context do
      authorization_context = %{context.authorization_context | topic: nil}

      assert {:ok, result} =
               Postgrex.transaction(context.db_conn, fn transaction_conn ->
                 Authorization.set_conn_config(transaction_conn, context.authorization_context)

                 TopicPolicies.check_read_policies(
                   transaction_conn,
                   %Policies{},
                   authorization_context
                 )
               end)

      assert {:ok, %Policies{topic: %TopicPolicies{read: false}}} = result
    end

    @tag role: "anon", policies: []
    test "handles database errors", context do
      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)
        Process.unlink(context.db_conn)
        Process.exit(context.db_conn, :shutdown)
        :timer.sleep(100)

        assert {:error, _} =
                 TopicPolicies.check_read_policies(
                   transaction_conn,
                   %Policies{},
                   context.authorization_context
                 )
      end)
    end
  end

  describe "check_write_policies/3" do
    setup [:rls_context]

    @tag role: "authenticated",
         policies: [:authenticated_read_topic, :authenticated_write_topic]
    test "authenticated user has write policies", context do
      query = from(m in Message, where: m.topic == ^context.topic)
      assert {:ok, %Message{}} = Repo.one(context.db_conn, query, Message)

      assert {:ok, result} =
               Postgrex.transaction(context.db_conn, fn transaction_conn ->
                 Authorization.set_conn_config(transaction_conn, context.authorization_context)

                 TopicPolicies.check_write_policies(
                   transaction_conn,
                   %Policies{},
                   context.authorization_context
                 )
               end)

      assert {:ok, %Policies{topic: %TopicPolicies{write: true}}} = result
      # Ensure policy check does not polute database
      assert {:ok, %Message{}} = Repo.one(context.db_conn, query, Message)
    end

    @tag role: "anon", policies: [:authenticated_read_topic, :authenticated_write_topic]
    test "anon user has no write policies", context do
      assert {:ok, result} =
               Postgrex.transaction(context.db_conn, fn transaction_conn ->
                 Authorization.set_conn_config(transaction_conn, context.authorization_context)

                 TopicPolicies.check_write_policies(
                   transaction_conn,
                   %Policies{},
                   context.authorization_context
                 )
               end)

      assert {:ok, %Policies{topic: %TopicPolicies{write: false}}} = result
    end

    @tag role: "anon",
         policies: [:authenticated_all_topic_read, :authenticated_all_topic_insert]
    test "no topic and authenticated returns false", context do
      authorization_context = %{context.authorization_context | topic: nil}

      assert {:ok, result} =
               Postgrex.transaction(context.db_conn, fn transaction_conn ->
                 Authorization.set_conn_config(transaction_conn, authorization_context)

                 TopicPolicies.check_write_policies(
                   transaction_conn,
                   %Policies{},
                   authorization_context
                 )
               end)

      assert {:ok, %Policies{topic: %TopicPolicies{write: false}}} = result
    end

    @tag role: "anon",
         policies: [:authenticated_all_topic_read, :authenticated_all_topic_insert]
    test "no topic and anon returns false", context do
      authorization_context = %{context.authorization_context | topic: nil}

      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)

        assert {:ok, result} =
                 TopicPolicies.check_write_policies(
                   transaction_conn,
                   %Policies{},
                   authorization_context
                 )

        assert result == %Policies{topic: %TopicPolicies{write: false}}
      end)
    end
  end

  def rls_context(context) do
    start_supervised!(CurrentTime.Mock)
    tenant = tenant_fixture()

    {:ok, _} = start_supervised({Connect, tenant_id: tenant.external_id}, restart: :transient)
    {:ok, db_conn} = Connect.get_status(tenant.external_id)

    clean_table(db_conn, "realtime", "messages")

    message = message_fixture(tenant)
    create_rls_policies(db_conn, context.policies, message)

    claims = %{sub: random_string(), role: context.role, exp: Joken.current_time() + 1_000}
    signer = Joken.Signer.create("HS256", "secret")
    jwt = Joken.generate_and_sign!(%{}, claims, signer)

    authorization_context =
      Authorization.build_authorization_params(%{
        headers: [{"header-1", "value-1"}],
        topic: message.topic,
        jwt: jwt,
        claims: claims,
        role: claims.role
      })

    on_exit(fn -> Process.exit(db_conn, :normal) end)

    %{
      tenant: tenant,
      topic: message.topic,
      db_conn: db_conn,
      authorization_context: authorization_context
    }
  end
end
