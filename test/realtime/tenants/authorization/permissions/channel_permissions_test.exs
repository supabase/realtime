defmodule Realtime.Tenants.Authorization.Permissions.ChannelPermissionsTest do
  use Realtime.DataCase

  alias Realtime.Api.Channel
  alias Realtime.Tenants
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Permissions
  alias Realtime.Tenants.Authorization.Permissions.ChannelPermissions

  alias RealtimeWeb.Joken.CurrentTime

  describe "check_read_permissions/3" do
    setup [:rls_context]

    @tag role: "authenticated", policies: [:read_channel]
    test "authenticated user has read permissions", context do
      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)

        assert {:ok, permissions} =
                 ChannelPermissions.check_read_permissions(
                   transaction_conn,
                   %Permissions{},
                   context.authorization_context
                 )

        assert permissions == %Permissions{channel: %ChannelPermissions{read: true}}
      end)
    end

    @tag role: "anon", policies: [:read_channel]
    test "anon user has no read permissions", context do
      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)

        assert {:ok, result} =
                 ChannelPermissions.check_read_permissions(
                   transaction_conn,
                   %Permissions{},
                   context.authorization_context
                 )

        assert result == %Permissions{channel: %ChannelPermissions{read: false}}
      end)
    end

    @tag role: "authenticated", policies: [:read_all_channels]
    test "no channel with authenticated and all channels returns true", context do
      authorization_context = %{context.authorization_context | channel: nil}

      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)

        assert {:ok, result} =
                 ChannelPermissions.check_read_permissions(
                   transaction_conn,
                   %Permissions{},
                   authorization_context
                 )

        assert result == %Permissions{channel: %ChannelPermissions{read: true}}
      end)
    end

    @tag role: "anon", policies: [:read_all_channels]
    test "no channel with anon in context returns false", context do
      authorization_context = %{context.authorization_context | channel: nil}

      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)

        assert {:ok, result} =
                 ChannelPermissions.check_read_permissions(
                   transaction_conn,
                   %Permissions{},
                   authorization_context
                 )

        assert result == %Permissions{channel: %ChannelPermissions{read: false}}
      end)
    end
  end

  describe "check_write_permissions/3" do
    setup [:rls_context]

    @tag role: "authenticated", policies: [:read_channel, :write_channel]
    test "authenticated user has write permissions and reverts check", context do
      query = from(c in Channel, where: c.id == ^context.channel.id)
      {:ok, %Channel{check: check}} = Repo.one(context.db_conn, query, Channel)

      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)

        assert {:ok, result} =
                 ChannelPermissions.check_write_permissions(
                   transaction_conn,
                   %Permissions{},
                   context.authorization_context
                 )

        assert result == %Permissions{channel: %ChannelPermissions{write: true}}
      end)

      # Ensure check stays with the initial value
      assert {:ok, %{check: ^check}} = Repo.one(context.db_conn, query, Channel)
    end

    @tag role: "anon", policies: [:read_channel, :write_channel]
    test "anon user has no write permissions", context do
      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)

        assert {:ok, result} =
                 ChannelPermissions.check_write_permissions(
                   transaction_conn,
                   %Permissions{},
                   context.authorization_context
                 )

        assert result == %Permissions{channel: %ChannelPermissions{write: false}}
      end)
    end

    @tag role: "anon", policies: [:read_all_channels, :write_all_channels]
    test "no channel and authenticated returns false", context do
      authorization_context = %{context.authorization_context | channel: nil}

      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)

        assert {:ok, result} =
                 ChannelPermissions.check_read_permissions(
                   transaction_conn,
                   %Permissions{},
                   authorization_context
                 )

        assert result == %Permissions{channel: %ChannelPermissions{write: false}}
      end)
    end

    @tag role: "anon", policies: [:read_all_channels, :write_all_channels]
    test "no channel and anon returns false", context do
      authorization_context = %{context.authorization_context | channel: nil}

      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)

        assert {:ok, result} =
                 ChannelPermissions.check_read_permissions(
                   transaction_conn,
                   %Permissions{},
                   authorization_context
                 )

        assert result == %Permissions{channel: %ChannelPermissions{write: false}}
      end)
    end
  end

  def rls_context(context) do
    start_supervised!(CurrentTime.Mock)
    tenant = tenant_fixture()

    {:ok, db_conn} = Tenants.Connect.lookup_or_start_connection(tenant.external_id)
    clean_table(db_conn, "realtime", "channels")
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
        role: claims.role
      })

    %{
      channel: channel,
      db_conn: db_conn,
      authorization_context: authorization_context
    }
  end
end
