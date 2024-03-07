defmodule Realtime.Channels.CacheTest do
  use Realtime.DataCase

  alias Realtime.Channels.Cache
  alias Realtime.Tenants.Connect

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
    %{channel: channel, db_conn: db_conn}
  end

  describe "get_channel_by_name/2" do
    test "returns a channel from cache", %{channel: channel, db_conn: db_conn} do
      assert {:ok, ^channel} = Cache.get_channel_by_name(channel.name, db_conn)
    end
  end
end
