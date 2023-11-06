defmodule Realtime.ChannelsTest do
  use Realtime.DataCase, async: false
  alias Realtime.Channels
  alias Realtime.Tenants.Migrations
  @cdc "postgres_cdc_rls"

  setup do
    tenant = tenant_fixture()
    settings = Realtime.PostgresCdc.filter_settings(@cdc, tenant.extensions)
    settings = Map.put(settings, "id", tenant.external_id)
    settings = Map.put(settings, "db_socket_opts", [:inet])

    start_supervised!({Migrations, settings})
    {:ok, conn} = Realtime.Tenants.Connect.lookup_or_start_connection(tenant.external_id)
    %{db_conn: conn}
  end

  describe "create/2" do
    test "creates channel in tenant database", %{db_conn: db_conn} do
      assert :ok = Channels.create_channel(%{name: random_string()}, db_conn)
    end
  end

  describe "get_channel_by_name/2" do
    test "fetches correct channel", %{db_conn: db_conn} do
      name = random_string()
      assert :ok = Channels.create_channel(%{name: name}, db_conn)

      assert %Realtime.Api.Channel{name: ^name} = Channels.get_channel_by_name(db_conn, name)
    end

    test "nil if channel does not exist", %{db_conn: db_conn} do
      assert nil == Channels.get_channel_by_name(db_conn, random_string())
    end
  end
end
