defmodule Realtime.Tenants.Authorization.Policies.ChannelPoliciesTest do
  # async: false due to the fact that multiple operations against the database will use the same connection
  use Realtime.DataCase, async: false

  import Ecto.Query

  alias Realtime.Api.Channel
  alias Realtime.Channels
  alias Realtime.Repo
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.ChannelPolicies
  alias Realtime.Tenants.Connect

  alias RealtimeWeb.Joken.CurrentTime

  describe "check_read_policies/3" do
    setup [:rls_context]

    @tag role: "authenticated", policies: [:read_channel]
    test "authenticated user has read policies", context do
      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)

        assert {:ok, policies} =
                 ChannelPolicies.check_read_policies(
                   transaction_conn,
                   %Policies{},
                   context.authorization_context
                 )

        assert policies == %Policies{channel: %ChannelPolicies{read: true}}
      end)
    end

    @tag role: "anon", policies: [:read_channel]
    test "anon user has no read policies", context do
      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)

        assert {:ok, result} =
                 ChannelPolicies.check_read_policies(
                   transaction_conn,
                   %Policies{},
                   context.authorization_context
                 )

        assert result == %Policies{channel: %ChannelPolicies{read: false}}
      end)
    end

    @tag role: "authenticated", policies: [:read_all_channels]
    test "no channel with authenticated and all channels returns true", context do
      authorization_context = %{context.authorization_context | channel: nil}

      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)

        assert {:ok, result} =
                 ChannelPolicies.check_read_policies(
                   transaction_conn,
                   %Policies{},
                   authorization_context
                 )

        assert result == %Policies{channel: %ChannelPolicies{read: true}}
      end)
    end

    @tag role: "anon", policies: [:read_all_channels]
    test "no channel with anon in context returns false", context do
      authorization_context = %{context.authorization_context | channel: nil}

      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)

        assert {:ok, result} =
                 ChannelPolicies.check_read_policies(
                   transaction_conn,
                   %Policies{},
                   authorization_context
                 )

        assert result == %Policies{channel: %ChannelPolicies{read: false}}
      end)
    end

    @tag role: "anon", policies: []
    test "handles database errors", context do
      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)
        Process.exit(context.db_conn, :kill)

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

    @tag role: "authenticated", policies: [:read_channel, :write_channel]
    test "authenticated user has write policies and reverts check", context do
      query = from(c in Channel, where: c.id == ^context.channel.id)
      {:ok, %Channel{check: check}} = Repo.one(context.db_conn, query, Channel)

      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)

        assert {:ok, result} =
                 ChannelPolicies.check_write_policies(
                   transaction_conn,
                   %Policies{},
                   context.authorization_context
                 )

        assert result == %Policies{channel: %ChannelPolicies{write: true}}
      end)

      # Ensure check stays with the initial value
      assert {:ok, %{check: ^check}} = Repo.one(context.db_conn, query, Channel)
    end

    @tag role: "anon", policies: [:read_channel, :write_channel]
    test "anon user has no write policies", context do
      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)

        assert {:ok, result} =
                 ChannelPolicies.check_write_policies(
                   transaction_conn,
                   %Policies{},
                   context.authorization_context
                 )

        assert result == %Policies{channel: %ChannelPolicies{write: false}}
      end)
    end

    @tag role: "anon", policies: [:read_all_channels, :write_all_channels]
    test "no channel and authenticated returns false", context do
      authorization_context = %{
        context.authorization_context
        | channel: nil,
          channel_name: nil
      }

      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, authorization_context)

        assert {:ok, result} =
                 ChannelPolicies.check_write_policies(
                   transaction_conn,
                   %Policies{},
                   authorization_context
                 )

        assert result == %Policies{channel: %ChannelPolicies{write: false}}
      end)
    end

    @tag role: "service_role",
         policies: [
           :service_role_all_channels_read,
           :service_role_all_channels_write,
           :service_role_all_channels_delete,
           :service_role_all_broadcasts_write
         ]
    test "no channel, channel name in context and service_role returns true", context do
      channel_name = random_string()

      authorization_context = %{
        context.authorization_context
        | channel: nil,
          channel_name: channel_name
      }

      Postgrex.transaction(context.db_conn, fn transaction_conn ->
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

    @tag role: "anon", policies: [:read_all_channels, :write_all_channels]
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

    {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)

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
      channel: channel,
      db_conn: db_conn,
      authorization_context: authorization_context
    }
  end
end
