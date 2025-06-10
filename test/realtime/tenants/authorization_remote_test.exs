defmodule Realtime.Tenants.AuthorizationRemoteTest do
  # async: false due to usage of Clustered
  # Also using dev_tenant due to distributed test
  use RealtimeWeb.ConnCase, async: false
  use Mimic
  setup :set_mimic_global

  require Phoenix.ChannelTest

  alias Realtime.Database
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias Realtime.Tenants.Authorization.Policies.PresencePolicies

  setup [:rls_context]

  describe "get_authorizations" do
    @tag role: "authenticated",
         policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ]
    test "authenticated user has expected policies", context do
      {:ok, policies} =
        Authorization.get_read_authorizations(
          %Policies{},
          context.db_conn,
          context.authorization_context
        )

      {:ok, policies} =
        Authorization.get_write_authorizations(
          policies,
          context.db_conn,
          context.authorization_context
        )

      assert %Policies{
               broadcast: %BroadcastPolicies{read: true, write: true},
               presence: %PresencePolicies{read: true, write: true}
             } == policies
    end

    @tag role: "anon",
         policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ]
    test "anon user has no policies", context do
      {:ok, policies} =
        Authorization.get_read_authorizations(
          %Policies{},
          context.db_conn,
          context.authorization_context
        )

      {:ok, policies} =
        Authorization.get_write_authorizations(
          policies,
          context.db_conn,
          context.authorization_context
        )

      assert %Policies{
               broadcast: %BroadcastPolicies{read: false, write: false},
               presence: %PresencePolicies{read: false, write: false}
             } == policies
    end
  end

  describe "get_write_authorizations for DBConnection" do
    @tag role: "authenticated",
         policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ]
    test "authenticated user has expected policies", context do
      {:ok, policies} =
        Authorization.get_write_authorizations(
          %Policies{},
          context.db_conn,
          context.authorization_context
        )

      assert %Policies{
               broadcast: %BroadcastPolicies{read: nil, write: true},
               presence: %PresencePolicies{read: nil, write: true}
             } == policies
    end

    @tag role: "anon",
         policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ]
    test "anon user has no policies", context do
      {:ok, policies} =
        Authorization.get_write_authorizations(
          %Policies{},
          context.db_conn,
          context.authorization_context
        )

      assert %Policies{
               broadcast: %BroadcastPolicies{read: nil, write: false},
               presence: %PresencePolicies{read: nil, write: false}
             } = policies
    end
  end

  describe "database error" do
    @tag role: "authenticated",
         policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ],
         timeout: :timer.minutes(2)
    test "handles small pool size", context do
      task =
        Task.async(fn ->
          :erpc.call(node(context.db_conn), Postgrex, :query!, [
            context.db_conn,
            "SELECT pg_sleep(59)",
            [],
            [timeout: :timer.minutes(1)]
          ])
        end)

      Process.sleep(100)

      assert {:error, :increase_connection_pool} =
               Authorization.get_read_authorizations(
                 %Policies{},
                 context.db_conn,
                 context.authorization_context
               )

      assert {:error, :increase_connection_pool} =
               Authorization.get_write_authorizations(
                 %Policies{},
                 context.db_conn,
                 context.authorization_context
               )

      assert {:error, :increase_connection_pool} =
               Authorization.get_read_authorizations(
                 %Policies{},
                 context.db_conn,
                 context.authorization_context
               )

      assert {:error, :increase_connection_pool} =
               Authorization.get_write_authorizations(
                 %Policies{},
                 context.db_conn,
                 context.authorization_context
               )

      assert {:error, :increase_connection_pool} =
               Authorization.get_write_authorizations(
                 %Policies{},
                 context.db_conn,
                 context.authorization_context
               )

      Task.await(task, :timer.minutes(1))
    end

    @tag role: "authenticated",
         policies: [:broken_read_presence, :broken_write_presence]
    test "broken RLS policy sets policies to false and shows error to user", context do
      assert {:error, :rls_policy_error, %Postgrex.Error{}} =
               Authorization.get_read_authorizations(
                 %Policies{},
                 context.db_conn,
                 context.authorization_context
               )

      assert {:error, :rls_policy_error, %Postgrex.Error{}} =
               Authorization.get_write_authorizations(
                 %Policies{},
                 context.db_conn,
                 context.authorization_context
               )

      assert {:error, :rls_policy_error, %Postgrex.Error{}} =
               Authorization.get_read_authorizations(
                 %Policies{},
                 context.db_conn,
                 context.authorization_context
               )

      assert {:error, :rls_policy_error, %Postgrex.Error{}} =
               Authorization.get_write_authorizations(
                 %Policies{},
                 context.db_conn,
                 context.authorization_context
               )

      assert {:error, :rls_policy_error, %Postgrex.Error{}} =
               Authorization.get_write_authorizations(
                 %Policies{},
                 context.db_conn,
                 context.authorization_context
               )
    end
  end

  defp rls_context(context) do
    tenant = Realtime.Tenants.get_tenant_by_external_id("dev_tenant")

    {:ok, local_db_conn} = Database.connect(tenant, "realtime_test", :stop)
    topic = random_string()

    clean_table(local_db_conn, "realtime", "messages")

    claims = %{sub: random_string(), role: context.role, exp: Joken.current_time() + 1_000}
    signer = Joken.Signer.create("HS256", "secret")

    jwt = Joken.generate_and_sign!(%{}, claims, signer)

    authorization_context =
      Authorization.build_authorization_params(%{
        tenant_id: tenant.external_id,
        topic: topic,
        jwt: jwt,
        claims: claims,
        headers: [{"header-1", "value-1"}],
        role: claims.role
      })

    Realtime.Tenants.Migrations.create_partitions(local_db_conn)
    create_rls_policies(local_db_conn, context.policies, %{topic: topic})

    {:ok, node} = Clustered.start()
    # Start the database connection on the remote node
    stub(Realtime.Nodes, :get_node_for_tenant, fn _ -> {:ok, node} end)
    {:ok, db_conn} = Realtime.Tenants.Connect.lookup_or_start_connection("dev_tenant")

    assert node(db_conn) == node

    %{
      tenant: tenant,
      topic: topic,
      db_conn: db_conn,
      authorization_context: authorization_context
    }
  end
end
