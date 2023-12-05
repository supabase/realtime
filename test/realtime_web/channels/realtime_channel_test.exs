defmodule RealtimeWeb.RealtimeChannelTest do
  use ExUnit.Case, async: false
  use RealtimeWeb.ChannelCase

  import Mock

  alias Phoenix.Socket

  alias Realtime.Tenants

  alias RealtimeWeb.ChannelsAuthorization
  alias RealtimeWeb.Joken.CurrentTime
  alias RealtimeWeb.UserSocket

  @default_limits %{
    max_concurrent_users: 200,
    max_events_per_second: 100,
    max_joins_per_second: 100,
    max_channels_per_client: 100,
    max_bytes_per_second: 100_000
  }

  setup context do
    start_supervised!(CurrentTime.Mock)
    tenant = tenant_fixture()
    settings = Realtime.PostgresCdc.filter_settings("postgres_cdc_rls", tenant.extensions)
    settings = Map.put(settings, "id", tenant.external_id)
    settings = Map.put(settings, "db_socket_opts", [:inet])

    start_supervised!({Tenants.Migrations, settings})
    {:ok, conn} = Tenants.Connect.lookup_or_start_connection(tenant.external_id)
    truncate_table(conn, "realtime.channels")

    case context do
      %{rls: policy} ->
        create_rls_policy(conn, policy)

        on_exit(fn ->
          Postgrex.query!(conn, "drop policy #{policy} on realtime.channels", [])
        end)

      _ ->
        :ok
    end

    %{tenant: tenant_fixture(), conn: conn}
  end

  setup_with_mocks [
    {
      ChannelsAuthorization,
      [],
      [
        authorize_conn: fn _, _ ->
          {:ok, %{"exp" => Joken.current_time() + 1_000, "role" => "postgres"}}
        end
      ]
    }
  ] do
    :ok
  end

  describe "maximum number of connected clients per tenant" do
    test "not reached", %{tenant: tenant} do
      {:ok, %Socket{} = socket} = connect(UserSocket, %{}, conn_opts(tenant))

      socket = Socket.assign(socket, %{limits: %{@default_limits | max_concurrent_users: 1}})
      assert {:ok, _, %Socket{}} = subscribe_and_join(socket, "realtime:test", %{})
    end

    test "reached", %{tenant: tenant} do
      {:ok, %Socket{} = socket} = connect(UserSocket, %{}, conn_opts(tenant))

      socket_at_capacity =
        Socket.assign(socket, %{limits: %{@default_limits | max_concurrent_users: 0}})

      socket_over_capacity =
        Socket.assign(socket, %{limits: %{@default_limits | max_concurrent_users: -1}})

      assert {:error, %{reason: "{:error, :too_many_connections}"}} =
               subscribe_and_join(socket_at_capacity, "realtime:test", %{})

      assert {:error, %{reason: "{:error, :too_many_connections}"}} =
               subscribe_and_join(socket_over_capacity, "realtime:test", %{})
    end
  end

  describe "token expiration" do
    test "valid", %{tenant: tenant} do
      {:ok, %Socket{} = socket} = connect(UserSocket, %{}, conn_opts(tenant))
      assert {:ok, _, %Socket{}} = subscribe_and_join(socket, "realtime:test", %{})
    end

    test_with_mock "token about to expire", %{tenant: tenant}, ChannelsAuthorization, [],
      authorize_conn: fn _, _ ->
        {:ok, %{"exp" => Joken.current_time(), "role" => "postgres"}}
      end do
      {:ok, %Socket{} = socket} = connect(UserSocket, %{}, conn_opts(tenant))

      assert {:error, %{reason: "{:error, 0}"}} = subscribe_and_join(socket, "realtime:test", %{})
    end

    test_with_mock "token that has expired", %{tenant: tenant}, ChannelsAuthorization, [],
      authorize_conn: fn _, _ ->
        {:ok, %{"exp" => Joken.current_time() - 1, "role" => "postgres"}}
      end do
      {:ok, %Socket{} = socket} = connect(UserSocket, %{}, conn_opts(tenant))

      assert {:error, %{reason: "{:error, -1}"}} =
               subscribe_and_join(socket, "realtime:test", %{})
    end
  end

  describe "checks tenant db connectivity" do
    test "successful connection proceeds with join", %{tenant: tenant} do
      {:ok, %Socket{} = socket} = connect(UserSocket, %{}, conn_opts(tenant))
      assert {:ok, _, %Socket{}} = subscribe_and_join(socket, "realtime:test", %{})
    end

    test "unsuccessful connection halts join" do
      extensions = [
        %{
          "type" => "postgres_cdc_rls",
          "settings" => %{
            "db_host" => "127.0.0.1",
            "db_name" => "false",
            "db_user" => "false",
            "db_password" => "false",
            "db_port" => "5432",
            "poll_interval" => 100,
            "poll_max_changes" => 100,
            "poll_max_record_bytes" => 1_048_576,
            "region" => "us-east-1",
            "ssl_enforced" => false
          }
        }
      ]

      tenant = tenant_fixture(%{"extensions" => extensions})

      {:ok, %Socket{} = socket} = connect(UserSocket, %{}, conn_opts(tenant))

      assert {:error, %{reason: "{:error, :tenant_database_unavailable}"}} =
               subscribe_and_join(socket, "realtime:test", %{})
    end
  end

  describe "check authorization on connect" do
    @tag role: "authenticated", rls: :select_authenticated_role
    test_with_mock "authenticated user has read permissions",
                   %{tenant: tenant, role: role},
                   ChannelsAuthorization,
                   [],
                   authorize_conn: fn _, _ ->
                     {:ok,
                      %{
                        "exp" => Joken.current_time() + 1_000,
                        "role" => role,
                        "sub" => random_string()
                      }}
                   end do
      channel_name = random_string()
      channel_fixture(tenant, %{"name" => channel_name})
      params = %{"config" => %{"channel" => channel_name, "public" => true}}

      {:ok, %Socket{} = socket} = connect(UserSocket, %{}, conn_opts(tenant))

      assert {:ok, _, %Socket{} = socket} = subscribe_and_join(socket, "realtime:test", params)
      assert %{read: true} = socket.assigns.permissions
    end

    @tag role: "anon", rls: :select_authenticated_role
    test_with_mock "anon user has no read permissions",
                   %{tenant: tenant, role: role},
                   ChannelsAuthorization,
                   [],
                   authorize_conn: fn _, _ ->
                     {:ok,
                      %{
                        "exp" => Joken.current_time() + 1_000,
                        "role" => role,
                        "sub" => random_string()
                      }}
                   end do
      channel_name = random_string()
      channel_fixture(tenant, %{"name" => channel_name})
      params = %{"config" => %{"channel" => channel_name, "public" => true}}

      {:ok, %Socket{} = socket} = connect(UserSocket, %{}, conn_opts(tenant))

      assert {:ok, _, %Socket{} = socket} = subscribe_and_join(socket, "realtime:test", params)
      assert %{read: false} = socket.assigns.permissions
    end
  end

  defp conn_opts(tenant) do
    [
      connect_info: %{
        uri: %{host: "#{tenant.external_id}.localhost:4000/socket/websocket", query: ""},
        x_headers: [{"x-api-key", "token123"}]
      }
    ]
  end

  defp create_rls_policy(conn, :select_authenticated_role) do
    Postgrex.query!(
      conn,
      """
      create policy select_authenticated_role
      on realtime.channels for select
      to authenticated
      using ( realtime.channel_name() = name );
      """,
      []
    )
  end
end
