defmodule Realtime.Tenants.Authorization.Policies.ChannelPoliciesTest do
  # async: false due to the fact that multiple operations against the database will use the same connection
  use Realtime.DataCase, async: false

  import Ecto.Query

  alias Realtime.Api.Channel
  alias Realtime.Channels
  alias Realtime.Helpers
  alias Realtime.Repo
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.ChannelPolicies
  alias Realtime.Tenants.Connect

  alias RealtimeWeb.Joken.CurrentTime

  describe "check_read_policies/3" do
    setup [:rls_context]

    @tag role: "authenticated", policies: [:authenticated_read_channel]
    test "authenticated user has read policies", context do
      assert {:ok, result} =
               Postgrex.transaction(context.db_conn, fn transaction_conn ->
                 Authorization.set_conn_config(transaction_conn, context.authorization_context)

                 ChannelPolicies.check_read_policies(
                   transaction_conn,
                   %Policies{},
                   context.authorization_context
                 )
               end)

      assert {:ok, %Policies{channel: %ChannelPolicies{read: true}}} = result
    end

    @tag role: "anon", policies: [:authenticated_read_channel]
    test "anon user has no read policies", context do
      assert {:ok, result} =
               Postgrex.transaction(context.db_conn, fn transaction_conn ->
                 Authorization.set_conn_config(transaction_conn, context.authorization_context)

                 ChannelPolicies.check_read_policies(
                   transaction_conn,
                   %Policies{},
                   context.authorization_context
                 )
               end)

      assert {:ok, %Policies{channel: %ChannelPolicies{read: false}}} = result
    end

    @tag role: "authenticated", policies: [:authenticated_all_channels_read]
    test "no channel with authenticated and all channels returns true", context do
      authorization_context = %{context.authorization_context | channel: nil}

      assert {:ok, result} =
               Postgrex.transaction(context.db_conn, fn transaction_conn ->
                 Authorization.set_conn_config(transaction_conn, context.authorization_context)

                 ChannelPolicies.check_read_policies(
                   transaction_conn,
                   %Policies{},
                   authorization_context
                 )
               end)

      assert {:ok, %Policies{channel: %ChannelPolicies{read: true}}} = result
    end

    @tag role: "anon", policies: [:authenticated_all_channels_read]
    test "no channel with anon in context returns false", context do
      authorization_context = %{context.authorization_context | channel: nil}

      assert {:ok, result} =
               Postgrex.transaction(context.db_conn, fn transaction_conn ->
                 Authorization.set_conn_config(transaction_conn, context.authorization_context)

                 ChannelPolicies.check_read_policies(
                   transaction_conn,
                   %Policies{},
                   authorization_context
                 )
               end)

      assert {:ok, %Policies{channel: %ChannelPolicies{read: false}}} = result
    end

    @tag role: "anon", policies: []
    test "handles database errors", context do
      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)
        Process.unlink(context.db_conn)
        Process.exit(context.db_conn, :shutdown)
        :timer.sleep(100)

        assert {:error, _} =
                 ChannelPolicies.check_read_policies(
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
         policies: [:authenticated_read_channel, :authenticated_write_channel]
    test "authenticated user has write policies and reverts updated_at", context do
      query = from(c in Channel, where: c.id == ^context.channel.id)
      {:ok, %Channel{updated_at: updated_at}} = Repo.one(context.db_conn, query, Channel)

      assert {:ok, result} =
               Postgrex.transaction(context.db_conn, fn transaction_conn ->
                 Authorization.set_conn_config(transaction_conn, context.authorization_context)

                 ChannelPolicies.check_write_policies(
                   transaction_conn,
                   %Policies{},
                   context.authorization_context
                 )
               end)

      assert {:ok, %Policies{channel: %ChannelPolicies{write: true}}} = result
      # Ensure updated_at stays with the initial value
      assert {:ok, %{updated_at: ^updated_at}} = Repo.one(context.db_conn, query, Channel)
    end

    @tag role: "anon", policies: [:authenticated_read_channel, :authenticated_write_channel]
    test "anon user has no write policies", context do
      assert {:ok, result} =
               Postgrex.transaction(context.db_conn, fn transaction_conn ->
                 Authorization.set_conn_config(transaction_conn, context.authorization_context)

                 ChannelPolicies.check_write_policies(
                   transaction_conn,
                   %Policies{},
                   context.authorization_context
                 )
               end)

      assert {:ok, %Policies{channel: %ChannelPolicies{write: false}}} = result
    end

    @tag role: "anon",
         policies: [:authenticated_all_channels_read, :authenticated_all_channels_insert]
    test "no channel and authenticated returns false", context do
      authorization_context = %{
        context.authorization_context
        | channel: nil,
          channel_name: nil
      }

      assert {:ok, result} =
               Postgrex.transaction(context.db_conn, fn transaction_conn ->
                 Authorization.set_conn_config(transaction_conn, authorization_context)

                 ChannelPolicies.check_write_policies(
                   transaction_conn,
                   %Policies{},
                   authorization_context
                 )
               end)

      assert {:ok, %Policies{channel: %ChannelPolicies{write: false}}} = result
    end

    @tag role: "authenticated",
         policies: [
           :authenticated_all_channels_read,
           :authenticated_all_channels_insert
         ]
    test "no channel, channel name in context, allow policy and channel does not exist returns true",
         context do
      channel_name = random_string()

      authorization_context = %{
        context.authorization_context
        | channel: nil,
          channel_name: channel_name
      }

      Helpers.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, authorization_context)

        assert {:ok, result} =
                 ChannelPolicies.check_write_policies(
                   transaction_conn,
                   %Policies{},
                   authorization_context
                 )

        assert result == %Policies{channel: %ChannelPolicies{write: true}}

        assert {:error, :not_found} = Channels.get_channel_by_name(channel_name, transaction_conn)
      end)
    end

    @tag role: "authenticated",
         policies: [
           :authenticated_all_channels_read,
           :authenticated_all_channels_insert
         ]
    test "no channel, channel name in context, allow policy and channel exists returns true",
         context do
      channel_name = random_string()
      channel_fixture(context.tenant, %{name: channel_name})

      authorization_context = %{
        context.authorization_context
        | channel: nil,
          channel_name: channel_name
      }

      Helpers.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, authorization_context)

        assert {:ok, result} =
                 ChannelPolicies.check_write_policies(
                   transaction_conn,
                   %Policies{},
                   authorization_context
                 )

        assert result == %Policies{channel: %ChannelPolicies{write: true}}

        assert {:ok, _} = Channels.get_channel_by_name(channel_name, transaction_conn)
      end)
    end

    @tag role: "anon",
         policies: [:authenticated_all_channels_read, :authenticated_all_channels_insert]
    test "no channel and anon returns false", context do
      authorization_context = %{context.authorization_context | channel: nil}

      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)

        assert {:ok, result} =
                 ChannelPolicies.check_write_policies(
                   transaction_conn,
                   %Policies{},
                   authorization_context
                 )

        assert result == %Policies{channel: %ChannelPolicies{write: false}}
      end)
    end
  end

  def rls_context(context) do
    start_supervised!(CurrentTime.Mock)
    tenant = tenant_fixture()

    {:ok, _} = start_supervised({Connect, tenant_id: tenant.external_id}, restart: :transient)
    {:ok, db_conn} = Connect.get_status(tenant.external_id)

    clean_table(db_conn, "realtime", "channels")
    clean_table(db_conn, "realtime", "broadcasts")

    channel = channel_fixture(tenant)

    create_rls_policies(db_conn, context.policies, channel)

    claims = %{sub: random_string(), role: context.role, exp: Joken.current_time() + 1_000}
    signer = Joken.Signer.create("HS256", "secret")
    jwt = Joken.generate_and_sign!(%{}, claims, signer)

    authorization_context =
      Authorization.build_authorization_params(%{
        channel: channel,
        headers: [{"header-1", "value-1"}],
        jwt: jwt,
        claims: claims,
        role: claims.role,
        channel_name: channel.name
      })

    on_exit(fn -> Process.exit(db_conn, :normal) end)

    %{
      tenant: tenant,
      channel: channel,
      db_conn: db_conn,
      authorization_context: authorization_context
    }
  end
end
