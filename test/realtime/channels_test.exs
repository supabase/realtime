defmodule Realtime.ChannelsTest do
  use Realtime.DataCase, async: false

  alias Realtime.Channels
  alias Realtime.Api.Channel
  alias Realtime.Tenants

  @cdc "postgres_cdc_rls"

  setup do
    tenant = tenant_fixture()
    settings = Realtime.PostgresCdc.filter_settings(@cdc, tenant.extensions)
    settings = Map.put(settings, "id", tenant.external_id)
    settings = Map.put(settings, "db_socket_opts", [:inet])

    start_supervised!({Tenants.Migrations, settings})
    {:ok, conn} = Tenants.Connect.lookup_or_start_connection(tenant.external_id)
    truncate_table(conn, "realtime.channels")

    %{db_conn: conn, tenant: tenant}
  end

  describe "list/1" do
    test "list channels in tenant database", %{db_conn: db_conn, tenant: tenant} do
      channels = Stream.repeatedly(fn -> channel_fixture(tenant) end) |> Enum.take(10)
      assert {:ok, ^channels} = Channels.list_channels(db_conn)
    end
  end

  describe "create/2" do
    test "creates channel in tenant database", %{db_conn: db_conn} do
      name = random_string()
      assert {:ok, %Channel{name: ^name}} = Channels.create_channel(%{name: name}, db_conn)
    end
  end

  describe "get_channel_by_name/2" do
    test "fetches correct channel", %{db_conn: db_conn} do
      name = random_string()
      {:ok, channel} = Channels.create_channel(%{name: name}, db_conn)
      assert {:ok, ^channel} = Channels.get_channel_by_name(name, db_conn)
    end

    test "nil if channel does not exist", %{db_conn: db_conn} do
      assert {:ok, nil} == Channels.get_channel_by_name(random_string(), db_conn)
    end
  end
end
