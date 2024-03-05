defmodule Realtime.Tenants.Authorization.Permissions.BroadcastPermissionsTest do
  use Realtime.DataCase

  alias Realtime.Api.Broadcast
  alias Realtime.Tenants
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Permissions
  alias Realtime.Tenants.Authorization.Permissions.BroadcastPermissions

  alias RealtimeWeb.Joken.CurrentTime

  describe "check_read_permissions/3" do
    setup [:rls_context]

    @tag role: "authenticated", policies: [:read_broadcast]
    test "authenticated user has read permissions", context do
      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)

        assert {:ok, result} =
                 BroadcastPermissions.check_read_permissions(
                   transaction_conn,
                   %Permissions{},
                   context.authorization_context
                 )

        assert result == %Permissions{broadcast: %BroadcastPermissions{read: true}}
      end)
    end

    @tag role: "anon", policies: [:read_broadcast]
    test "anon user has read permissions", context do
      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)

        assert {:ok, result} =
                 BroadcastPermissions.check_read_permissions(
                   transaction_conn,
                   %Permissions{},
                   context.authorization_context
                 )

        assert result == %Permissions{broadcast: %BroadcastPermissions{read: false}}
      end)
    end

    @tag role: "anon", policies: []
    test "no channel in context returns false permissions", context do
      authorization_context = %{context.authorization_context | channel: nil}

      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)

        assert {:ok, result} =
                 BroadcastPermissions.check_read_permissions(
                   transaction_conn,
                   %Permissions{},
                   authorization_context
                 )

        assert result == %Permissions{broadcast: %BroadcastPermissions{read: false}}
      end)
    end

    @tag role: "anon", policies: []
    test "handles database errors", context do
      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)
        Process.exit(context.db_conn, :kill)

        assert {:error, _} =
                 BroadcastPermissions.check_read_permissions(
                   transaction_conn,
                   %Permissions{},
                   context.authorization_context
                 )
      end)
    end
  end

  describe "check_write_permissions/3" do
    setup [:rls_context]

    @tag role: "authenticated", policies: [:read_broadcast, :write_broadcast]
    test "authenticated user has write permissions and reverts check", context do
      query = from(b in Broadcast, where: b.channel_id == ^context.channel.id)
      {:ok, %Broadcast{check: check}} = Repo.one(context.db_conn, query, Broadcast)

      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)

        assert {:ok, result} =
                 BroadcastPermissions.check_write_permissions(
                   transaction_conn,
                   %Permissions{},
                   context.authorization_context
                 )

        assert result == %Permissions{broadcast: %BroadcastPermissions{write: true}}
      end)

      # Ensure check stays with the initial value
      assert {:ok, %{check: ^check}} = Repo.one(context.db_conn, query, Broadcast)
    end

    @tag role: "anon", policies: [:read_broadcast, :write_broadcast]
    test "anon user has no write permissions", context do
      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)

        assert {:ok, result} =
                 BroadcastPermissions.check_write_permissions(
                   transaction_conn,
                   %Permissions{},
                   context.authorization_context
                 )

        assert result == %Permissions{broadcast: %BroadcastPermissions{write: false}}
      end)
    end

    @tag role: "anon", policies: []
    test "no channel in context returns false", context do
      authorization_context = %{context.authorization_context | channel: nil}

      Postgrex.transaction(context.db_conn, fn transaction_conn ->
        Authorization.set_conn_config(transaction_conn, context.authorization_context)

        assert {:ok, result} =
                 BroadcastPermissions.check_write_permissions(
                   transaction_conn,
                   %Permissions{},
                   authorization_context
                 )

        assert result == %Permissions{broadcast: %BroadcastPermissions{write: false}}
      end)
    end
  end

  def rls_context(context) do
    start_supervised!(CurrentTime.Mock)
    tenant = tenant_fixture()

    {:ok, db_conn} = Tenants.Connect.lookup_or_start_connection(tenant.external_id)
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
        role: claims.role
      })

    %{
      channel: channel,
      db_conn: db_conn,
      authorization_context: authorization_context
    }
  end
end
