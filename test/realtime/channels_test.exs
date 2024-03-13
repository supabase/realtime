defmodule Realtime.ChannelsTest do
  # async: false due to the fact that multiple operations against the database will use the same connection
  use Realtime.DataCase, async: false

  alias Realtime.Api.Broadcast
  alias Realtime.Api.Channel
  alias Realtime.Channels
  alias Realtime.Tenants.Connect

  setup do
    tenant = tenant_fixture()

    {:ok, pid} = Connect.connect(tenant.external_id)
    Process.link(pid)
    {:ok, conn} = Connect.get_status(tenant.external_id)

    clean_table(conn, "realtime", "broadcasts")
    clean_table(conn, "realtime", "channels")

    on_exit(fn -> Process.exit(conn, :normal) end)
    %{conn: conn, tenant: tenant}
  end

  describe "list/1" do
    test "list channels in tenant database", %{conn: conn, tenant: tenant} do
      channels = Stream.repeatedly(fn -> channel_fixture(tenant) end) |> Enum.take(10)
      assert {:ok, ^channels} = Channels.list_channels(conn)
    end
  end

  describe "get_channel_by_id/2" do
    test "fetches correct channel", %{tenant: tenant, conn: conn} do
      [channel | _] = Stream.repeatedly(fn -> channel_fixture(tenant) end) |> Enum.take(10)
      {:ok, res} = Channels.get_channel_by_id(channel.id, conn)
      assert channel == res
    end

    test "not found error if does not exist", %{conn: conn} do
      assert {:error, :not_found} = Channels.get_channel_by_id(0, conn)
    end
  end

  describe "create_channel/2" do
    test "creates a channel and a broadcast entry in tenant database", %{conn: conn} do
      name = random_string()

      assert {:ok, %Channel{name: ^name, id: channel_id}} =
               Channels.create_channel(%{name: name}, conn)

      assert {:ok, [%Broadcast{channel_id: ^channel_id}]} = Repo.all(conn, Broadcast, Broadcast)
    end

    test "no channel name has error changeset", %{conn: conn} do
      assert {:error, %Ecto.Changeset{valid?: false, errors: errors}} =
               Channels.create_channel(%{}, conn)

      assert ^errors = [name: {"can't be blank", [validation: :required]}]
    end

    test "already repeating channel returns changeset", %{conn: conn} do
      name = random_string()
      Channels.create_channel(%{name: name}, conn)

      assert {:error, %Ecto.Changeset{valid?: false, errors: errors}} =
               Channels.create_channel(%{name: name}, conn)

      assert ^errors = [name: {"has already been taken", []}]
    end
  end

  describe "get_channel_by_name/2" do
    test "fetches correct channel", %{conn: conn} do
      name = random_string()
      {:ok, channel} = Channels.create_channel(%{name: name}, conn)
      assert {:ok, ^channel} = Channels.get_channel_by_name(name, conn)
    end

    test "not found error if does not exist", %{conn: conn} do
      assert {:error, :not_found} == Channels.get_channel_by_name(random_string(), conn)
    end
  end

  describe "delete_channel_by_id/2" do
    test "deletes correct channel", %{conn: conn, tenant: tenant} do
      [channel | _] = Stream.repeatedly(fn -> channel_fixture(tenant) end) |> Enum.take(10)
      assert :ok = Channels.delete_channel_by_id(channel.id, conn)
      assert {:error, :not_found} = Channels.get_channel_by_id(channel.id, conn)
    end

    test "not found error if does not exist", %{conn: conn} do
      assert {:error, :not_found} = Channels.delete_channel_by_id(0, conn)
    end
  end

  describe "update_channel_by_id/2" do
    test "update correct channel", %{conn: conn, tenant: tenant} do
      name = random_string()
      [channel | _] = Stream.repeatedly(fn -> channel_fixture(tenant) end) |> Enum.take(10)
      assert {:ok, channel} = Channels.update_channel_by_id(channel.id, %{name: name}, conn)
      {:ok, channel} = Channels.get_channel_by_id(channel.id, conn)
      assert name == channel.name
    end

    test "not found error if does not exist", %{conn: conn} do
      assert {:error, :not_found} = Channels.update_channel_by_id(0, %{name: ""}, conn)
    end
  end
end
