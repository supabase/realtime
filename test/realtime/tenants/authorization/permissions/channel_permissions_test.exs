defmodule Realtime.Tenants.Authorization.Permissions.ChannelPermissionsTest do
  use Realtime.DataCase

  alias Realtime.Tenants
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Permissions
  alias Realtime.Tenants.Authorization.Permissions.ChannelPermissions

  alias RealtimeWeb.Joken.CurrentTime

  describe "build_permissions/1" do
    test "adds Channel Permissions to the Permission struct" do
      assert %Permissions{channel: %ChannelPermissions{read: false, write: false}} =
               ChannelPermissions.build_permissions(%Permissions{})
    end
  end

  describe "check_read_permissions/3" do
    setup [:rls_context]

    @tag role: "authenticated", rls: :select_authenticated_role
    test "authenticated user has read permissions", context do
      params = Authorization.build_authorization_params(context)
      permissions = ChannelPermissions.build_permissions(%Permissions{})

      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, params)

        assert {:ok, result} =
                 ChannelPermissions.check_read_permissions(transaction_conn, permissions)

        assert result == %Permissions{
                 channel: %ChannelPermissions{
                   read: true,
                   write: false
                 }
               }
      end)
    end

    @tag role: "anon", rls: :select_authenticated_role
    test "anon user has read permissions", context do
      params = Authorization.build_authorization_params(context)
      permissions = ChannelPermissions.build_permissions(%Permissions{})

      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, params)

        assert {:ok, result} =
                 ChannelPermissions.check_read_permissions(transaction_conn, permissions)

        assert result == %Permissions{
                 channel: %ChannelPermissions{
                   read: false,
                   write: false
                 }
               }
      end)
    end
  end

  describe "check_write_permissions/3" do
    setup [:rls_context]

    @tag role: "authenticated", rls: :write_authenticated_role
    test "authenticated user has write permissions and reverts check", context do
      params = Authorization.build_authorization_params(context)
      permissions = ChannelPermissions.build_permissions(%Permissions{})

      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, params)

        assert {:ok, result} =
                 ChannelPermissions.check_write_permissions(
                   transaction_conn,
                   permissions,
                   params
                 )

        assert result == %Permissions{
                 channel: %ChannelPermissions{
                   read: false,
                   write: true
                 }
               }
      end)
    end

    @tag role: "anon", rls: :write_authenticated_role
    test "anon user has no write permissions", context do
      params = Authorization.build_authorization_params(context)
      permissions = ChannelPermissions.build_permissions(%Permissions{})

      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, params)

        assert {:ok, result} =
                 ChannelPermissions.check_write_permissions(
                   transaction_conn,
                   permissions,
                   params
                 )

        assert result == %Permissions{
                 channel: %ChannelPermissions{
                   read: false,
                   write: false
                 }
               }
      end)
    end
  end

  def rls_context(context) do
    start_supervised!(CurrentTime.Mock)
    tenant = tenant_fixture()

    {:ok, db_conn} = Tenants.Connect.lookup_or_start_connection(tenant.external_id)
    clean_table(db_conn, "realtime", "channels")
    channel = channel_fixture(tenant)

    create_rls_policy(db_conn, context.rls, channel)

    claims = %{sub: random_string(), role: context.role, exp: Joken.current_time() + 1_000}
    signer = Joken.Signer.create("HS256", "secret")

    jwt = Joken.generate_and_sign!(%{}, claims, signer)

    %{
      channel: channel,
      db_conn: db_conn,
      jwt: jwt,
      claims: claims,
      headers: [{"header-1", "value-1"}]
    }
  end
end
